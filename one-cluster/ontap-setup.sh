#!/bin/bash
# ontap-setup.sh: day-one configuration of dc-ontap (2-node ONTAP 9.17.1 simulator), run after ontap-grow.sh. Re-runnable:
# a command whose object exists fails harmlessly ("already ..."); the script prints only unexpected errors and the end state.
#   licenses ($SECRETS/ontap-licenses.txt: one code per line, for node 1's default serial and node 2's 4034389062) | a0a = e0d-e0g LACP per node (Po51 / Po52 on the storage pair)
#   IPspace prod: a0a-103 (Vrf-Prod), IPspace dev: a0a-203 (Vrf-Dev) | management on e0h in Vrf-Mgmt: cluster 172.16.0.40, nodes .41 / .42
#   svm-prod / svm-dev, the SAME addresses: SVM management 10.0.3.5 (Trident), iSCSI .11 / .12, NFS .21 / .22 (node 1 / node 2)
#   IPspaces ocp (a0a-103, Vrf-Ocp 10.0.3.0/24), prod (a0a-113, Vrf-Prod 10.10.3.0/24), dev (a0a-213, Vrf-Dev
#   10.20.3.0/24); svm-ocp / svm-prod / svm-dev: management .250, iSCSI .251 / .252, NFS .253 / .254; clients = the storage subnet
#   a0a and the storage VLANs 103/113/213 at MTU 9000 (the node bonds are 9000, the leaves 9100); admin VLANs 106/107 and e0h at 1500
#   DNS + NTP from dns-ntp1 / dns-ntp2 (Vrf-Svc, through the PA-VM's vr-shared: mgmt -> svc is allowed without NAT)
# CLI in one ssh session (the simulator's sshd throttles bursts of logins); the vsadmin passwords through the REST API (.env, never printed).
cd "$(dirname "$0")"; . ./lib.sh; . ./.env; SECRETS=${SCD_SECRETS:-/root/scd-secrets}   # ontap-licenses.txt lives there
N1=dc-ontap-01; N2=dc-ontap-02; NODES="$N1 $N2"
L=$(grep -E "^[A-Z]{28}$" "$SECRETS/ontap-licenses.txt" | sed "s/^/system license add -license-code /" | paste -sd";" -)
C="$L; "
# free the data and management ports from ONTAP's auto-created domains (names depend on the wiring: look them up)
while read -r n p bd; do [ -n "$bd" ] && [ "$bd" != "-" ] && C+="network port broadcast-domain remove-ports -broadcast-domain $bd -ports $n:$p; "
done < <(ONTAP "network port show -port e0d,e0e,e0f,e0g,e0h -fields broadcast-domain" | awk '$2 ~ /^e0[d-h]$/ && $3 ~ /^Default/ {print $1, $2, $3}')
for n in $NODES; do
  C+="network port ifgrp create -node $n -ifgrp a0a -distr-func ip -mode multimode_lacp; "
  for p in e0d e0e e0f e0g; do C+="network port ifgrp add-port -node $n -ifgrp a0a -port $p; "; done
done
C+="network ipspace create -ipspace ocp; network ipspace create -ipspace prod; network ipspace create -ipspace dev; "
for n in $NODES; do for v in 103 113 213; do C+="network port vlan create -node $n -vlan-name a0a-$v; "; done; done
for t in ocp:103 prod:113 dev:213; do C+="network port broadcast-domain create -ipspace ${t%:*} -broadcast-domain bd-${t%:*}-storage -mtu 1500 -ports $N1:a0a-${t#*:},$N2:a0a-${t#*:}; "; done
C+="network port broadcast-domain create -ipspace Default -broadcast-domain bd-mgmt -mtu 1500 -ports $N1:e0h,$N2:e0h; "
# management in Vrf-Mgmt
C+="network interface create -vserver dc-ontap -lif cluster-mgmt -service-policy default-management -home-node $N1 -home-port e0h -address 172.16.0.40 -netmask 255.255.255.0 -failover-policy broadcast-domain-wide -auto-revert true; "
C+="network interface create -vserver dc-ontap -lif ${N1}-node-mgmt -service-policy default-management -home-node $N1 -home-port e0h -address 172.16.0.41 -netmask 255.255.255.0 -failover-policy local-only; "
C+="network interface create -vserver dc-ontap -lif ${N2}-node-mgmt -service-policy default-management -home-node $N2 -home-port e0h -address 172.16.0.42 -netmask 255.255.255.0 -failover-policy local-only; "
C+="network route create -vserver dc-ontap -destination 172.16.0.0/16 -gateway 172.16.0.1; network route create -vserver dc-ontap -destination 10.250.0.0/24 -gateway 172.16.0.1; "
C+="vserver services name-service dns create -vserver dc-ontap -domains dc.lab -name-servers 10.250.0.11,10.250.0.12; "
C+="cluster time-service ntp server create -server 10.250.0.11; cluster time-service ntp server create -server 10.250.0.12; "
# the SVMs (one per tenant IPspace, identical addresses)
# tenant: VLAN, subnet, SVM management / iSCSI / NFS host octets, NFS clients (prod/dev nodes sit on 10.0.1.0/24, their LIFs on 10.0.3.0/24)
declare -A TV=([ocp]="103 10.0.3 250 251 252 253 254 10.0.3.0/24" [prod]="113 10.10.3 250 251 252 253 254 10.10.3.0/24" [dev]="213 10.20.3 250 251 252 253 254 10.20.3.0/24")
for t in ocp prod dev; do read -r V NET OM OI1 OI2 ON1 ON2 CLIENTS <<<"${TV[$t]}"
  C+="vserver create -vserver svm-$t -ipspace $t -rootvolume root_$t -aggregate aggr_netapp01 -rootvolume-security-style unix; "
  C+="vserver add-aggregates -vserver svm-$t -aggregates aggr_netapp01,aggr_netapp02; "
  C+="vserver nfs create -vserver svm-$t -v3 enabled -v4.0 enabled -v4.1 enabled; vserver iscsi create -vserver svm-$t -target-alias svm-$t; "
  C+="network interface create -vserver svm-$t -lif svm-mgmt -service-policy default-management -home-node $N1 -home-port a0a-$V -address $NET.$OM -netmask 255.255.255.0 -failover-policy broadcast-domain-wide -auto-revert true; "
  C+="network interface create -vserver svm-$t -lif iscsi-netapp01 -service-policy default-data-iscsi -home-node $N1 -home-port a0a-$V -address $NET.$OI1 -netmask 255.255.255.0; "
  C+="network interface create -vserver svm-$t -lif iscsi-netapp02 -service-policy default-data-iscsi -home-node $N2 -home-port a0a-$V -address $NET.$OI2 -netmask 255.255.255.0; "
  C+="network interface create -vserver svm-$t -lif nfs-netapp01 -service-policy default-data-files -home-node $N1 -home-port a0a-$V -address $NET.$ON1 -netmask 255.255.255.0 -auto-revert true; "
  C+="network interface create -vserver svm-$t -lif nfs-netapp02 -service-policy default-data-files -home-node $N2 -home-port a0a-$V -address $NET.$ON2 -netmask 255.255.255.0 -auto-revert true; "
  C+="network route create -vserver svm-$t -destination 0.0.0.0/0 -gateway $NET.1; "
  C+="vserver export-policy rule create -vserver svm-$t -policyname default -clientmatch $CLIENTS -rorule sys -rwrule sys -superuser sys -protocol nfs; "
  [ $t = ocp ] || C+="volume create -vserver svm-$t -volume isolation_$t -aggregate aggr_netapp01 -size 1g -junction-path /isolation_$t -security-style unix -unix-permissions 0777; "
done
# the storage-admin network: one management interface each for svm-prod / svm-dev in Vrf-Ocp (VLAN 106 / 107), routed back to 10.0.0.0/16
for t in prod:106 dev:107; do T=${t%:*}; V=${t#*:}
  for n in $NODES; do C+="network port vlan create -node $n -vlan-name a0a-$V; "; done
  C+="network port broadcast-domain create -ipspace $T -broadcast-domain bd-$T-admin -mtu 1500 -ports $N1:a0a-$V,$N2:a0a-$V; "
  C+="network interface create -vserver svm-$T -lif svm-admin -service-policy default-management -home-node $N1 -home-port a0a-$V -address 10.0.$((V - 100)).250 -netmask 255.255.255.0 -failover-policy broadcast-domain-wide -auto-revert true; "
  C+="network route create -vserver svm-$T -destination 10.0.0.0/16 -gateway 10.0.$((V - 100)).1; "
done
C+="network interface show -fields address,ipspace,curr-node,curr-port,status-oper"
say "ontap-setup: applying (one session)"
ONTAP "$C" | grep -E "^Error" | grep -v -i -E "already|duplicate|exists|is not assigned|not found in IPspace|is already a member|no valid failover targets" | sed 's/^/  unexpected: /'
# jumbo frames on the data path. a0a sits in a broadcast domain ONTAP created when the ifgrp came up (its name depends on the wiring),
# so it is raised after the first pass: the parent first (a VLAN cannot exceed its port), then the three storage domains. Admin VLANs stay 1500.
C="" 
for n in $NODES; do bd=$(ONTAP "network port show -node $n -port a0a -fields broadcast-domain" | awk '$2=="a0a"{print $3}')
  if [ -n "$bd" ] && [ "$bd" != "-" ]; then C+="network port broadcast-domain modify -ipspace Default -broadcast-domain $bd -mtu 9000; "
  else C+="network port modify -node $n -port a0a -mtu 9000; "; fi; done
for t in ocp prod dev; do C+="network port broadcast-domain modify -ipspace $t -broadcast-domain bd-$t-storage -mtu 9000; "; done
ONTAP "$C" | grep -E "^Error" | sed 's/^/  unexpected: /'
sleep 20
A="-sk -u admin:CHANGE_ME_ONTAP_PW https://$(mip netapp-01)/api"
for t in ocp prod dev; do svm=$(curl $A/svm/svms?name=svm-$t | python3 -c "import sys,json;print(json.load(sys.stdin)['records'][0]['uuid'])")
  curl $A/security/accounts/$svm/vsadmin -X PATCH -d "{\"password\":\"$ONTAP_VSADMIN_PW\",\"locked\":false}" -o /dev/null -w "vsadmin svm-$t: %{http_code}\n"; done
ONTAP "network port ifgrp show; network interface show -fields address,ipspace,curr-node,curr-port,status-oper; storage aggregate show -fields aggregate,node,size,availsize"
