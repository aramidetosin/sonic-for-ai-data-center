#!/bin/bash
# node-roll.sh <prod|dev|gpu> [host ...]: reboot the nodes of ONE cluster one at a time (every iSCSI / NFS session reconnects and negotiates
# the jumbo MSS), through the cluster's own bastion. Per node: drain (daemonsets stay, emptyDir data goes), reboot over ssh, wait NotReady then
# Ready, uncordon, then wait until the cluster is healthy before the next node: every operator Available and neither Progressing nor Degraded,
# every MachineConfigPool Updated, and etcd with all 3 members healthy (a compact cluster loses quorum if two of its 3 nodes are down at once).
# Default order: prod / dev: cp1, cp2, cp3 (each is control plane AND workload node: one at a time, never two); gpu: gpu-worker1..8, then
# master1..3. A drain deletes the pods no controller owns: on gpu the model servers (llm/) are re-deployed at the end, any other is named.
# Stops at the first node that does not come back (exit 1), leaving the rest untouched.
set -u
cd "$(dirname "$0")"; . ./lib.sh
CL=${1:?prod|dev|gpu}; shift; case $CL in prod|dev|gpu) ;; *) echo "usage: $0 prod|dev|gpu [host ...]"; exit 2;; esac
BARE=$(mktemp)   # the pods without a controller that the drains delete
OC() { OCL $CL "$@" 2>&1; }
if [ $# -gt 0 ]; then NODES="$*"
elif [ $CL = gpu ]; then NODES="$(nodes_of gpu | grep '^gpu-worker' | sort -V | xargs) $(nodes_of gpu | grep '^master' | sort -V | xargs)"
else NODES=$(nodes_of $CL | sort -V | xargs); fi
[ -n "$NODES" ] || { say "no nodes of cluster $CL in mgmt-hosts.txt"; exit 1; }
NS() { NSSH "$(ctr_of $CL $1)" "$2"; }
ready() { OC get node $1 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'; }
etcd_ok() {   # 3 etcd members, every one healthy (the operator's own view: EtcdMembersAvailable)
  OC get etcd cluster -o jsonpath='{.status.conditions[?(@.type=="EtcdMembersAvailable")].message}' | grep -q "3 members are available"; }
healthy() {
  [ -z "$(OC get co --no-headers | awk '$3!="True" || $4!="False" || $5!="False"')" ] &&
  [ -z "$(OC get mcp --no-headers | awk '$3!="True" || $4!="False" || $5!="False"')" ] && etcd_ok; }
waitfor() { local what=$1 max=$2 t=0; shift 2; until "$@"; do sleep 10; t=$((t+10)); [ $t -ge $max ] && { say "  timeout ($max s) waiting for $what"; return 1; }; done; say "  $what after ${t}s"; }
notready() { [ "$(ready $1)" != "True" ]; }
isready() { [ "$(ready $1)" = "True" ]; }
say "node-roll $CL: $NODES"
for n in $NODES; do
  say "== $n ($(ctr_of $CL $n))"
  waitfor "cluster $CL healthy before $n" 1800 healthy || exit 1
  OC adm cordon $n | sed 's/^/  /'
  OC adm drain $n --ignore-daemonsets --delete-emptydir-data --force --timeout=600s 2>&1 | tee -a $BARE.raw | grep -v -E "^evicting|^pod/.*evicted" | sed 's/^/  /'
  boot0=$(NS $n "cat /proc/sys/kernel/random/boot_id")
  NS $n "sudo systemctl reboot" >/dev/null; say "  reboot sent (boot_id ${boot0:0:8})"
  waitfor "$n NotReady" 600 notready $n || true
  waitfor "$n Ready" 1200 isready $n || exit 1
  boot1=$(NS $n "cat /proc/sys/kernel/random/boot_id"); [ "$boot1" != "$boot0" ] || { say "  $n did not reboot (same boot_id)"; exit 1; }
  OC adm uncordon $n | sed 's/^/  /'
  waitfor "cluster $CL healthy after $n" 1800 healthy || exit 1
  say "  $n: new boot ${boot1:0:8}, storage sessions: $(NS $n "ss -tni state established '( dport = :3260 or dport = :2049 )' | grep -o 'mss:[0-9]*' | sort | uniq -c | paste -sd' '")"
done
# a drain --force deletes the pods no controller owns: the model servers of llm-serve.sh are such pods; re-deploy them, name any other
grep -o "declare no controller: [^;]*" $BARE.raw | sed "s/.*controller: //" | tr "," "\n" | sed "s/^ *//" | sort -u > $BARE
say "pods the drains deleted (no controller): $(paste -sd' ' $BARE)"
if [ $CL = gpu ] && grep -q "^llm/" $BARE; then say "re-deploying the model servers (llm-serve.sh up)"; ./llm-serve.sh up 2>&1 | grep -v "would violate PodSecurity" | sed "s/^/  /"; fi
grep -v "^llm/" $BARE | sed "s/^/  NOT re-created, do it by hand: /"
rm -f $BARE $BARE.raw
say "node-roll $CL: done ($NODES)"
