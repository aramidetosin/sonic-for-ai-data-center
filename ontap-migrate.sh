#!/bin/bash
# ontap-migrate.sh [check|gpu|prod|dev|verify|all]: the migration to three clusters on the RUNNING dc-ontap, from the one-cluster layout to one SVM per cluster, without
# re-creating an SVM, an aggregate or a volume (licences, aggregates and data stay):
#   before:  IPspace ocp  / svm-ocp  on a0a-103 10.0.3.250-.254 (Vrf-Ocp)            after:  IPspace gpu  / svm-gpu  on a0a-109 10.0.9.250-.254
#            IPspace prod / svm-prod on a0a-113 10.10.3.250-.254 + svm-admin a0a-106          IPspace prod / svm-prod on a0a-103 10.0.3.250-.254
#            IPspace dev  / svm-dev  on a0a-213 10.20.3.250-.254 + svm-admin a0a-107          IPspace dev  / svm-dev  on a0a-203 10.0.3.250-.254
# Order matters: svm-gpu leaves a0a-103 before a0a-103 joins IPspace prod. Run only while no cluster uses the array: every LIF
# moves (address + home port), so every iSCSI / NFS session of the old cluster would break. Each phase is one CLI session; an object already in
# its target state answers an error that is filtered as harmless, so a phase can be re-run. The old clusters' Trident volumes are LISTED (logs/),
# never deleted (the models volume of svm-gpu can be imported into cluster gpu with tridentctl import).
cd "$(dirname "$0")"; . ./lib.sh; . ./ontap.env; mkdir -p logs; LOG=logs/ontap-migrate-$(date +%Y%m%d%H%M%S).txt
N1=dc-ontap-01; N2=dc-ontap-02
HARMLESS="already|duplicate|exists|is not assigned|not found|is already a member|no valid failover targets|does not exist|entry doesn't exist|There are no entries"
run() { say "ontap-migrate $1"; shift; ONTAP "$*" | tee -a $LOG | grep -E "^Error" | grep -v -i -E "$HARMLESS" | sed 's/^/  unexpected: /'; }
lifs() { local svm=$1 V=$2 NET=$3 c=""
  c+="network interface modify -vserver $svm -lif svm-mgmt -home-port a0a-$V -address $NET.250 -netmask 255.255.255.0; "
  c+="network interface modify -vserver $svm -lif iscsi-netapp01 -status-admin down; network interface modify -vserver $svm -lif iscsi-netapp01 -home-port a0a-$V -address $NET.251 -netmask 255.255.255.0; network interface modify -vserver $svm -lif iscsi-netapp01 -status-admin up; "
  c+="network interface modify -vserver $svm -lif iscsi-netapp02 -status-admin down; network interface modify -vserver $svm -lif iscsi-netapp02 -home-port a0a-$V -address $NET.252 -netmask 255.255.255.0; network interface modify -vserver $svm -lif iscsi-netapp02 -status-admin up; "
  c+="network interface modify -vserver $svm -lif nfs-netapp01 -home-port a0a-$V -address $NET.253 -netmask 255.255.255.0; "
  c+="network interface modify -vserver $svm -lif nfs-netapp02 -home-port a0a-$V -address $NET.254 -netmask 255.255.255.0; "
  c+="network interface revert -vserver $svm -lif *; "
  echo "$c"; }
check() {
  ONTAP "network ipspace show; vserver show -fields ipspace; network port broadcast-domain show -fields ipspace,broadcast-domain,ports,mtu; network interface show -fields address,ipspace,home-port,curr-port,status-oper; network route show; vserver export-policy rule show -fields clientmatch" | tee -a $LOG
  say "volumes per SVM (Trident's trident_pvc_* belong to the one-cluster build: listed, not deleted)"
  ONTAP "volume show -vserver svm-* -fields vserver,volume,size,used,junction-path" | tee -a $LOG | grep -c trident_ | sed 's/^/  trident volumes: /'; }
gpu() {   # IPspace ocp > gpu, svm-ocp > svm-gpu, its LIFs to a0a-109 10.0.9.x, then a0a-103 leaves the gpu IPspace
  local c="network ipspace rename -ipspace ocp -new-name gpu; vserver rename -vserver svm-ocp -newname svm-gpu; "
  c+="network port vlan create -node $N1 -vlan-name a0a-109; network port vlan create -node $N2 -vlan-name a0a-109; "
  c+="network port broadcast-domain create -ipspace gpu -broadcast-domain bd-gpu-storage -mtu 9000 -ports $N1:a0a-109,$N2:a0a-109; "
  c+="$(lifs svm-gpu 109 10.0.9)"
  c+="network route delete -vserver svm-gpu -destination 0.0.0.0/0 -gateway 10.0.3.1; network route create -vserver svm-gpu -destination 0.0.0.0/0 -gateway 10.0.9.1; "
  c+="vserver export-policy rule modify -vserver svm-gpu -policyname default -ruleindex 1 -clientmatch 10.0.9.0/24; "
  c+="network port broadcast-domain remove-ports -ipspace gpu -broadcast-domain bd-ocp-storage -ports $N1:a0a-103,$N2:a0a-103; "
  c+="network port broadcast-domain delete -ipspace gpu -broadcast-domain bd-ocp-storage"
  run gpu "$c"; }
tenant() {   # svm-<t> to a0a-<new> 10.0.3.x; the storage-admin VLAN (106 / 107), its LIF and route, and the old VLAN (113 / 213) go
  local t=$1 new=$2 oldv=$3 adm=$4 oldnet=$5 c=""
  [ $t = dev ] && c+="network port vlan create -node $N1 -vlan-name a0a-$new; network port vlan create -node $N2 -vlan-name a0a-$new; "
  c+="network port broadcast-domain add-ports -ipspace $t -broadcast-domain bd-$t-storage -ports $N1:a0a-$new,$N2:a0a-$new; "
  c+="$(lifs svm-$t $new 10.0.3)"
  c+="network route delete -vserver svm-$t -destination 0.0.0.0/0 -gateway $oldnet.1; network route create -vserver svm-$t -destination 0.0.0.0/0 -gateway 10.0.3.1; "
  c+="network route delete -vserver svm-$t -destination 10.0.0.0/16 -gateway 10.0.$((adm - 100)).1; "
  c+="network interface modify -vserver svm-$t -lif svm-admin -status-admin down; network interface delete -vserver svm-$t -lif svm-admin; "
  c+="vserver export-policy rule modify -vserver svm-$t -policyname default -ruleindex 1 -clientmatch 10.0.3.0/24; "
  c+="network port broadcast-domain delete -ipspace $t -broadcast-domain bd-$t-admin; "
  c+="network port broadcast-domain remove-ports -ipspace $t -broadcast-domain bd-$t-storage -ports $N1:a0a-$oldv,$N2:a0a-$oldv; "
  for n in $N1 $N2; do for v in $adm $oldv; do c+="network port vlan delete -node $n -vlan-name a0a-$v; "; done; done
  c+="network port broadcast-domain modify -ipspace $t -broadcast-domain bd-$t-storage -mtu 9000"
  run $t "$c"; }
verify() {   # the end state ontap-setup.sh would build: 3 SVMs in their IPspaces, 15 LIFs where gen.py says, MTU 9000 storage domains
  local out bad=0 cl v
  out=$(ONTAP "network interface show -vserver svm-* -fields address,ipspace,home-port,status-oper")
  for cl in $SVMS; do v=SVM_$cl; read -r SVM IPS V NET _r <<<"${!v}"
    for o in 250 251 252 253 254; do echo "$out" | awk -v s=$SVM -v a=$NET.$o -v p=a0a-$V -v i=$IPS '$1==s && $3==a && $4==p && $5=="up" && $6==i' | grep -q . \
      || { echo "  MISSING $SVM $NET.$o on a0a-$V ($IPS) up"; bad=1; }; done; done
  ONTAP "network port broadcast-domain show -fields mtu" | awk '$2 ~ /^bd-(prod|dev|gpu)-storage$/ && $3 != 9000 {print "  MTU " $2 " " $3; f=1} END {exit f}' || bad=1
  ONTAP "network port vlan show" | grep -E "a0a-(106|107|113|213)\b" && bad=1
  ONTAP "vserver show" | grep -q svm-ocp && { echo "  svm-ocp still exists"; bad=1; }
  say "ontap-migrate verify: $([ $bad = 0 ] && echo PASS || echo FAIL)"; return $bad; }
case ${1:-check} in
  check) check ;;
  gpu) gpu ;;
  prod) tenant prod 103 113 106 10.10.3 ;;
  dev) tenant dev 203 213 107 10.20.3 ;;
  verify) ./ontap-vsadmin.sh; verify ;;
  all) check; gpu; tenant prod 103 113 106 10.10.3; tenant dev 203 213 107 10.20.3; sleep 15; ./ontap-vsadmin.sh; verify ;;
  *) echo "usage: $0 check|gpu|prod|dev|verify|all"; exit 2 ;;
esac
