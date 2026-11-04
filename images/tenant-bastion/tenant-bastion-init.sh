#!/bin/bash
# PID 1 of bastion-<t> (image scd/tenant-bastion:2). env: TENANT, IP (10.0.2.11/24), GW (10.0.2.1), HARBOR_IP (10.0.1.203), DNS, SEARCH,
# KUBECONFIG (/w/agent/build/auth/kubeconfig). Two jobs, two users:
#   root     the cluster's installer and oc host, reached from the lab host only (docker exec): openshift-install agent wait-for, oc, helm, skopeo for the
#            internal registry; the kubeconfig the install writes into /w/agent/build/auth (agent-<t> on the lab host)
#   <t>-ops  the tenant's loading path for Harbor / MinIO: key-only SSH from the LAN through the PA-VM (.142 / .143 :22), sshd on the
#            tenant address only, AllowUsers <t>-ops, no root, no passwords
# Network: eth1 = the containerlab cable to probe-<t>:eth3 (the probe bridges it onto its LACP bond, VLAN 102 / 202 in the tenant VRF);
# eth0 (management) keeps its own table 200 so the lab host can always reach the container. Never exits.
set +e; trap '' TERM HUP
U=$TENANT-ops
log() { echo "[bastion-$TENANT] $*"; }
for i in $(seq 1 120); do [ -e /sys/class/net/eth1 ] && break; sleep 1; done
ip link set eth1 mtu 9000; ip link set eth1 up; ip addr replace $IP dev eth1
MGMT_IP=$(ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1 | head -1); MGMT_GW=$(ip -4 route show default dev eth0 | awk '{print $3}' | head -1)
if [ -n "$MGMT_GW" ]; then
  ip route replace default via "$MGMT_GW" dev eth0 table 200; ip rule add from "$MGMT_IP" lookup 200 2>/dev/null
  ip route del default via "$MGMT_GW" dev eth0 2>/dev/null
fi
ip route replace default via $GW dev eth1   # the tenant VRF: its cluster, DNS / NTP and egress through its own PA-VM virtual router
: > /etc/resolv.conf; for d in ${DNS:-10.250.0.11 10.250.0.12}; do echo "nameserver $d" >> /etc/resolv.conf; done
echo "search ${SEARCH:-$TENANT.dc.lab dc.lab}" >> /etc/resolv.conf
# /etc/hosts is docker's bind mount: rewritten in place, never replaced
{ grep -v " harbor.$TENANT.dc.lab\$" /etc/hosts; echo "$HARBOR_IP harbor.$TENANT.dc.lab"; } > /tmp/hosts && cat /tmp/hosts > /etc/hosts && rm -f /tmp/hosts
# root: the cluster's kubeconfig once the install wrote it
mkdir -p /root/.kube; ln -sfn ${KUBECONFIG:-/w/agent/build/auth/kubeconfig} /root/.kube/config
echo "export KUBECONFIG=${KUBECONFIG:-/w/agent/build/auth/kubeconfig}" > /etc/profile.d/zz-scd-kube.sh
grep -q zz-scd-kube /etc/bash.bashrc || echo "[ -r /etc/profile.d/zz-scd-kube.sh ] && . /etc/profile.d/zz-scd-kube.sh   # also for interactive non-login shells (docker exec bash)" >> /etc/bash.bashrc
# the ops user: key only (no password at all, but not a locked account: sshd refuses locked accounts even with a key)
id $U >/dev/null 2>&1 || useradd -m -s /bin/bash -c "operations, tenant $TENANT" $U
usermod -p '*' $U
install -d -o $U -g $U -m 700 /home/$U/.ssh; install -o $U -g $U -m 600 /etc/scd/authorized_keys /home/$U/.ssh/authorized_keys
# the base image's interactive accounts get no password login here (keys only)
for a in admin; do id $a >/dev/null 2>&1 && usermod -L $a; done
mkdir -p /run/sshd; ssh-keygen -A >/dev/null
printf 'ListenAddress %s\nPermitRootLogin no\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nPubkeyAuthentication yes\nAllowUsers %s\n' \
  "${IP%/*}" "$U" > /etc/ssh/sshd_config.d/10-scd-bastion.conf   # the tenant address only (Ubuntu reads sshd_config.d first: first value wins)
log "tenant $IP via $GW, management $MGMT_IP (table 200), ops user $U, harbor.$TENANT.dc.lab = $HARBOR_IP, kubeconfig ${KUBECONFIG:-/w/agent/build/auth/kubeconfig}"
while true; do pgrep -x sshd >/dev/null || /usr/sbin/sshd; sleep 30; done
