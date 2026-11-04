#!/usr/bin/env bash
# prune-installers.sh <cluster>...: delete the failed static-pod installer pods that their own node has already superseded: the node's current
# revision is at or past the installer's (install-time races such as "configmaps client-ca not found", retried until one attempt succeeded).
# A failed installer of a revision its node has NOT reached is kept and reported: that one is a real fault.
cd "$(dirname "$0")"; . ./lib.sh
for cl in "$@"; do
  for pair in kube-apiserver:kubeapiserver kube-controller-manager:kubecontrollermanager kube-scheduler:kubescheduler; do
    ns=openshift-${pair%%:*}; op=${pair#*:}
    cur=$(OCL $cl get $op cluster -o jsonpath='{range .status.nodeStatuses[*]}{.nodeName}={.currentRevision} {end}' </dev/null)
    for p in $(OCL $cl -n $ns get pods --no-headers </dev/null 2>/dev/null | awk '$1 ~ /^installer-[0-9]+-/ && $3 == "Error" {print $1}'); do
      r=$(echo $p | sed -E 's/^installer-([0-9]+)-.*/\1/'); node=$(echo $p | sed -E 's/^installer-[0-9]+-(retry-[0-9]+-)?//')
      have=$(echo " $cur" | grep -oE " $node=[0-9]+" | cut -d= -f2)
      if [ -n "$have" ] && [ "$have" -ge "$r" ]; then
        OCL $cl -n $ns delete pod $p --wait=false </dev/null >/dev/null && echo "  $cl $ns/$p: $node is at revision $have >= $r, deleted"
      else echo "  $cl $ns/$p: $node is at revision ${have:-?} < $r, KEPT (a real fault)"; fi
    done
  done
done
