#!/bin/bash
# migrate-fabric.sh [--plan] [switch ...]: the migration to three clusters on the RUNNING fabric: every front-end leaf moves from its one-cluster config (one-cluster/configs/,
# a copy of one-cluster/configs/) to the three-cluster one (configs/, gen.py), one switch at a time. Per switch:
#   1. teardown, computed from the two configs (python below): SVIs that go or change VRF lose their address and VRF binding; the VXLAN maps of
#      retired VLANs and of VRFs that leave the pair go; PortChannels lose an access VLAN or tagged VLANs they no longer carry; BGP neighbours
#      that go are removed (the MetalLB / FRR-K8s sessions of the one-cluster nodes), a VRF that leaves the pair loses its BGP instance and
#      `ip vrf`; finally the retired VLANs themselves (no interface VlanN). Dell SONiC 4.6 forms as vrf-rename.sh uses them.
#   2. the switch's NEW configs/<sw>.cli pushed whole (sonic-apply.sh semantics: existing lines are idempotent)
#   3. checks: underlay 4/4 and EVPN 4/4 established, the VRFs and VLANs gen.py says and no retired VLAN, running config holds every NEW line
#      that `show running-configuration` echoes (interfaces, VLANs, VRFs, BGP neighbours), the border's PA / BIG-IP sessions untouched
# Spines and rail switches do not change (byte-identical configs: the script skips any switch whose config did not change); the
# border pair changes only two descriptions (fw-transit-gpu, lb-transit-gpu: an empty teardown, the push re-applies lines that exist), last.
# Order (default): rack1 and rack2 pairs (gpu masters only), rack3, rack4, the storage pair, the borders; within a pair b then a.
# Nothing in Vrf-Mgmt or Vrf-Svc changes. --plan writes logs/migrate-fabric-<sw>.teardown for every switch and changes nothing.
# Before the first run, try the MetalLB lines (Loopback 11, neighbour update-source / ebgp-multihop) on one leaf by hand.
set -u
cd "$(dirname "$0")" || exit 1; . ./lib.sh; mkdir -p logs
PLAN=0; [ "${1:-}" = --plan ] && { PLAN=1; shift; }
OLD=${MIGRATE_OLD:-one-cluster/configs}; NEWD=${MIGRATE_NEW:-configs}   # rollback: MIGRATE_OLD=configs MIGRATE_NEW=one-cluster/configs ./migrate-fabric.sh <sw...> (reverse order)
SWS=("$@"); [ $# -eq 0 ] && SWS=(leaf1b-control leaf1a-control leaf2b-control leaf2a-control leaf3b-compute leaf3a-compute leaf4b-compute leaf4a-compute leaf5b-storage leaf5a-storage leaf6b-border leaf6a-border)
teardown() {   # teardown <old cli> <new cli>: the sonic-cli lines that remove what the old config has and the new one does not
  python3 - "$1" "$2" <<'EOF'
import re, sys
def parse(path):
    """blocks: (header, [lines]) for every top-level 'interface X' / 'router bgp ...' block, plus top-level lines; the KLISH files are flat with
    'exit' closing a block (the ES sub-mode and the BGP neighbour / address-family sub-modes nest: tracked by depth)"""
    lines = [l.rstrip("\n") for l in open(path)]
    blocks, top, cur, depth = {}, [], None, 0
    for l in lines:
        if cur is None:
            if l.startswith(("interface ", "router bgp ")):
                cur, depth = l, 1; blocks.setdefault(cur, []); continue
            top.append(l); continue
        if l == "exit":
            depth -= 1
            if depth == 0: cur = None
            else: blocks[cur].append(l)
            continue
        if l.startswith(("neighbor ", "address-family ", "evpn ethernet-segment")): depth += 1
        blocks[cur].append(l)
    return blocks, top
ob, otop = parse(sys.argv[1]); nb, ntop = parse(sys.argv[2])
vlan = lambda h: int(h.split("Vlan")[1]) if re.match(r"interface Vlan\d+$", h) else None
vrf_of = lambda b: next((l.split()[-1] for l in b if l.startswith("ip vrf forwarding ")), None)
out = ["configure terminal"]
# BGP: neighbours that go (inside a kept VRF), whole VRF instances that go
for h, b in ob.items():
    m = re.match(r"router bgp (\d+) vrf (\S+)$", h)
    if not m: continue
    if h not in nb:
        out.append("no router bgp vrf %s" % m.group(2)); continue   # Dell SONiC 4.6: no ASN in the "no" form (vrf-rename.sh)
    gone = [l for l in b if l.startswith("neighbor ") and l not in nb[h]]
    if gone: out += [h] + ["no " + l for l in gone] + ["exit"]
# PortChannels: an access VLAN that changes, tagged VLANs no longer carried
for h, b in ob.items():
    if not h.startswith("interface PortChannel"): continue
    nbk = next((nb[k] for k in nb if k.split()[:2] == h.split()[:2]), [])
    oa = [l for l in b if l.startswith("switchport access Vlan")]; na = [l for l in nbk if l.startswith("switchport access Vlan")]
    ot = set(sum([l.split()[-1].split(",") for l in b if l.startswith("switchport trunk allowed Vlan")], []))
    nt = set(sum([l.split()[-1].split(",") for l in nbk if l.startswith("switchport trunk allowed Vlan")], []))
    cmds = (["no switchport access Vlan"] if oa and oa != na else []) + (["switchport trunk allowed Vlan remove %s" % ",".join(sorted(ot - nt, key=int))] if ot - nt else [])
    if cmds: out += [h.replace(" fast_rate", "")] + cmds + ["exit"]
# single access ports (BMC, e0h) that change VLAN
for h, b in ob.items():
    if h.startswith("interface Ethernet") and h in nb:
        oa = [l for l in b if l.startswith("switchport access Vlan")]; na = [l for l in nb[h] if l.startswith("switchport access Vlan")]
        if oa and oa != na: out += [h, "no switchport access Vlan", "exit"]
# SVIs (and loopbacks) that go or change VRF: address and VRF binding off
gone_vlans, gone_vrfs = [], []
for h, b in ob.items():
    if not re.match(r"interface (Vlan\d+|Loopback \d+)$", h): continue
    if h in nb and vrf_of(nb[h]) == vrf_of(b): continue
    out += [h] + ["no " + l for l in b if re.match(r"ip (anycast-address|address) ", l)] + (["no ip vrf forwarding %s" % vrf_of(b)] if vrf_of(b) else []) + ["exit"]
    if h not in nb and vlan(h): gone_vlans.append(vlan(h))
# VXLAN maps of retired VLANs and of VRFs leaving the pair
ovtep = ob.get("interface vxlan vtep1", []); nvtep = nb.get("interface vxlan vtep1", [])
maps = [l for l in ovtep if l.startswith("map vni ") and l not in nvtep]
if maps: out += ["interface vxlan vtep1"] + ["no " + l for l in maps] + ["exit"]
for l in otop:
    if l.startswith("ip vrf ") and l not in ntop: gone_vrfs.append(l.split()[-1])
out += ["no ip vrf %s" % v for v in gone_vrfs]
# the retired VLANs (members, maps and SVI are gone by now); the L3VNI VLAN of a VRF that left the pair as well
for l in maps:
    m = re.match(r"map vni \d+ vlan (\d+)$", l)
    if m and int(m.group(1)) not in gone_vlans: gone_vlans.append(int(m.group(1)))
out += ["no interface Vlan%d" % v for v in sorted(set(gone_vlans))]
print("\n".join(out + ["end", "write memory"]))
EOF
}
check() {   # check <sw>: one line, the facts the change must leave true
  local sw=$1 v u e vl
  v=$(KL $sw "show ip vrf" | awk '$1 ~ /^Vrf-/ {print $1}' | sort | xargs)
  u=$(KL $sw "show bgp ipv4 unicast summary" | grep -o 'established [0-9]*' | awk '{print $2}')
  e=$(KL $sw "show bgp l2vpn evpn summary" | grep -o 'established [0-9]*' | awk '{print $2}')
  vl=$(KL $sw "show vlan" | grep -oE '^\s*[0-9]+' | xargs)
  echo "vrfs [$v] underlay ${u:-0} evpn ${e:-0} vlans [$vl]"; }
want_vrfs() { grep -E '^ip vrf ' $NEWD/$1.cli | awk '{print $3}' | sort | xargs; }
for sw in "${SWS[@]}"; do
  [ -f $OLD/$sw.cli ] || { say "$sw: no $OLD/$sw.cli (copy the one-cluster configs there first)"; exit 1; }
  if cmp -s $OLD/$sw.cli $NEWD/$sw.cli; then say "$sw: config unchanged, skipped"; continue; fi
  teardown $OLD/$sw.cli $NEWD/$sw.cli > logs/migrate-fabric-$sw.teardown
  [ $PLAN = 1 ] && { say "$sw: plan, $(( $(wc -l < logs/migrate-fabric-$sw.teardown) - 3 )) teardown lines in logs/migrate-fabric-$sw.teardown"; continue; }
  L=logs/migrate-fabric-$sw.log; : > $L; say "== $sw: before: $(check $sw)"
  KL $sw "show running-configuration" > logs/migrate-fabric-$sw.running-before 2>&1
  mapfile -t TD < logs/migrate-fabric-$sw.teardown; say "$sw: teardown ($(( ${#TD[@]} - 3 )) lines)"; KL $sw "${TD[@]}" >> $L 2>&1
  mapfile -t NEW < $NEWD/$sw.cli; say "$sw: push the new config ($(wc -l < $NEWD/$sw.cli) lines)"; KL $sw "${NEW[@]}" >> $L 2>&1
  errs=$(grep -i -E 'error|invalid|failed' $L | grep -v -E 'error-disable|0 error' | head -5)
  [ -n "$errs" ] && say "$sw: CLI messages (see $L): $(echo $errs | head -c 300)"
  for i in $(seq 1 30); do c=$(check $sw); echo "$c" | grep -qE 'underlay 4 evpn 4' && break; sleep 6; done
  KL $sw "show running-configuration" > logs/migrate-fabric-$sw.running-after 2>&1
  retired=""; [ "$NEWD" = configs ] && retired=$(echo "$c" | grep -oE '\[[0-9 ]*\]$' | tr -d '[]' | tr ' ' '\n' | grep -xE '100|104|106|107|111|112|113|211|212|213' | xargs)
  say "$sw: after: $c${retired:+ RETIRED VLANS LEFT: $retired}"
  case $sw in *border) b=$(for x in Vrf-Prod:1 Vrf-Dev:1 Vrf-Mgmt:1 Vrf-Svc:3 Vrf-Ocp:1; do echo -n "${x%%:*}=$(KL $sw "show bgp ipv4 unicast vrf ${x%%:*} summary" | grep -o 'established [0-9]*' | awk '{print $2}') "; done)
    say "$sw: PA / BIG-IP sessions per VRF: $b"; echo "$b" | grep -q 'Vrf-Prod=3 Vrf-Dev=3 Vrf-Mgmt=1 Vrf-Svc=3 Vrf-Ocp=3' || { say "$sw: border sessions not all up, stopping"; exit 1; };; esac
  echo "$c" | grep -q "vrfs \[$(want_vrfs $sw)\]" && echo "$c" | grep -qE 'underlay 4 evpn 4' && [ -z "$retired" ] \
    || { say "$sw: NOT as $NEWD/$sw.cli says, stopping here (running config before/after in logs/migrate-fabric-$sw.*)"; exit 1; }
done
say "done: ${SWS[*]}"
