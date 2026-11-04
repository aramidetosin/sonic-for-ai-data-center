#!/bin/bash
# vrf-rename.sh <old-configs-dir> [switch ...]: rename the fabric VRFs on the RUNNING switches, one switch at a time, from Vrf-A / -B / -C / -S to
# Vrf-Prod / Vrf-Dev / Vrf-Mgmt / Vrf-Svc. A SONiC VRF cannot be renamed in place, so per switch:
#   1. drain: shut every oper-up port that is not a spine uplink (its ESI-LAG partner carries the hosts; single-homed BMC / e0h ports blip)
#   2. teardown, built from the switch's OLD config: no router bgp <asn> vrf <old>; no map vni <l3vni> vrf <old>; on every interface bound to an
#      old VRF: no ip anycast-address / no ip address, no ip vrf forwarding; no ip vrf <old>
#   3. the switch's NEW configs/<sw>.cli pushed whole (as sonic-apply.sh does; existing lines are idempotent)
#   4. checks: only the new VRF names, underlay established 4 (12 on a spine), every local ES seen on the partner (LR), the border's eBGP to the PA
#   5. reopen the drained ports, wait until every local ES is LR again and every PortChannel is oper-up, then the next switch
# EVPN matches tenants by VNI and auto route-targets, not by VRF name: a pair with one old-named and one new-named leaf keeps forwarding.
# Every drained port is reopened by an EXIT trap. Log: logs/vrf-rename-<sw>.log.
set -u
cd "$(dirname "$0")" || exit 1; . ./lib.sh; mkdir -p logs
OLD=${1:?old configs dir}; shift
SWS=("$@"); [ $# -eq 0 ] && SWS=(stor1b stor1a leaf2b leaf2a leaf4b leaf4a leaf3b leaf3a leaf1b leaf1a border2 border1)
DRAINED=""; DSW=""
ports() { local sw=$1 act=$2; shift 2; local a=("configure terminal") p; for p in "$@"; do a+=("interface $p" "$act" "exit"); done; KL $sw "${a[@]}" >> logs/vrf-rename-$sw.log 2>&1; }
cleanup() { [ -n "$DRAINED" ] && { say "trap: reopening $DSW $DRAINED"; ports $DSW "no shutdown" $DRAINED; }; }
trap cleanup EXIT
teardown() {   # teardown <old cli>: the sonic-cli lines that remove every old-VRF binding, one per line
  python3 - "$1" <<'EOF'
import re, sys
lines = [l.rstrip("\n") for l in open(sys.argv[1])]
out = ["configure terminal"]; bgp = []; vni = []; ifs = []; vrfs = []; cur = None; addr = []; bound = None
for l in lines:
    m = re.match(r"router bgp (\d+) vrf (Vrf-[ABCS])$", l)
    if m: bgp.append("no router bgp vrf %s" % m.group(2))   # Dell SONiC 4.6: no ASN in the "no" form
    m = re.match(r"map vni (\d+) vrf (Vrf-[ABCS])$", l)
    if m: vni.append("no map vni %s vrf %s" % m.groups())
    m = re.match(r"ip vrf (Vrf-[ABCS])$", l)
    if m: vrfs.append("no ip vrf %s" % m.group(1))
    if l.startswith("interface "): cur, addr, bound = l, [], None; continue
    if cur and re.match(r"ip vrf forwarding (Vrf-[ABCS])$", l): bound = l.split()[-1]
    if cur and re.match(r"ip (anycast-address|address) ", l): addr.append("no " + l)
    if cur and l == "exit":
        if bound: ifs.append([cur] + addr + ["no ip vrf forwarding %s" % bound, "exit"])
        cur = None
out += bgp
if vni: out += ["interface vxlan vtep1"] + vni + ["exit"]
for b in ifs: out += b
out += vrfs
print("\n".join(out))
EOF
}
check() {   # check <sw>: one line, the facts the rename must leave true
  local sw=$1 v u es lone bgp=""
  v=$(KL $sw "show ip vrf" | awk '$1 ~ /^Vrf-/ {print $1}' | sort | xargs)
  u=$(KL $sw "show bgp ipv4 unicast summary" | grep -o 'established [0-9]*')
  lone=$(KL $sw "show evpn es" | awk '$1 ~ /^00:/ && $2 ~ /L/ && $2 !~ /R/' | wc -l)
  case $sw in border*) for x in Vrf-Prod:1 Vrf-Dev:1 Vrf-Mgmt:1 Vrf-Svc:3; do bgp="$bgp ${x%%:*}=$(KL $sw "show bgp ipv4 unicast vrf ${x%%:*} summary" | grep -o 'established [0-9]*' | awk '{print $2}')"; done;; esac
  echo "vrfs [$v] underlay $u lone-ES $lone pc-down $(KL $sw 'show interface status' | awk '$1 ~ /^PortChannel/ && $4 != "oper-up"' | wc -l)$bgp"; }
for sw in "${SWS[@]}"; do
  L=logs/vrf-rename-$sw.log; : > $L; say "== $sw: before: $(check $sw)"
  grep -q 'ip vrf Vrf-[ABCS]$' $OLD/$sw.cli || { say "$sw: no old VRF in its old config, skipped"; continue; }
  DSW=$sw; DRAINED=$(KL $sw "show interface status" | awk '$1 ~ /^Ethernet/ && $4 == "oper-up" && $1 !~ /^Ethernet[0-3]$/ {print $1}' | xargs)
  say "$sw: drain $(echo $DRAINED | wc -w) ports"; ports $sw shutdown $DRAINED; sleep 8
  teardown $OLD/$sw.cli > logs/vrf-rename-$sw.teardown; mapfile -t TD < logs/vrf-rename-$sw.teardown
  say "$sw: teardown ($(( ${#TD[@]} - 1 )) lines)"; KL $sw "${TD[@]}" >> $L 2>&1
  mapfile -t NEW < configs/$sw.cli; say "$sw: push the new config ($(wc -l < configs/$sw.cli) lines)"; KL $sw "${NEW[@]}" >> $L 2>&1
  errs=$(grep -i -E 'error|invalid|failed' $L | grep -v -E 'error-disable|0 error' | head -5)
  [ -n "$errs" ] && say "$sw: CLI messages (see $L): $(echo $errs | head -c 300)"
  sleep 10; say "$sw: after push: $(check $sw)"
  ports $sw "no shutdown" $DRAINED; DRAINED=""
  for i in $(seq 1 40); do c=$(check $sw); echo "$c" | grep -qE 'lone-ES 0 pc-down 0' && break; sleep 6; done
  say "$sw: reopened: $c"
  echo "$c" | grep -qE 'vrfs \[(Vrf-(Dev|Mgmt|Prod|Svc) ?)+\]' && ! echo "$c" | grep -q 'Vrf-[ABCS]\b' && echo "$c" | grep -qE 'established (4|12) lone-ES 0 pc-down 0' \
    || { say "$sw: NOT clean after the rename, stopping here"; exit 1; }
  case $sw in border*) echo "$c" | grep -q 'Vrf-Prod=1 Vrf-Dev=1 Vrf-Mgmt=1 Vrf-Svc=3' || { say "$sw: PA sessions not all back, stopping"; exit 1; };; esac
done
say "done: ${SWS[*]}"
