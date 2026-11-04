#!/bin/bash
# validate-storage.sh: checks of sonic-clos-dc (dc-ontap), one PASS/FAIL line each -> results/<lab>_storage_<ts>/result.txt
cd "$(dirname "$0")"; . ./lib.sh; . ./.env
P=0; F=0; RD=$(resdir storage); OUT=$RD/result.txt; CMDLOG=$PWD/$RD/commands.txt; : > $OUT; : > $CMDLOG
log() { echo "$*" | tee -a $OUT; }
ok() { if [ "$2" = 0 ]; then log "PASS  $1"; P=$((P+1)); else log "FAIL  $1  ($3)"; F=$((F+1)); fi; }
want() { local got; [ -n "${CMDLOG:-}" ] && printf '$ %s\n' "$2" | redact >> "$CMDLOG"; got=$(eval "$2" 2>&1); echo "$got" | grep -q -E "$3"; ok "$1" $? "got: $(echo $got | head -c 140)"; }
deny() { local got; [ -n "${CMDLOG:-}" ] && printf '$ %s\n' "$2" | redact >> "$CMDLOG"; got=$(eval "$2" 2>&1); if echo "$got" | grep -q -E "$3"; then ok "$1" 1 "reached: $(echo $got | head -c 90)"; else ok "$1" 0; fi; }
mnt() { X $1 "mkdir -p /mnt/n; timeout 25 mount -t nfs -o vers=3,nolock,soft,timeo=50 $2 /mnt/n && { echo $1 > /mnt/n/owner-$1 && ls /mnt/n; umount /mnt/n; } 2>&1"; }
log "== storage"
want "cluster healthy, 2 nodes" "ONTAP 'cluster show -fields health' | grep -c ' true'" "^2$"
for n in dc-ontap-01 dc-ontap-02; do want "$n a0a: 4 active LACP ports" "ONTAP 'network port ifgrp show -node $n -ifgrp a0a -fields up-ports'" "e0d,e0e,e0f,e0g"; done
for s in leaf5a-storage leaf5b-storage; do want "$s: PortChannel51/52 up with their ES partner" "KL $s 'show evpn es' | awk '\$3 ~ /PortChannel5[12]/ && \$2 ~ /R/' | wc -l" "^2$"; done
want "all 17 SVM LIFs up (5 data per SVM on .250-.254; svm-prod / svm-dev also one storage-admin LIF)" "ONTAP 'network interface show -vserver svm-* -fields address,status-oper' | grep -c ' up'" "^17$"
for t in ocp:10.0.3 prod:10.10.3 dev:10.20.3; do want "svm-${t%:*}: its 5 LIFs on ${t#*:}.250-.254" "ONTAP 'network interface show -vserver svm-${t%:*} -fields address' | grep -c '${t#*:}\.25[0-4]'" "^5$"; done
want "bastion-ocp: svm-ocp REST 10.0.3.250 (vsadmin, Vrf-Ocp) answers" "X bastion-ocp 'curl -sk -o /dev/null -w %{http_code} -u vsadmin:$ONTAP_VSADMIN_PW https://10.0.3.250/api/storage/volumes'" "^200$"
for t in prod dev; do p=$([ $t = prod ] && echo 10.10 || echo 10.20); o=$([ $t = prod ] && echo dev || echo prod); q=$([ $t = prod ] && echo 10.20 || echo 10.10)
  for a in $p.3.251 $p.3.252; do want "probe-$t reaches svm-$t iSCSI $a:3260 over Vrf-$t" "X probe-$t 'nc -z -w3 $a 3260 && echo open'" "^open$"; done
  deny "probe-$t is refused by svm-$t's NFS export (clients = the storage subnet $p.3.0/24 only)" "mnt probe-$t $p.3.253:/isolation_$t" "owner-"
  deny "probe-$t cannot reach svm-$o (another tenant VRF)" "X probe-$t 'nc -z -w3 $q.3.251 3260 && echo open'" "^open$"
  deny "probe-$t cannot reach svm-ocp (Vrf-Ocp)" "X probe-$t 'nc -z -w3 10.0.3.251 3260 && echo open'" "^open$"
done
for t in prod:10.0.6.250 dev:10.0.7.250; do want "bastion-ocp: svm-${t%:*} storage-admin interface ${t#*:} answers (Vrf-Ocp)" "X bastion-ocp 'curl -sk -o /dev/null -w %{http_code} -m 8 https://${t#*:}/api/svm/svms'" "^401$"
  deny "probe-prod cannot reach the storage-admin interface ${t#*:}" "X probe-prod 'curl -sk -o /dev/null -w %{http_code} -m 5 https://${t#*:}/'" "^[1-5][0-9][0-9]$"; done
want "bastion-ocp reaches cluster management 172.16.0.40 over Vrf-Mgmt" "X bastion-ocp 'curl -sk -o /dev/null -w %{http_code} -u admin:CHANGE_ME_ONTAP_PW --interface eth3 https://172.16.0.40/api/cluster'" "^200$"
deny "probe-prod cannot reach cluster management (no tenant transit)" "X probe-prod 'curl -sk -o /dev/null -w %{http_code} -m 5 https://172.16.0.40/'" "^[1-5][0-9][0-9]$"
# jumbo frames from the nodes to every SVM, unfragmented (8972 bytes of ICMP payload + 28 = 9000), one node of each role
want "ONTAP a0a and the 3 storage VLANs at MTU 9000 on both nodes" "ONTAP 'network port show -port a0a,a0a-103,a0a-113,a0a-213 -fields mtu' | grep -c ' 9000 *\$'" "^8$"
NX() { ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8 core@"$(mip ocp-$1)" "$2" 2>&1; }   # a node of cluster ocp
jumbo() { NX $1 "ping -c 3 -W 2 -M do -s 8972 $2 2>&1 | grep transmitted"; }
for p in master1:10.0.3.253 gpu-worker1:10.0.3.251 prod-worker1:10.0.3.254 prod-worker1:10.10.3.253 prod-worker1:10.10.3.251 dev-worker1:10.20.3.254 dev-worker1:10.20.3.252; do
  want "${p%:*} reaches ${p#*:} with 9000-byte frames, DF set" "jumbo ${p%:*} ${p#*:}" " 3 received"; done
want "ONTAP resolves through dns-ntp1/dns-ntp2" "ONTAP 'vserver services name-service dns check -vserver dc-ontap'" "up"
log "-- failover: svm-prod iscsi-netapp01 stays on node 1 (iSCSI LIFs do not move); nfs-netapp01 moves to node 2, svm-prod keeps the address"
ONTAP "network interface migrate -vserver svm-prod -lif nfs-netapp01 -destination-node dc-ontap-02 -destination-port a0a-113" >/dev/null; sleep 5
want "svm-prod nfs-netapp01 now on dc-ontap-02" "ONTAP 'network interface show -vserver svm-prod -lif nfs-netapp01 -fields curr-node'" "dc-ontap-02"
want "10.10.3.253 still answers from Vrf-Prod after the move" "SW leaf5b-storage 'ping -c2 -W1 -I Vrf-Prod 10.10.3.253'" " 0% packet loss"
ONTAP "network interface revert -vserver svm-prod -lif nfs-netapp01" >/dev/null; sleep 3
want "svm-prod nfs-netapp01 reverted home" "ONTAP 'network interface show -vserver svm-prod -lif nfs-netapp01 -fields curr-node,is-home'" "dc-ontap-01 +true"
log ""; log "RESULT: $P passed, $F failed ($RD)"
[ $F = 0 ]
