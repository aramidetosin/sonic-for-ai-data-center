#!/bin/bash
# node-roll.sh [node ...]: reboot the nodes of cluster ocp one at a time (every iSCSI / NFS session reconnects and negotiates the jumbo MSS).
# Per node: drain (daemonsets stay, emptyDir data goes), reboot over ssh, wait NotReady then Ready, uncordon, then wait until every cluster operator
# is Available and neither Progressing nor Degraded and both MachineConfigPools are Updated before the next node. Workers first, masters last.
# A drain deletes the pods no controller owns: the model servers (llm/) are re-deployed at the end, any other is named.
# Default order: prod, dev, gpu workers, masters. Stops at the first node that does not come back (exit 1), leaving the rest untouched.
set -u
BARE=$(mktemp)   # the pods without a controller that the drains delete
cd "$(dirname "$0")"; . ./lib.sh
B=$C-bastion-ocp; OC() { docker exec $B oc "$@" 2>&1; }
NODES=${*:-"prod-worker1 prod-worker2 prod-worker3 dev-worker1 dev-worker2 dev-worker3 gpu-worker1 gpu-worker2 gpu-worker3 gpu-worker4 gpu-worker5 gpu-worker6 gpu-worker7 gpu-worker8 master1 master2 master3"}
NS() { ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8 core@"$(mip ocp-$1)" "$2" 2>&1; }
ready() { OC get node $1 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'; }
healthy() {   # every operator Available=True, Progressing=False, Degraded=False; both pools Updated, none Degraded
  [ -z "$(OC get co --no-headers | awk '$3!="True" || $4!="False" || $5!="False"')" ] &&
  [ -z "$(OC get mcp --no-headers | awk '$3!="True" || $4!="False" || $5!="False"')" ]; }
waitfor() { local what=$1 max=$2 t=0; shift 2; until "$@"; do sleep 10; t=$((t+10)); [ $t -ge $max ] && { say "  timeout ($max s) waiting for $what"; return 1; }; done; say "  $what after ${t}s"; }
notready() { [ "$(ready $1)" != "True" ]; }
isready() { [ "$(ready $1)" = "True" ]; }
for n in $NODES; do
  say "== $n"
  waitfor "cluster healthy before $n" 1800 healthy || exit 1
  OC adm cordon $n | sed 's/^/  /'
  OC adm drain $n --ignore-daemonsets --delete-emptydir-data --force --timeout=600s 2>&1 | tee -a $BARE.raw | grep -v -E "^evicting|^pod/.*evicted" | sed 's/^/  /'
  boot0=$(NS $n "cat /proc/sys/kernel/random/boot_id")
  NS $n "sudo systemctl reboot" >/dev/null; say "  reboot sent (boot_id ${boot0:0:8})"
  waitfor "$n NotReady" 600 notready $n || true
  waitfor "$n Ready" 1200 isready $n || exit 1
  boot1=$(NS $n "cat /proc/sys/kernel/random/boot_id"); [ "$boot1" != "$boot0" ] || { say "  $n did not reboot (same boot_id)"; exit 1; }
  OC adm uncordon $n | sed 's/^/  /'
  waitfor "cluster healthy after $n" 1800 healthy || exit 1
  say "  $n: new boot ${boot1:0:8}, storage sessions: $(NS $n "ss -tni state established '( dport = :3260 or dport = :2049 )' | grep -o 'mss:[0-9]*' | sort | uniq -c | paste -sd' '")"
done
# a drain --force deletes the pods no controller owns: the model servers of llm-serve.sh are such pods; re-deploy them, name any other
grep -o "declare no controller: [^;]*" $BARE.raw | sed "s/.*controller: //" | tr "," "\n" | sed "s/^ *//" | sort -u > $BARE
say "pods the drains deleted (no controller): $(paste -sd' ' $BARE)"
if grep -q "^llm/" $BARE; then say "re-deploying the model servers (llm-serve.sh up)"; ./llm-serve.sh up 2>&1 | grep -v "would violate PodSecurity" | sed "s/^/  /"; fi
grep -v "^llm/" $BARE | sed "s/^/  NOT re-created, do it by hand: /"
rm -f $BARE $BARE.raw
say "node-roll: done ($NODES)"
