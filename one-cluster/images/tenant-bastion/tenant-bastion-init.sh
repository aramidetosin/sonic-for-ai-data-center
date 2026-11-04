#!/bin/bash
# PID 1 of bastion-<t>. env: TENANT, IP, GW, HARBOR_IP. Its network is its own cable eth1 (containerlab link to probe-<t>:eth3, which
# the probe bridges onto its bond); here: the address and route, the ops user (key only, from /etc/scd/authorized_keys), sshd (no passwords, no root), DNS, Harbor's name pinned
# to its LoadBalancer address in the tenant VRF. Never exits.
set +e; trap '' TERM HUP
U=$TENANT-ops
# its cable: eth1 (containerlab links it after the start: wait), the tenant address, default route into the tenant VRF (not the management net)
for i in $(seq 1 120); do [ -e /sys/class/net/eth1 ] && break; sleep 1; done
ip link set eth1 mtu 9000; ip link set eth1 up; ip addr replace $IP dev eth1; ip route replace default via $GW dev eth1
printf 'nameserver 10.250.0.11\nnameserver 10.250.0.12\nsearch %s.dc.lab dc.lab\n' "$TENANT" > /etc/resolv.conf
grep -q " harbor.$TENANT.dc.lab" /etc/hosts || echo "$HARBOR_IP harbor.$TENANT.dc.lab" >> /etc/hosts
id $U >/dev/null 2>&1 || adduser -D -s /bin/bash -g "operations, tenant $TENANT" $U
sed -i "s/^$U:!:/$U:*:/" /etc/shadow   # no password at all, but not a locked account (sshd refuses locked accounts even with a key)
install -d -o $U -g $U -m 700 /home/$U/.ssh; install -o $U -g $U -m 600 /etc/scd/authorized_keys /home/$U/.ssh/authorized_keys
ssh-keygen -A >/dev/null
printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no\nPubkeyAuthentication yes\nAllowUsers %s\nListenAddress %s\n' "$U" "${IP%/*}" > /etc/ssh/sshd_config.d/10-scd-bastion.conf   # the tenant address only
echo "[bastion-$TENANT] ops user $U, harbor.$TENANT.dc.lab = $HARBOR_IP"
while true; do pidof sshd >/dev/null || /usr/sbin/sshd; sleep 30; done
