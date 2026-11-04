#!/bin/bash
# tenant-bastion.sh up|status|down [prod|dev ...]: one bastion per tenant, the only way a LAN user loads images into the tenant's Harbor
# and objects into its MinIO. bastion-<t> is a containerlab node of the topology (image scd/tenant-bastion:1: sshd, skopeo, mc; management
# 172.21.30.139 / .140) with its own cable bastion-<t>:eth1 <-> probe-<t>:eth3; probe-<t> bridges eth3 with its LACP bond (br0), so the bastion
# sits on the tenant access VLAN 112 / 212 behind the rack pair: 10.x0.2.11/24, gateway 10.x0.2.1. sshd listens on that address only.
# A fresh `containerlab deploy` builds all of it from sonic-clos-dc.clab.yml (gen.py); on a running lab `up` creates what is missing the same
# way containerlab would (its labels, management address, the veth), as node-resize.sh does for a switch. The ops user's key pair is made here,
# under /root/scd-secrets/bastion (mode 600, never printed); the tools' credentials are loaded by tenant-apps.sh <t> bastion. Idempotent.
cd "$(dirname "$0")"; . ./lib.sh
ACT=${1:-status}; shift; TS=${*:-prod dev}
declare -A P=([prod]=10.10 [dev]=10.20) M=([prod]=139 [dev]=140)
IMG=scd/tenant-bastion:1; KEYS=/root/scd-secrets/bastion; TOPO=$PWD/sonic-clos-dc.clab.yml
MGMT=$(awk '$2=="fw-pa" {split($1, a, "."); print a[1]"."a[2]"."a[3]}' mgmt-hosts.txt)   # the management /24 (gen.py MGMT)
probe_bridge() {   # the running probe-<t> moves its address from bond0 to br0 (bond0 + eth3), as host-up.sh does at boot with BRIDGE=eth3
  local t=$1 ip=${P[$1]}.2.10/24 gw=${P[$1]}.2.1
  docker exec $C-probe-$t sh -c "ip link show br0 >/dev/null 2>&1 || { ip link add br0 type bridge && ip link set br0 mtu 9000 && ip link set br0 up \
    && ip link set bond0 master br0 && ip addr del $ip dev bond0 && ip addr add $ip dev br0 && ip route replace default via $gw dev br0; }
    ip link set eth3 mtu 9000 && ip link set eth3 master br0 && ip link set eth3 up"
}
for t in $TS; do n=$C-bastion-$t; ip=${P[$t]}.2.11
  case $ACT in
  up)
    docker build --network host -q -t $IMG images/tenant-bastion >/dev/null || { say "build $IMG failed"; exit 1; }   # cached unless the files changed
    install -d -m 700 $KEYS; [ -s $KEYS/$t-ops ] || ssh-keygen -q -t ed25519 -N '' -C "$t-ops@bastion-$t" -f $KEYS/$t-ops; chmod 600 $KEYS/$t-ops $KEYS/$t-ops.pub
    # a container that is not a containerlab node (no containerlab label, macvlan network) is replaced
    if docker inspect $n >/dev/null 2>&1 && [ -z "$(docker inspect -f '{{index .Config.Labels "containerlab"}}' $n)" ]; then
      docker rm -f $n >/dev/null && say "bastion-$t: the pre-containerlab container removed"; fi
    if ! docker inspect $n >/dev/null 2>&1 || [ "$(docker inspect -f '{{.Config.Image}}' $n)" != "$IMG" ] || \
       [ "$(docker inspect -f '{{.Image}}' $n)" != "$(docker image inspect -f '{{.Id}}' $IMG)" ]; then
      docker rm -f $n >/dev/null 2>&1; mkdir -p clab-$LAB/bastion-$t
      docker run -d --name $n --hostname bastion-$t --network clab-$LAB --ip $MGMT.${M[$t]} --privileged --restart always \
        --label containerlab=$LAB --label clab-node-name=bastion-$t --label clab-node-longname=$n --label clab-node-kind=linux --label clab-node-type= \
        --label clab-node-group=bastions --label clab-node-lab-dir=$PWD/clab-$LAB/bastion-$t --label clab-topo-file=$TOPO --label clab-owner=root \
        -e TENANT=$t -e IP=$ip/24 -e GW=${P[$t]}.2.1 -e HARBOR_IP=${P[$t]}.1.203 -v $KEYS/$t-ops.pub:/etc/scd/authorized_keys:ro $IMG >/dev/null \
        && say "bastion-$t: containerlab node created (management $MGMT.${M[$t]})"
    fi
    [ "$(docker inspect -f '{{.State.Running}}' $n)" = true ] || docker start $n >/dev/null
    docker exec $n test -e /sys/class/net/eth1 || containerlab tools veth create -a $C-probe-$t:eth3 -b $n:eth1 --mtu 9500 2>&1 | tail -1
    probe_bridge $t
    for i in $(seq 1 30); do X bastion-$t "ping -c1 -W1 ${P[$t]}.2.1" >/dev/null && break; sleep 2; done
    say "bastion-$t: $ip on its cable to probe-$t (br0), gateway $(X bastion-$t "ping -c1 -W1 ${P[$t]}.2.1 >/dev/null && echo up || echo DOWN"), sshd on $(X bastion-$t "ss -ltnH 2>/dev/null | grep -oE '[0-9.]+:22 ' | xargs")" ;;
  status)
    say "bastion-$t: $(docker inspect -f '{{.State.Status}} clab={{index .Config.Labels "containerlab"}}' $n 2>/dev/null || echo absent), $(X bastion-$t 'ip -br -4 addr show eth1' 2>/dev/null | awk '{print $1, $3}'), probe br0: $(X probe-$t 'bridge link 2>/dev/null | grep -o "^[0-9]*: [a-z0-9@]*" | paste -sd" "'), key $([ -s $KEYS/$t-ops ] && echo present || echo missing)" ;;
  down) docker stop $n >/dev/null 2>&1; say "bastion-$t stopped" ;;
  *) echo "usage: $0 up|status|down [prod|dev ...]"; exit 2 ;;
  esac
done
