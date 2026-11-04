#!/bin/bash
# sonic-apply.sh [switch ...]: wait for each Dell SONiC VM's "Startup complete", fix FRR's boot hostname, push configs/<sw>.cli through one
# chained sonic-cli call (KLISH ignores stdin and -e files), then require a BGP instance. Logs: logs/apply-<sw>.log; exit 1 if a switch failed.
cd "$(dirname "$0")"; . ./lib.sh; mkdir -p logs
SWS=("$@"); [ $# -eq 0 ] && SWS=($(awk '/kind: dell_sonic/{sub(":","",$1); print $1}' $TOPO))
bgp_up() { SW $1 'sudo vtysh -c "show bgp summary"' 2>/dev/null | grep -q "BGP router identifier"; }
one() {
  local n=$1 i rc e
  until docker logs $C-$n 2>&1 | grep -q "Startup complete"; do sleep 20; done
  # "Startup complete" can come before SSH answers; a push without SSH is a failure, never "applied"
  for i in $(seq 1 30); do SW $n true 2>/dev/null && break; sleep 10; done
  SW $n true 2>/dev/null || { echo "$n: FAILED, no SSH to $(mip $n) after 5 min"; return 1; }
  SW $n 'sudo vtysh -c "show run" | grep -q "^hostname $(hostname)$" || { sudo systemctl restart bgp; sleep 25; }'
  mapfile -t CMDS < configs/$n.cli; KL $n "${CMDS[@]}" > logs/apply-$n.log 2>&1; rc=$?
  e=$(grep -c -i -E 'error|invalid|timed out|denied|refused' logs/apply-$n.log)
  if [ $rc != 0 ] || [ $e != 0 ]; then echo "$n: FAILED, rc $rc, $e error lines (logs/apply-$n.log)"; return 1; fi
  # bgpd can hold the pushed frr.conf and still run no BGP instance: restart it once, then require the instance
  if ! bgp_up $n; then
    SW $n 'sudo systemctl restart bgp'; for i in $(seq 1 12); do sleep 10; bgp_up $n && break; done
    bgp_up $n || { echo "$n: FAILED, no BGP instance after the push and a bgp restart"; return 1; }
    echo "$n: bgp restarted (no BGP instance after the push)"
  fi
  echo "$n: applied, 0 error lines, BGP up"
}
RC=0; for n in "${SWS[@]}"; do one $n & done; for j in $(jobs -p); do wait $j || RC=1; done; exit $RC
