#!/bin/bash
# rmac-refresh.sh [leaf ...]: after leaves were re-created. A re-created Dell SONiC VM comes back with a NEW router MAC; the other leaves' zebra
# then keeps the old router MAC of that VTEP beside the new one and the kernel next hop of the L3VNI routes keeps the OLD one (a soft or hard
# EVPN clear does not change it): routed traffic to a host behind that VTEP is dropped (seen: the API VIP from bastion-ocp). Restarting FRR (the bgp
# service) on a leaf rebuilds its router-MAC table. One leaf at a time, "b" before "a"; each must come back (underlay + EVPN 4/4, its local ES
# LR) and hold ONE router MAC per remote VTEP in every L3VNI before the next.
cd "$(dirname "$0")"; . ./lib.sh
LV=("$@"); [ $# -eq 0 ] && LV=(leaf1b-control leaf1a-control leaf2b-control leaf2a-control leaf3b-compute leaf3a-compute leaf4b-compute leaf4a-compute
                                 leaf5b-storage leaf5a-storage leaf6b-border leaf6a-border)
T() { timeout 90 bash -c ". ./lib.sh; SW $1 \"$2\"" 2>&1; }
dups() { local v; for v in 50001 50002 50003 50004 50005; do T $1 "vtysh -c 'show evpn rmac vni $v'" | awk '$1 ~ /^[0-9a-f][0-9a-f]:/ {n[$2]++} END {for (k in n) if (n[k] > 1) print k}'; done | sort -u | xargs; }
for l in "${LV[@]}"; do
  es=$(T $l "vtysh -c 'show evpn es'" | awk '$1 ~ /^00:/ && $2 ~ /L/ {print $3}' | sort | xargs)
  say "$l: VTEPs with more than one router MAC before: [$(dups $l)]; restarting FRR"
  T $l "sudo systemctl restart bgp" > /dev/null
  for i in $(seq 1 30); do sleep 10
    u=$(T $l "vtysh -c 'show bgp ipv4 unicast summary'" | awk '/established/ {print $NF}'); e=$(T $l "vtysh -c 'show bgp l2vpn evpn summary'" | awk '/established/ {print $NF}')
    lr=$(T $l "vtysh -c 'show evpn es'" | awk '$1 ~ /^00:/ && $2 ~ /LR/ {print $3}' | sort | xargs)
    [ "$u" = 4 ] && [ "$e" = 4 ] && [ "$lr" = "$es" ] && break; done
  sleep 15; d=$(dups $l)
  say "$l: underlay ${u:-0}/4, EVPN ${e:-0}/4, local ES LR $(echo $lr | wc -w)/$(echo $es | wc -w); VTEPs with more than one router MAC now: [$d]"
  [ "$u" = 4 ] && [ "$e" = 4 ] && [ "$lr" = "$es" ] && [ -z "$d" ] || { say "STOP at $l"; exit 1; }
done
say "router MACs refreshed on ${#LV[@]} leaves"
