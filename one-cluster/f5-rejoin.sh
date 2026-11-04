#!/bin/bash
# f5-rejoin.sh <unit>: bring one BIG-IP back beside the ACTIVE peer that holds the configuration (its licence key must be free first).
# The unit is re-created by `containerlab restart` (links kept): a fresh VE that auto-licenses with its own key. Then LTM/ASM, the route domains,
# VLANs and self IPs, BGP (f5.sh provision/network/bgp for that unit only), and the pair is re-formed FROM THE PEER: the stale trust entry is
# removed, the new unit trusted and added to dg-lb-f5, and the peer syncs to the group. f5.sh ha is NOT used: it syncs from the first unit,
# which here is the empty one.
set -uo pipefail
cd "$(dirname "$0")"; . ./lib.sh; . ./f5.env
U=${1:?unit}; P=$(for u in $UNITS; do [ $u != $U ] && echo $u; done)
SEC=/root/scd-secrets
tm() { local u=$1; shift; ./bigip-run.sh $u "tmsh $*"; }
grep -q "| free |" <(grep "$(sed -n "$([ $U = lb-f5a ] && echo 1 || echo 2)p" $SEC/f5-regkeys.txt | sed -E 's/^(.{5}).*(.{4})$/\1-…-\2/')" $SEC/f5-licence-ledger) || { say "$U: its key is not free in the ledger, refusing"; exit 1; }
if [ -z "${SKIP_RESTART:-}" ]; then say "$U: re-created"; containerlab restart -t $TOPO -n $U > logs/f5-rejoin-$U.log 2>&1 || { tail -5 logs/f5-rejoin-$U.log; exit 1; }
  say "$U: NOTE containerlab restart of a STOPPED node does not restore its links: run ./relink.sh for them"; fi
./f5.sh licence || exit 1
./f5.sh provision $U && ./f5.sh network $U && ./f5.sh bgp $U || exit 1
ha=192.168.255.$([ $U = lb-f5a ] && echo 1 || echo 2); pha=192.168.255.$([ $P = lb-f5a ] && echo 1 || echo 2)
tm $U "modify cm device $U.dc.lab configsync-ip $ha unicast-address { { ip $ha } { ip $(eval echo \$MGMT_${U//-/_}) } } mirror-ip any6all" >/dev/null
pw=$(sed -n 's/^PASSWORD=//p' $SEC/$U.env)
say "$P: drop the stale $U.dc.lab, trust the new one, re-form dg-lb-f5"
tm $P "modify cm device-group dg-lb-f5 devices delete { $U.dc.lab }" >/dev/null 2>&1
tm $P "modify cm trust-domain Root ca-devices delete { $U.dc.lab }" >/dev/null 2>&1
tm $P "delete cm device $U.dc.lab" >/dev/null 2>&1
sleep 5
tm $P "modify cm trust-domain Root ca-devices add { $ha } name $U.dc.lab username admin password $pw" >/dev/null 2>&1
sleep 15
tm $P "modify cm device-group dg-lb-f5 devices add { $U.dc.lab }" >/dev/null 2>&1
sleep 10
tm $P "run cm config-sync to-group dg-lb-f5" >/dev/null
for i in $(seq 1 30); do
  for u in $UNITS; do tm $u "show cm sync-status" | grep -q "datasync-global-dg (Changes Pending)" && tm $u "run cm config-sync to-group datasync-global-dg" >/dev/null; done
  [ "$(for u in $UNITS; do tm $u 'show cm sync-status' | awk '/^Status/ {print $2,$3}'; done | sort -u)" = "In Sync" ] && break; sleep 10; done
for u in $UNITS; do say "$u: $(tm $u 'show cm failover-status' | awk '/^Status/ {print $2}') | $(tm $u 'show cm sync-status' | awk '/^Status/ {print $2,$3}')"; done
