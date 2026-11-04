#!/bin/bash
# migrate-verify.sh <switch> <want-vrfs>: after migrate-fabric.sh, judge the switch independently: its VRFs, 4 underlay + 4 EVPN sessions, no retired
# VLAN, and every line of configs/<sw>.cli present in the running config (a "interface PortChannelN fast_rate" header prints without the keyword).
cd /root/sonic-clos-dc; . ./lib.sh
sw=$1; want=$2
for i in $(seq 1 30); do
  u=$(KL $sw "show bgp ipv4 unicast summary" 2>/dev/null | grep -o 'established [0-9]*' | awk '{print $2}')
  e=$(KL $sw "show bgp l2vpn evpn summary" 2>/dev/null | grep -o 'established [0-9]*' | awk '{print $2}')
  [ "$u" = 4 ] && [ "$e" = 4 ] && break; sleep 6; done
v=$(KL $sw "show ip vrf" 2>/dev/null | awk '$1 ~ /^Vrf-/ {print $1}' | sort | xargs)
vl=$(KL $sw "show vlan" 2>/dev/null | grep -oE '^\s*[0-9]+' | xargs)
ret=$(echo $vl | tr ' ' '\n' | grep -xE '100|104|106|107|111|112|113|211|212|213' | xargs)
KL $sw "show running-configuration" > logs/migrate-verify-$sw.running 2>&1
miss=$(python3 - $sw <<'EOF'
import re, sys
sw = sys.argv[1]
cli = [l.strip() for l in open("configs/%s.cli" % sw) if l.strip() and l.strip() not in ("exit", "end", "!", "configure terminal", "write memory")]
def norm(s):
    s = re.sub(r"Loopback ?(\d+)", r"Loopback \1", re.sub(r"\s+", " ", s.strip()))
    m = re.match(r"^(switchport trunk allowed Vlan (?:add |remove )?)([\d,\-]+)$", s)   # the switch prints a VLAN list sorted
    if not m: return s
    v = set()
    for x in m.group(2).split(","):   # the switch also compresses runs into ranges (3001-3004)
        a, _, b = x.partition("-"); v.update(range(int(a), int(b or a) + 1))
    return m.group(1) + ",".join(str(x) for x in sorted(v))
run = set(norm(l) for l in open("logs/migrate-verify-%s.running" % sw))
m = [l for l in cli if norm(l) not in run and not re.match(r"^interface PortChannel\d+ fast_rate$", l)]
print(len(m), "|".join(m[:6]))
EOF
)
ok=yes; [ "$v" = "$want" ] || ok=no; [ "$u" = 4 ] && [ "$e" = 4 ] || ok=no; [ -z "$ret" ] || ok=no; [ "${miss%% *}" = 0 ] || ok=no
echo "$sw: vrfs [$v] (want [$want]) underlay $u evpn $e vlans [$vl] retired [${ret}] missing ${miss} => $ok"
[ $ok = yes ]
