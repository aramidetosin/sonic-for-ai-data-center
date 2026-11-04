#!/bin/bash
# validate-rails.sh [control|data|all]: the GPU backend, one PASS/FAIL line each -> results/<lab>_rails-<part>_<ts>/result.txt.
# control = the 12 rail switches; data = the GPU workers over the rails (needs the gpu cluster).
cd "$(dirname "$0")"; . ./lib.sh
PART=${1:-all}; P=0; F=0; K=0; RD=$(resdir rails-$PART); OUT=$RD/result.txt; CMDLOG=$PWD/$RD/commands.txt; : > $OUT; : > $CMDLOG
log() { echo "$*" | tee -a $OUT; }
ok() { if [ "$2" = 0 ]; then log "PASS  $1"; P=$((P+1)); else log "FAIL  $1  ($3)"; F=$((F+1)); fi; }
known() { log "KNOWN $1  ($2)"; K=$((K+1)); }
want() { local got; got=$(eval "$2" 2>&1); echo "$got" | grep -q -E "$3"; ok "$1" $? "got: $(echo $got | head -c 140)"; }
deny() { local got; got=$(eval "$2" 2>&1); if echo "$got" | grep -q -E "$3"; then ok "$1" 1 "reached: $(echo $got | head -c 90)"; else ok "$1" 0; fi; }
SSHC() { ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8 core@"$(mip $1)" "$2" </dev/null 2>&1; }
OCG() { docker exec -i $C-bastion-ocp oc "$@" 2>&1; }
SPINES="rail-spine1 rail-spine2 rail-spine3 rail-spine4"; LEAVES="rail-leaf1 rail-leaf2 rail-leaf3 rail-leaf4 rail-leaf5 rail-leaf6 rail-leaf7 rail-leaf8"
W=(gpu-worker1 gpu-worker2 gpu-worker3 gpu-worker4 gpu-worker5 gpu-worker6 gpu-worker7 gpu-worker8)

if [ $PART = control ] || [ $PART = all ]; then
log "== rails: control plane and RoCE configuration (Dell Enterprise SONiC 4.6.0)"
for s in $SPINES; do want "$s: 8 rail leaves, eBGP unnumbered up" "KL $s 'show bgp ipv4 unicast summary'" "established 8"; done
for l in $LEAVES; do r=${l#rail-leaf}
  want "$l: 4 rail spines, eBGP unnumbered up" "KL $l 'show bgp ipv4 unicast summary'" "established 4"
  ecmp() { SW $1 'sudo vtysh -c "show ip route bgp"' | awk '/^B/ {p = ($2 ~ /^172\.16\./) ? $2 : ""} p && /via fe80/ {n[p]++} END {for (k in n) c[n[k]]++; for (k in c) printf "%d prefixes x %d paths\n", c[k], k}'; }
  want "$l: the other 7 rails learned, each over 4 spines (ECMP)" "ecmp $l" "^7 prefixes x 4 paths$"
  want "$l: rail $r gateway 172.16.$r.1/24 on Vlan$((r * 10)), MTU 9100" "SW $l 'ip -br addr show Vlan$((r * 10)); cat /sys/class/net/Vlan$((r * 10))/mtu'" "172\\.16\\.$r\\.1/24.*9100|9100"
  want "$l: Dell RoCE profile (roce enable)" "SW $l 'sonic-cli -c \"show running-configuration\"' | grep -x 'roce enable'" "roce enable"
  want "$l: PFC priorities 3,4 on the GPU ports (CONFIG_DB PORT_QOS_MAP)" "SW $l 'for p in 4 5 6 7 8 9 10 11; do redis-cli -n 4 hget \"PORT_QOS_MAP|Ethernet\$p\" pfc_enable; done | sort | uniq -c'" "^ *8 3,4$"
  want "$l: WRED/ECN profile ROCE (ecn_all)" "SW $l 'redis-cli -n 4 hget \"WRED_PROFILE|ROCE\" ecn'" "^ecn_all$"
done
fi

if [ $PART = data ] || [ $PART = all ]; then
log "== rails: GPU workers over the rails"
for w in "${W[@]}"; do
  want "$w: 8 rail NICs up with their rail address (172.16.r.$((10 + ${w#gpu-worker})))" "SSHC ocp-$w 'for r in 1 2 3 4 5 6 7 8; do ip -br -4 addr show enp0s\$((5 + r)); done' | grep -c ' UP .*172\\.16\\.[1-8]\\.$((10 + ${w#gpu-worker}))/24'" "^8$"
  want "$w: 8 SoftRoCE devices ACTIVE (rxe_rail1-8)" "SSHC ocp-$w 'rdma link show' | grep -c 'rxe_rail[1-8]/1 state ACTIVE'" "^8$"
  want "$w: nvidia.com/gpu allocatable 8 (simulated)" "OCG get node $w -o jsonpath='{.status.allocatable.nvidia\\.com/gpu}'" "^8$"
done
for r in 1 2 3 4 5 6 7 8; do   # same rail, worker1 <-> worker8: bridged on rail-leaf r, jumbo DF
  want "rail $r: worker1 -> worker8 jumbo 8972 DF (same rail)" "SSHC ocp-gpu-worker1 'ping -c3 -W2 -M do -s 8972 -I 172.16.$r.11 172.16.$r.18'" " 0% packet loss"
done
want "cross rail 1 -> 2: worker1 -> worker2 jumbo 8972 DF over a rail spine" "SSHC ocp-gpu-worker1 'ping -c3 -W2 -M do -s 8972 -I 172.16.1.11 172.16.2.12'" " 0% packet loss"
# the rail-1 address routes by source (table 101) via rail-leaf1; no traceroute on RHCOS and the unnumbered spines send no time-exceeded:
# TTL 3 must not arrive, TTL 4 must, and the answer comes back with TTL 61 (64 - 3 routed hops: rail-leaf1, a rail spine, rail-leaf2)
want "cross rail 1 -> 2: 3 routed hops (rail-leaf1, a rail spine, rail-leaf2): TTL 3 does not arrive, TTL 4 does, answered with TTL 61" "SSHC ocp-gpu-worker1 'ping -c1 -W2 -t 3 -I 172.16.1.11 172.16.2.12 | grep -c \"bytes from\"; ping -c1 -W2 -t 4 -I 172.16.1.11 172.16.2.12 | grep -o \"ttl=[0-9]*\"' | paste -sd' '" "^0 ttl=61$"
deny "a rail address cannot reach the front end (10.0.1.1): rails carry no route out" "SSHC ocp-gpu-worker1 'ping -c2 -W1 -I 172.16.1.11 10.0.1.1'" " [12] received"
fi

log "RESULT: $P passed, $F failed, $K known platform limitation(s) ($RD)"
[ $F = 0 ]
