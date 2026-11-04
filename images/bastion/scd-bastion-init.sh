#!/bin/bash
# PID 1 of a sonic-clos-dc bastion. env: TENANT_IP (10.0.4.10), TENANT_GW, C_IP (Vrf-Mgmt address on eth3), DNS (space list)
# bond0 = eth1 + eth2 (LACP fast) in the tenant VRF, default route via the tenant gateway; eth3 in Vrf-Mgmt (connected route only);
# eth0 (clab management) keeps its own table 200 so the lab host can always reach the bastion. Never exits.
set +e; trap '' TERM HUP
log() { echo "[bastion] $*"; }
for i in $(seq 1 240); do ip link show eth1 >/dev/null 2>&1 && ip link show eth2 >/dev/null 2>&1 && ip link show eth3 >/dev/null 2>&1 && break; sleep 1; done
if ! ip link show bond0 >/dev/null 2>&1; then
  ip link add bond0 type bond mode 802.3ad lacp_rate fast miimon 100 xmit_hash_policy layer3+4
  for e in eth1 eth2; do ethtool -K $e tx off >/dev/null 2>&1; ip link set $e down; ip link set $e master bond0; ip link set $e mtu 9000; ip link set $e up; done
  ip link set bond0 mtu 9000; ip link set bond0 up
fi
ip addr replace "$TENANT_IP/24" dev bond0
MGMT_IP=$(ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1 | head -1); MGMT_GW=$(ip -4 route show default dev eth0 | awk '{print $3}' | head -1)
if [ -n "$MGMT_GW" ]; then
  ip route replace default via "$MGMT_GW" dev eth0 table 200; ip rule add from "$MGMT_IP" lookup 200 2>/dev/null
  ip route del default via "$MGMT_GW" dev eth0 2>/dev/null
fi
ip route replace default via "$TENANT_GW" dev bond0
ethtool -K eth3 tx off >/dev/null 2>&1; ip link set eth3 up; ip addr replace "$C_IP/24" dev eth3
: > /etc/resolv.conf; for d in $DNS; do echo "nameserver $d" >> /etc/resolv.conf; done; echo "search ${SEARCH:-dc.lab}" >> /etc/resolv.conf
log "tenant $TENANT_IP via $TENANT_GW, Vrf-Mgmt $C_IP, management $MGMT_IP (table 200), DNS $DNS"
# ssh by key only (put keys in /root/.ssh/authorized_keys or /home/admin/.ssh/authorized_keys), on the management address; a login gets this
# cluster's kubeconfig (root reads the mounted one, admin a copy in ~/.kube once the install has written it)
echo 'export KUBECONFIG=$HOME/.kube/config' > /etc/profile.d/zz-scd-kube.sh
grep -q zz-scd-kube /etc/bash.bashrc || echo "[ -r /etc/profile.d/zz-scd-kube.sh ] && . /etc/profile.d/zz-scd-kube.sh   # also for interactive non-login shells (docker exec bash)" >> /etc/bash.bashrc
mkdir -p /root/.kube; ln -sfn /w/agent/build/auth/kubeconfig /root/.kube/config
kube_admin() { [ -f /w/agent/build/auth/kubeconfig ] && ! cmp -s /w/agent/build/auth/kubeconfig /home/admin/.kube/config && {
  install -d -o admin -g admin -m 700 /home/admin/.kube; install -o admin -g admin -m 600 /w/agent/build/auth/kubeconfig /home/admin/.kube/config; }; }
mkdir -p /run/sshd; /usr/sbin/sshd && log "sshd up on $MGMT_IP"
while true; do pgrep -x sshd >/dev/null || /usr/sbin/sshd; kube_admin; sleep 30; done
