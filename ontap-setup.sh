#!/bin/bash
# ontap-setup.sh: day-one configuration of dc-ontap (2-node ONTAP 9.17.1 simulator), run after ontap-grow.sh. Re-runnable:
# a command whose object exists fails harmlessly ("already ..."); the script prints only unexpected errors and the end state.
#   licenses ($SECRETS/ontap-licenses.txt: one code per line, for node 1's default serial and node 2's 4034389062) | a0a = e0d-e0g LACP per node (Po51 / Po52 on the storage pair)
#   management on e0h in Vrf-Mgmt: cluster 172.16.0.40, nodes .41 / .42; DNS + NTP from dns-ntp1 / dns-ntp2 (Vrf-Svc, through vr-shared)
# ontap.env (gen.py): one SVM per OpenShift cluster, each in its own IPspace on its own VLAN port of a0a:
#   svm-prod (IPspace prod, a0a-103, Vrf-Prod 10.0.3.0/24) and svm-dev (IPspace dev, a0a-203, Vrf-Dev 10.0.3.0/24): the SAME addresses
#   svm-gpu  (IPspace gpu,  a0a-109, Vrf-Ocp 10.0.9.0/24)
#   in each: SVM management .250 (Trident, in-VRF), iSCSI .251 / .252, NFS .253 / .254 (node 1 / node 2); NFS clients = the storage /24
#   a0a and the three storage domains at MTU 9000 (node bonds 9000, leaves 9100); e0h 1500
# The running lab moves from the one-cluster layout with ontap-migrate.sh (renames, LIF moves); this script builds the same end state on a fresh array.
# CLI in one ssh session (the simulator's sshd throttles bursts of logins); the vsadmin passwords through the REST API (appliances.env,
# never printed, curl reads the credentials from stdin).
cd "$(dirname "$0")"; . ./lib.sh; . ./ontap.env
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
for cl in $SVMS; do v=SVM_$cl; read -r SVM IPS V NET OM OI1 OI2 ON1 ON2 CLIENTS <<<"${!v}"
  C+="network ipspace create -ipspace $IPS; "
  for n in $NODES; do C+="network port vlan create -node $n -vlan-name a0a-$V; "; done
  C+="network port broadcast-domain create -ipspace $IPS -broadcast-domain bd-$cl-storage -mtu 1500 -ports $N1:a0a-$V,$N2:a0a-$V; "
done
C+="network port broadcast-domain create -ipspace Default -broadcast-domain bd-mgmt -mtu 1500 -ports $N1:e0h,$N2:e0h; "
# management in Vrf-Mgmt
C+="network interface create -vserver dc-ontap -lif cluster-mgmt -service-policy default-management -home-node $N1 -home-port e0h -address $CMGMT -netmask 255.255.255.0 -failover-policy broadcast-domain-wide -auto-revert true; "
C+="network interface create -vserver dc-ontap -lif ${N1}-node-mgmt -service-policy default-management -home-node $N1 -home-port e0h -address ${NODE_MGMT%% *} -netmask 255.255.255.0 -failover-policy local-only; "
C+="network interface create -vserver dc-ontap -lif ${N2}-node-mgmt -service-policy default-management -home-node $N2 -home-port e0h -address ${NODE_MGMT##* } -netmask 255.255.255.0 -failover-policy local-only; "
C+="network route create -vserver dc-ontap -destination 172.16.0.0/16 -gateway 172.16.0.1; network route create -vserver dc-ontap -destination 10.250.0.0/24 -gateway 172.16.0.1; "
C+="vserver services name-service dns create -vserver dc-ontap -domains dc.lab -name-servers 10.250.0.11,10.250.0.12; "
C+="cluster time-service ntp server create -server 10.250.0.11; cluster time-service ntp server create -server 10.250.0.12; "
# the SVMs: one per cluster, in its IPspace (prod and dev with identical addresses)
for cl in $SVMS; do v=SVM_$cl; read -r SVM IPS V NET OM OI1 OI2 ON1 ON2 CLIENTS <<<"${!v}"
  C+="vserver create -vserver $SVM -ipspace $IPS -rootvolume root_$cl -aggregate aggr_netapp01 -rootvolume-security-style unix; "
  C+="vserver add-aggregates -vserver $SVM -aggregates aggr_netapp01,aggr_netapp02; "
  C+="vserver nfs create -vserver $SVM -v3 enabled -v4.0 enabled -v4.1 enabled; vserver iscsi create -vserver $SVM -target-alias $SVM; "
  C+="network interface create -vserver $SVM -lif svm-mgmt -service-policy default-management -home-node $N1 -home-port a0a-$V -address $NET.$OM -netmask 255.255.255.0 -failover-policy broadcast-domain-wide -auto-revert true; "
  C+="network interface create -vserver $SVM -lif iscsi-netapp01 -service-policy default-data-iscsi -home-node $N1 -home-port a0a-$V -address $NET.$OI1 -netmask 255.255.255.0; "
  C+="network interface create -vserver $SVM -lif iscsi-netapp02 -service-policy default-data-iscsi -home-node $N2 -home-port a0a-$V -address $NET.$OI2 -netmask 255.255.255.0; "
  C+="network interface create -vserver $SVM -lif nfs-netapp01 -service-policy default-data-files -home-node $N1 -home-port a0a-$V -address $NET.$ON1 -netmask 255.255.255.0 -auto-revert true; "
  C+="network interface create -vserver $SVM -lif nfs-netapp02 -service-policy default-data-files -home-node $N2 -home-port a0a-$V -address $NET.$ON2 -netmask 255.255.255.0 -auto-revert true; "
  C+="network route create -vserver $SVM -destination 0.0.0.0/0 -gateway $NET.1; "
  C+="vserver export-policy rule create -vserver $SVM -policyname default -clientmatch $CLIENTS -rorule sys -rwrule sys -superuser sys -protocol nfs; "
  [ $cl = gpu ] || C+="volume create -vserver $SVM -volume isolation_$cl -aggregate aggr_netapp01 -size 1g -junction-path /isolation_$cl -security-style unix -unix-permissions 0777; "
done
C+="network interface show -fields address,ipspace,curr-node,curr-port,status-oper"
say "ontap-setup: applying (one session)"
ONTAP "$C" | grep -E "^Error" | grep -v -i -E "already|duplicate|exists|is not assigned|not found in IPspace|is already a member|no valid failover targets" | sed 's/^/  unexpected: /'
# jumbo frames on the data path. a0a sits in a broadcast domain ONTAP created when the ifgrp came up (its name depends on the wiring),
# so it is raised after the first pass: the parent first (a VLAN cannot exceed its port), then the storage domains.
C=""
for n in $NODES; do bd=$(ONTAP "network port show -node $n -port a0a -fields broadcast-domain" | awk '$2=="a0a"{print $3}')
  if [ -n "$bd" ] && [ "$bd" != "-" ]; then C+="network port broadcast-domain modify -ipspace Default -broadcast-domain $bd -mtu 9000; "
  else C+="network port modify -node $n -port a0a -mtu 9000; "; fi; done
for cl in $SVMS; do v=SVM_$cl; read -r SVM IPS _r <<<"${!v}"; C+="network port broadcast-domain modify -ipspace $IPS -broadcast-domain bd-$cl-storage -mtu 9000; "; done
ONTAP "$C" | grep -E "^Error" | sed 's/^/  unexpected: /'
sleep 20
./ontap-vsadmin.sh
ONTAP "network port ifgrp show; network interface show -fields address,ipspace,curr-node,curr-port,status-oper; storage aggregate show -fields aggregate,node,size,availsize"
