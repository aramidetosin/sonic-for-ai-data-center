#!/bin/bash
# host-up.sh: sonic-clos-dc test host / svc node (env IP, GW, BOND, BRIDGE): bond0 = eth1 + eth2 (LACP fast) or eth1 alone; default via the
# fabric; resolver dns-ntp1/dns-ntp2; busybox httpd answers "<hostname> <ip>" on the tenant address (the isolation proof)
set -e
for i in eth1 eth2; do ethtool -K $i tx off >/dev/null 2>&1 || true; done
if [ "$BOND" = 1 ]; then
  ip link add bond0 type bond mode 802.3ad lacp_rate fast miimon 100 xmit_hash_policy layer3+4
  for i in eth1 eth2; do ip link set $i down; ip link set $i master bond0; done
  DEV=bond0
else DEV=eth1; fi
if [ -n "${BRIDGE:-}" ]; then   # probes: br0 = the uplink + the bastion's cable(s), the address on br0
  ip link set $DEV mtu 9000; ip link set $DEV up
  ip link add br0 type bridge; ip link set br0 mtu 9000; ip link set $DEV master br0
  for i in $BRIDGE; do ip link set $i mtu 9000 2>/dev/null && ip link set $i master br0 && ip link set $i up; done
  DEV=br0
fi
ip link set $DEV mtu 9000; ip link set $DEV up; ip addr add $IP dev $DEV
ip route replace default via $GW dev $DEV
printf 'nameserver 10.250.0.11\nnameserver 10.250.0.12\nsearch dc.lab\n' > /etc/resolv.conf
mkdir -p /www && echo "$(hostname) ${IP%/*}" > /www/index.html && httpd -p ${IP%/*}:80 -h /www
# ssh as on the bastions (admin/admin, root/CHANGE_ME_HOST_ROOT_PW, LAB values), reached on the management address
id admin >/dev/null 2>&1 || adduser -D -s /bin/bash admin
echo admin:admin | chpasswd; echo root:CHANGE_ME_HOST_ROOT_PW | chpasswd
ssh-keygen -A >/dev/null
sed -i -e 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
pgrep -x sshd >/dev/null || /usr/sbin/sshd
