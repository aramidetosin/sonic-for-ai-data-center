#!/bin/bash
# lan-client-up.sh: client-lan1 / client-lan2, a user on the external LAN beyond the PA-VM (env IP, GW). Reaches BOTH clusters only through the
# PA-VM's outside addresses: the apps on .142 (prod) / .143 (dev) > the F5 VIP, console and OAuth of cluster prod on .144 and of
# cluster dev on .145 > that cluster's router.
# Names come from /etc/hosts (as on the Windows server), the resolver is the outside LAN's DNS (dns02 192.168.100.53).
set -e
ethtool -K eth1 tx off >/dev/null 2>&1 || true
ip link set eth1 up; ip addr replace $IP dev eth1   # replace: re-runnable on a running client
ip route replace default via $GW dev eth1
printf 'nameserver 192.168.100.53\n' > /etc/resolv.conf
# each tenant's apps on its VR's outside address > the F5 VIP; its cluster's console and OAuth on .144 (prod) / .145 (dev)
# /etc/hosts is docker's bind mount (sed -i cannot replace it): rewrite it in place, without this lab's earlier block
h=$(awk '/^# sonic-clos-dc BEGIN/ {s=1} !s; /^# sonic-clos-dc END/ {s=0}' /etc/hosts | grep -v -e '\.apps\.\(prod\|dev\)\.dc\.lab'); echo "$h" > /etc/hosts
{
  echo "# sonic-clos-dc BEGIN"
  for cl in prod:142 dev:143; do c=${cl%%:*}; a=${cl#*:}
    echo "192.168.100.$a whoami.$c.dc.lab chat.$c.dc.lab inference.$c.dc.lab harbor.$c.dc.lab minio.$c.dc.lab"
  done
  for cl in prod:144 dev:145; do c=${cl%%:*}; a=${cl#*:}
    echo "192.168.100.$a console-openshift-console.apps.$c.dc.lab oauth-openshift.apps.$c.dc.lab"
  done
  echo "# sonic-clos-dc END"
} >> /etc/hosts
# ssh on the management address (the admin / root passwords come from /run/scd/host.env, a read-only bind of
# /root/scd-secrets/host.env; without it the accounts keep what they have, a fresh one has no password: docker exec only)
id admin >/dev/null 2>&1 || adduser -D -s /bin/bash admin
if [ -r /run/scd/host.env ]; then . /run/scd/host.env
  printf 'admin:%s\nroot:%s\n' "$HOST_ADMIN_PW" "$HOST_ROOT_PW" | chpasswd; unset HOST_ADMIN_PW HOST_ROOT_PW
fi   # without host.env the accounts stay as they are (adduser -D: no password)
ssh-keygen -A >/dev/null
sed -i -e 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
pgrep -x sshd >/dev/null || /usr/sbin/sshd
