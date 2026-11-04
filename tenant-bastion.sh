#!/bin/bash
# tenant-bastion.sh up|status|down [prod|dev ...]: one bastion per tenant. bastion-<t> installs and operates its tenant's OpenShift
# cluster (root: openshift-install agent wait-for, oc, helm; agent-<t> mounted as /w/agent, KUBECONFIG /w/agent/build/auth/kubeconfig) and is the
# only way a LAN user loads images into the tenant's Harbor and objects into its MinIO (<t>-ops over SSH through the PA-VM, key only).
# It is a containerlab node (image scd/tenant-bastion:2; management 172.21.30.139 / .140) with its own cable bastion-<t>:eth1 <->
# probe-<t>:eth3; probe-<t> bridges eth3 with its LACP bond (br0), so the bastion sits on the tenant VLAN 102 / 202 behind the rack pair:
# 10.0.2.11/24 in BOTH tenants, gateway 10.0.2.1. sshd listens on that address only.
# A fresh `containerlab deploy` builds all of it from sonic-clos-dc.clab.yml (gen.py); on a running lab `up` (re)creates what is missing or
# outdated the same way containerlab would (its labels, management address, binds, env from nodes.json, the veth), as node-recreate.sh does.
# The ops user's key pair is made here, under /root/scd-secrets/bastion (mode 600, never printed); the tools' credentials are loaded by
# tenant-apps.sh <t> bastion. Idempotent.
cd "$(dirname "$0")"; . ./lib.sh
ACT=${1:-status}; shift; TS=${*:-$TENANTS}
IMG=scd/tenant-bastion:2; KEYS=$SECRETS/bastion; TOPOF=$PWD/$TOPO
MGMT=$(python3 -c "import json; print(json.load(open('nodes.json'))['mgmt'])")
spec() { python3 -c "import json,sys; s=json.load(open('nodes.json'))['nodes']['bastion-$1']; print(s$2)"; }
probe_bridge() {   # the running probe-<t> keeps its address on br0 (bond0 + eth3), as host-up.sh does at boot with BRIDGE=eth3
  local t=$1 ip gw; ip=$(python3 -c "import json; print(json.load(open('nodes.json'))['nodes']['probe-$t']['env']['IP'])"); gw=${ip%.*/*}.1
  docker exec $C-probe-$t sh -c "ip link show br0 >/dev/null 2>&1 || { ip link add br0 type bridge && ip link set br0 mtu 9000 && ip link set br0 up \
    && ip link set bond0 master br0 && ip addr del $ip dev bond0 && ip addr add $ip dev br0 && ip route replace default via $gw dev br0; }
    ip link set eth3 mtu 9000 && ip link set eth3 master br0 && ip link set eth3 up"
}
for t in $TS; do n=$C-bastion-$t; ip=$(spec $t "['env']['IP']"); ip=${ip%/*}; gw=$(spec $t "['env']['GW']")
  case $ACT in
  up)
    docker build --network host -q -t $IMG images/tenant-bastion >/dev/null || { say "build $IMG failed"; exit 1; }   # cached unless the files changed
    install -d -m 700 $KEYS; [ -s $KEYS/$t-ops ] || ssh-keygen -q -t ed25519 -N '' -C "$t-ops@bastion-$t" -f $KEYS/$t-ops; chmod 600 $KEYS/$t-ops $KEYS/$t-ops.pub
    mkdir -p agent-$t
    want_env=$(python3 -c "import json; s=json.load(open('nodes.json'))['nodes']['bastion-$t']; print(' '.join('%s=%s' % kv for kv in sorted(s['env'].items())))")
    have_env=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' $n 2>/dev/null | grep -E "^($(python3 -c "import json; print('|'.join(json.load(open('nodes.json'))['nodes']['bastion-$t']['env']))"))=" | sort | paste -sd' ')
    if ! docker inspect $n >/dev/null 2>&1 || [ "$(docker inspect -f '{{.Config.Image}}' $n)" != "$IMG" ] || \
       [ "$(docker inspect -f '{{.Image}}' $n)" != "$(docker image inspect -f '{{.Id}}' $IMG)" ] || [ "$want_env" != "$have_env" ]; then
      docker rm -f $n >/dev/null 2>&1; mkdir -p $C/bastion-$t
      mapfile -t A < <(python3 - "$t" "$PWD" <<'EOF'
import json, os, sys
t, d = sys.argv[1:3]; s = json.load(open(os.path.join(d, "nodes.json")))["nodes"]["bastion-" + t]
for k, v in sorted(s["env"].items()): print("-e"); print("%s=%s" % (k, v))
for b in s["binds"]:
    src, rest = b.split(":", 1); print("-v"); print("%s:%s" % (src if src.startswith("/") else os.path.join(d, src), rest))
EOF
)
      docker run -d --name $n --hostname bastion-$t --network $C --ip $MGMT.$(spec $t "['mgmt']") --privileged --restart always \
        --label containerlab=$LAB --label clab-node-name=bastion-$t --label clab-node-longname=$n --label clab-node-kind=linux --label clab-node-type= \
        --label clab-node-group=bastions --label clab-node-lab-dir=$PWD/$C/bastion-$t --label clab-topo-file=$TOPOF --label clab-owner=root \
        "${A[@]}" $IMG >/dev/null && say "bastion-$t: containerlab node (re)created ($IMG, management $MGMT.$(spec $t "['mgmt']"), $ip)"
    fi
    [ "$(docker inspect -f '{{.State.Running}}' $n)" = true ] || docker start $n >/dev/null
    docker exec $n test -e /sys/class/net/eth1 || containerlab tools veth create -a $C-probe-$t:eth3 -b $n:eth1 --mtu 9500 2>&1 | tail -1
    probe_bridge $t
    # a re-made cable (probe-<t> re-created) arrives without the address the init set at start: apply the tenant address and route again
    docker exec $n sh -c "ip link set eth1 mtu 9000; ip link set eth1 up; ip addr replace $ip/24 dev eth1; ip route replace default via $gw dev eth1"
    for i in $(seq 1 30); do X bastion-$t "ping -c1 -W1 $gw" >/dev/null && break; sleep 2; done
    say "bastion-$t: $ip on its cable to probe-$t (br0), gateway $(X bastion-$t "ping -c1 -W1 $gw >/dev/null && echo up || echo DOWN"), sshd on $(X bastion-$t "ss -ltnH 2>/dev/null | grep -oE '[0-9.]+:22 ' | xargs"), oc $(X bastion-$t 'oc version --client 2>/dev/null | head -1')" ;;
  status)
    say "bastion-$t: $(docker inspect -f '{{.State.Status}} {{.Config.Image}} clab={{index .Config.Labels "containerlab"}}' $n 2>/dev/null || echo absent), $(X bastion-$t 'ip -br -4 addr show eth1' 2>/dev/null | awk '{print $1, $3}'), probe br0: $(X probe-$t 'bridge link 2>/dev/null | grep -o "^[0-9]*: [a-z0-9@]*" | paste -sd" "'), key $([ -s $KEYS/$t-ops ] && echo present || echo missing), kubeconfig $(X bastion-$t 'test -s /w/agent/build/auth/kubeconfig && echo present || echo absent')" ;;
  down) docker stop $n >/dev/null 2>&1; say "bastion-$t stopped" ;;
  *) echo "usage: $0 up|status|down [prod|dev ...]"; exit 2 ;;
  esac
done
