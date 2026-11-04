#!/bin/bash
# lan-client-up.sh: client-lan1 / client-lan2, a user on the external LAN beyond the PA-VM (env IP, GW). Reaches BOTH clusters only through the
# PA-VM's outside addresses: the apps on .142 (prod) / .143 (dev) > the F5 VIP, console and OAuth on .144 > the router.
# Names come from /etc/hosts (as on the Windows server), the resolver is the outside LAN's DNS (dns02 192.168.100.53).
set -e
ethtool -K eth1 tx off >/dev/null 2>&1 || true
ip link set eth1 up; ip addr add $IP dev eth1
ip route replace default via $GW dev eth1
printf 'nameserver 192.168.100.53\n' > /etc/resolv.conf
# one cluster: each tenant's apps on its VR's outside address > the F5 VIP; console, OAuth and the cluster's own routes on .144
# /etc/hosts is docker's bind mount (sed -i cannot replace it): rewrite it in place, without this lab's earlier block
h=$(awk '/^# sonic-clos-dc BEGIN/ {s=1} !s; /^# sonic-clos-dc END/ {s=0}' /etc/hosts | grep -v -e '\.apps\.\(prod\|dev\)\.dc\.lab'); echo "$h" > /etc/hosts
{
  echo "# sonic-clos-dc BEGIN"
  for cl in prod:142 dev:143; do c=${cl%%:*}; a=${cl#*:}
    echo "192.168.100.$a whoami.$c.dc.lab chat.$c.dc.lab inference.$c.dc.lab harbor.$c.dc.lab minio.$c.dc.lab"
  done
  echo "192.168.100.144 console-openshift-console.apps.ocp.dc.lab oauth-openshift.apps.ocp.dc.lab"
  echo "# sonic-clos-dc END"
} >> /etc/hosts
# ssh as on the other hosts (admin/admin, root/CHANGE_ME_HOST_ROOT_PW, LAB values), reached on the management address
id admin >/dev/null 2>&1 || adduser -D -s /bin/bash admin
echo admin:admin | chpasswd; echo root:CHANGE_ME_HOST_ROOT_PW | chpasswd
ssh-keygen -A >/dev/null
sed -i -e 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
pgrep -x sshd >/dev/null || /usr/sbin/sshd
