#!/bin/bash
# validate-storage.sh: checks of dc-ontap, one PASS/FAIL line each -> results/<lab>_storage_<ts>/result.txt
#   three SVMs in three IPspaces: svm-prod (IPspace prod, a0a-103, Vrf-Prod) and svm-dev (dev, a0a-203, Vrf-Dev) on the SAME addresses
#   10.0.3.250-.254, svm-gpu (gpu, a0a-109, Vrf-Ocp) on 10.0.9.250-.254; Trident's management LIF reached in-VRF.
# the ONTAP passwords come from appliances.env (lib.sh); curl reads the basic-auth line from stdin (-K -), never from its arguments.
cd "$(dirname "$0")"; . ./lib.sh
P=0; F=0; RD=$(resdir storage); OUT=$RD/result.txt; CMDLOG=$PWD/$RD/commands.txt; : > $OUT; : > $CMDLOG
log() { echo "$*" | tee -a $OUT; }
ok() { if [ "$2" = 0 ]; then log "PASS  $1"; P=$((P+1)); else log "FAIL  $1  ($3)"; F=$((F+1)); fi; }
want() { local got; [ -n "${CMDLOG:-}" ] && printf '$ %s\n' "$2" | redact >> "$CMDLOG"; got=$(eval "$2" 2>&1); echo "$got" | grep -q -E "$3"; ok "$1" $? "got: $(echo $got | head -c 140)"; }
deny() { local got; [ -n "${CMDLOG:-}" ] && printf '$ %s\n' "$2" | redact >> "$CMDLOG"; got=$(eval "$2" 2>&1); if echo "$got" | grep -q -E "$3"; then ok "$1" 1 "reached: $(echo $got | head -c 90)"; else ok "$1" 0; fi; }
mnt() { X $1 "mkdir -p /mnt/n; timeout 25 mount -t nfs -o vers=3,nolock,soft,timeo=50 $2 /mnt/n && { echo $1 > /mnt/n/owner-$1 && ls /mnt/n; umount /mnt/n; } 2>&1"; }
# VSA <lab node> <url>: an SVM REST call as vsadmin from that node's network; prints "<http code> <svm names the answer holds>"
VSA() { printf 'user = "vsadmin:%s"\n' "$ONTAP_VSADMIN_PW" | docker exec -i $C-$1 sh -c "curl -sk -m 8 -K - -o /tmp/vsa.json -w '%{http_code}' '$2'; echo \" \$(grep -o '\"name\": *\"svm-[a-z]*\"' /tmp/vsa.json | grep -o 'svm-[a-z]*' | sort -u | xargs)\"; rm -f /tmp/vsa.json"; }
# ADM <url>: a cluster-management REST call as the cluster admin from bastion-gpu's Vrf-Mgmt NIC (eth3)
ADM() { printf 'user = "%s:%s"\n' "${ONTAP_USER:-admin}" "$ONTAP_PW" | docker exec -i $C-bastion-gpu curl -sk -m 8 -K - -o /dev/null -w '%{http_code}' --interface eth3 "$1"; }
log "== storage"
want "cluster healthy, 2 nodes" "ONTAP 'cluster show -fields health' | grep -c ' true'" "^2$"
for n in dc-ontap-01 dc-ontap-02; do want "$n a0a: 4 active LACP ports" "ONTAP 'network port ifgrp show -node $n -ifgrp a0a -fields up-ports'" "e0d,e0e,e0f,e0g"; done
for s in leaf5a-storage leaf5b-storage; do want "$s: PortChannel51/52 up with their ES partner" "KL $s 'show evpn es' | awk '\$3 ~ /PortChannel5[12]/ && \$2 ~ /R/' | wc -l" "^2$"; done
want "the three SVMs sit in three IPspaces (gpu, prod, dev)" "ONTAP 'vserver show -vserver svm-gpu,svm-prod,svm-dev -fields ipspace' | awk '\$1 ~ /^svm-/ {print \$1\"=\"\$2}' | sort | paste -sd' '" "^svm-dev=dev svm-gpu=gpu svm-prod=prod$"
want "no svm-ocp and no IPspace ocp left (renamed to svm-gpu / gpu)" "ONTAP 'vserver show -fields ipspace' | grep -cE '^svm-ocp|ocp *\$'" "^0$"
want "all 15 SVM data LIFs up (mgmt .250, iSCSI .251/.252, NFS .253/.254 per SVM; no storage-admin LIF)" "ONTAP 'network interface show -vserver svm-* -fields address,status-oper' | grep -c ' up'" "^15$"
for t in prod:10.0.3 dev:10.0.3 gpu:10.0.9; do want "svm-${t%:*}: its 5 LIFs on ${t#*:}.250-.254" "ONTAP 'network interface show -vserver svm-${t%:*} -fields address' | grep -c '${t#*:}\.25[0-4]'" "^5$"; done
# the same LIF addresses in prod and dev, separated by IPspace
want "svm-prod and svm-dev hold the SAME 5 LIF addresses (separate IPspaces)" "a=\$(ONTAP 'network interface show -vserver svm-prod -fields address' | grep -oE '10\.0\.3\.25[0-4]' | sort | xargs); b=\$(ONTAP 'network interface show -vserver svm-dev -fields address' | grep -oE '10\.0\.3\.25[0-4]' | sort | xargs); [ -n \"\$a\" ] && [ \"\$a\" = \"\$b\" ] && echo same \$a" "^same 10\.0\.3\.250 10\.0\.3\.251 10\.0\.3\.252 10\.0\.3\.253 10\.0\.3\.254$"
want "the VLAN ports are a0a-103, a0a-109, a0a-203 on each node only (106 / 107 / 113 / 213 removed)" "ONTAP 'network port vlan show -fields vlan-name' | grep -oE 'a0a-[0-9]+' | sort | uniq -c | xargs" "^2 a0a-103 2 a0a-109 2 a0a-203$"
log "-- Trident's path: each cluster's bastion reaches ITS SVM's management LIF in its own VRF; the same address, another SVM per tenant"
want "bastion-prod > 10.0.3.250 (vsadmin): svm-prod answers" "VSA bastion-prod https://10.0.3.250/api/svm/svms" "^200 svm-prod$"
want "bastion-dev > 10.0.3.250 (vsadmin): svm-dev answers (the same address, another SVM)" "VSA bastion-dev https://10.0.3.250/api/svm/svms" "^200 svm-dev$"
want "bastion-gpu > 10.0.9.250 (vsadmin): svm-gpu answers" "VSA bastion-gpu https://10.0.9.250/api/svm/svms" "^200 svm-gpu$"
deny "bastion-gpu cannot reach 10.0.3.250 (no tenant SVM in Vrf-Ocp)" "X bastion-gpu 'curl -sk -o /dev/null -w %{http_code} -m 5 https://10.0.3.250/'" "^[1-5][0-9][0-9]$"
for t in prod dev; do o=$([ $t = prod ] && echo dev || echo prod)
  for a in 10.0.3.251 10.0.3.252; do want "probe-$t reaches svm-$t iSCSI $a:3260 over Vrf-${t^}" "X probe-$t 'nc -z -w3 $a 3260 && echo open'" "^open$"; done
  deny "probe-$t is refused by svm-$t's NFS export (clients = the storage subnet 10.0.3.0/24 only)" "mnt probe-$t 10.0.3.253:/isolation_$t" "owner-"
  deny "probe-$t cannot reach svm-gpu (Vrf-Ocp, 10.0.9.251)" "X probe-$t 'nc -z -w3 10.0.9.251 3260 && echo open'" "^open$"
done
want "bastion-gpu reaches cluster management 172.16.0.40 over Vrf-Mgmt" "ADM https://172.16.0.40/api/cluster" "^200$"
deny "probe-prod cannot reach cluster management (no tenant transit)" "X probe-prod 'curl -sk -o /dev/null -w %{http_code} -m 5 https://172.16.0.40/'" "^[1-5][0-9][0-9]$"
# jumbo frames from the nodes to every SVM, unfragmented (8972 bytes of ICMP payload + 28 = 9000), one node of each cluster
want "ONTAP a0a and the 3 storage VLANs at MTU 9000 on both nodes" "ONTAP 'network port show -port a0a,a0a-103,a0a-203,a0a-109 -fields mtu' | grep -c ' 9000 *\$'" "^8$"
jumbo() { NSSH $1 "ping -c 3 -W 2 -M do -s 8972 $2 2>&1 | grep transmitted"; }
for p in prod-cp1:10.0.3.253 prod-cp1:10.0.3.251 dev-cp1:10.0.3.254 dev-cp1:10.0.3.252 gpu-master1:10.0.9.253 gpu-worker1:10.0.9.251; do
  want "${p%:*} reaches ${p#*:} with 9000-byte frames, DF set" "jumbo ${p%:*} ${p#*:}" " 3 received"; done
want "ONTAP resolves through dns-ntp1/dns-ntp2" "ONTAP 'vserver services name-service dns check -vserver dc-ontap'" "up"
log "-- failover: svm-prod iscsi-netapp01 stays on node 1 (iSCSI LIFs do not move); nfs-netapp01 moves to node 2, svm-prod keeps the address"
ONTAP "network interface migrate -vserver svm-prod -lif nfs-netapp01 -destination-node dc-ontap-02 -destination-port a0a-103" >/dev/null; sleep 5
want "svm-prod nfs-netapp01 now on dc-ontap-02" "ONTAP 'network interface show -vserver svm-prod -lif nfs-netapp01 -fields curr-node'" "dc-ontap-02"
want "10.0.3.253 still answers from Vrf-Prod after the move" "SW leaf5b-storage 'ping -c2 -W1 -I Vrf-Prod 10.0.3.253'" " 0% packet loss"
ONTAP "network interface revert -vserver svm-prod -lif nfs-netapp01" >/dev/null; sleep 3
want "svm-prod nfs-netapp01 reverted home" "ONTAP 'network interface show -vserver svm-prod -lif nfs-netapp01 -fields curr-node,is-home'" "dc-ontap-01 +true"
log ""; log "RESULT: $P passed, $F failed ($RD)"
[ $F = 0 ]
