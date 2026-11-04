#!/bin/bash
# relink.sh <nodeA>:<ethA> <nodeB>:<ethB> [...]: re-create containerlab links lost when a node container was stopped (its veth pairs die with it,
# and `containerlab restart` of a stopped node does not bring them back). Each pair: a new veth, then on every side whose VM already runs
# (a tapN beside ethN, vrnetlab tc mode) the clsact ingress redirect ethN <-> tapN is (re)made, replacing the tap's filter that pointed at the
# deleted device; on an RHCOS node container (taps in bridges) ethN joins its bridge brN instead. A side whose launcher is still waiting for
# its interfaces (no tapN yet) is left to the launcher.
cd "$(dirname "$0")"; . ./lib.sh
side() {   # side <node> <ethN>: wire ethN to tapN inside the node, if the VM is up
  local n=$1 e=$2 t=tap${2#eth} m br
  # a Linux host container (bastion, probe, dns-ntp: scd/host, BOND=1) bonds eth1 / eth2 itself: those go back into bond0; any other NIC of
  # it (eth3, a bastion's Vrf-Mgmt NIC) is a plain interface, and its own init gives it the address
  if docker exec $C-$n test -d /sys/class/net/bond0 2>/dev/null && ! docker exec $C-$n test -e /sys/class/net/$t && [ $e != eth1 ] && [ $e != eth2 ]; then
    docker exec $C-$n ip link set $e up; echo "  $n:$e up (not bonded)"; return; fi
  if docker exec $C-$n test -d /sys/class/net/bond0 2>/dev/null && ! docker exec $C-$n test -e /sys/class/net/$t; then
    docker exec $C-$n sh -c "m=\$(cat /sys/class/net/bond0/mtu); ip link set $e down; ip link set $e mtu \$m; ip link set $e master bond0; ip link set $e up"
    echo "  $n:$e in bond0 ($(docker exec $C-$n grep -c 'Slave Interface' /proc/net/bonding/bond0) slaves)"; return; fi
  docker exec $C-$n ip link show $t >/dev/null 2>&1 || { echo "  $n:$e: no $t (launcher will wire it)"; return; }
  # an RHCOS node container (images/rhcos-node/vm-init.sh) bridges ethN and tapN in brN (LACP frames forwarded: group_fwd_mask): join the bridge
  br=$(docker exec $C-$n sh -c "basename \$(readlink /sys/class/net/$t/master) 2>/dev/null")
  if [ -n "$br" ]; then m=$(docker exec $C-$n cat /sys/class/net/$t/mtu)
    docker exec $C-$n sh -c "tc filter del dev $t ingress 2>/dev/null; tc filter del dev $e ingress 2>/dev/null; ip link set $e mtu $m; ip link set $e master $br; ip link set $e up"
    echo "  $n:$e in $br with $t (mtu $m)"; return; fi
  m=$(docker exec $C-$n cat /sys/class/net/$t/mtu)
  docker exec $C-$n sh -c "ip link set $e mtu $m up; tc qdisc add dev $e clsact 2>/dev/null; tc filter del dev $e ingress 2>/dev/null
    tc filter add dev $e ingress flower action mirred egress redirect dev $t; tc filter del dev $t ingress 2>/dev/null
    tc filter add dev $t ingress flower action mirred egress redirect dev $e"
  echo "  $n:$e <-> $t (mtu $m): $(docker exec $C-$n tc filter show dev $t ingress | grep -o "Redirect to device [a-z0-9*]*")"
}
while [ $# -ge 2 ]; do
  A=$1; Bp=$2; shift 2
  say "link $A <-> $Bp"
  # one end missing and the other still present = the present end is an orphaned veth (its peer died with the old container but the
  # interface lingers): veth create would fail on the name and the tc redirect would point at the orphan; delete it first
  ha=$(docker exec $C-${A%%:*} test -e /sys/class/net/${A#*:} && echo 1 || echo 0); hb=$(docker exec $C-${Bp%%:*} test -e /sys/class/net/${Bp#*:} && echo 1 || echo 0)
  [ $ha = 1 ] && [ $hb = 0 ] && docker exec $C-${A%%:*} ip link del ${A#*:} && echo "  ${A}: orphaned end removed"
  [ $hb = 1 ] && [ $ha = 0 ] && docker exec $C-${Bp%%:*} ip link del ${Bp#*:} && echo "  ${Bp}: orphaned end removed"
  containerlab tools veth create -a $C-${A%%:*}:${A#*:} -b $C-${Bp%%:*}:${Bp#*:} 2>&1 | tail -1
  side ${A%%:*} ${A#*:}; side ${Bp%%:*} ${Bp#*:}
done
