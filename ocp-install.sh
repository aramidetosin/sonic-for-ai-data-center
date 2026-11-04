#!/bin/bash
# ocp-install.sh <prod|dev|gpu> [--force-mem]: the install of one cluster: check the memory floor, release the hold gate (the cluster's node
# containers boot its agent ISO), then follow the install from the cluster's own bastion (bastion-<cluster>): bootstrap-complete,
# install-complete. Log: logs/install-<cluster>.txt (password lines dropped).
# The lab host keeps 16 GiB available. The cluster's VMs (VM_MEM of its nodes in nodes.json) plus 16 GiB must be available before
# the release, else the script refuses. Order: prod and dev (6 x 16 GiB) together,
# gpu (3 x 16 + 8 x 10 GiB) once they are installed.
cd "$(dirname "$0")"; . ./lib.sh; CL=${1:?prod|dev|gpu}; mkdir -p logs
case " $CLUSTERS " in *" $CL "*) ;; *) echo "unknown cluster $CL ($CLUSTERS)"; exit 2;; esac
[ -f agent-$CL/iso/agent.x86_64.iso ] || { say "no ISO: ./make-iso.sh $CL"; exit 1; }
B=$(BAST $CL); docker inspect $B >/dev/null 2>&1 || { say "$B is not running (node-recreate.sh bastion-$CL)"; exit 1; }
need=$(python3 -c "import json,sys; n=json.load(open('nodes.json'))['nodes']; print(sum(int(v['env']['VM_MEM']) for v in n.values() if v.get('cluster')=='$CL')//1024)")
held=$(for c in $(python3 -c "import json; n=json.load(open('nodes.json'))['nodes']; print(' '.join(k for k,v in n.items() if v.get('cluster')=='$CL'))"); do
  docker inspect -f '{{.State.Running}}' $C-$c 2>/dev/null; done | grep -c true)
avail=$(awk '/MemAvailable/ {print int($2/1048576)}' /proc/meminfo)
say "$CL: $held node containers running (held), the VMs need ${need} GiB, ${avail} GiB available (floor 16 GiB)"
if [ "$avail" -lt $((need + 16)) ] && [ "${2:-}" != --force-mem ]; then
  say "$CL: refusing to release: ${avail} GiB available < ${need} + 16 GiB (stop something or wait for the other install)"; exit 1; fi
say "$CL: releasing the guests"; touch shared/release-$CL
set -o pipefail   # the installer's exit code, not sed's
docker exec $B openshift-install agent wait-for bootstrap-complete --dir /w/agent/build --log-level info 2>&1 | sed '/[Pp]assword/d' > logs/install-$CL.txt; rc=$?
[ $rc = 0 ] && { docker exec $B openshift-install agent wait-for install-complete --dir /w/agent/build --log-level info 2>&1 | sed '/[Pp]assword/d' >> logs/install-$CL.txt; rc=$?; }
tail -3 logs/install-$CL.txt; say "$CL install rc=$rc, MemAvailable $(awk '/MemAvailable/ {print int($2/1048576)}' /proc/meminfo) GiB"; exit $rc
