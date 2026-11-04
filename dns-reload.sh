#!/bin/bash
# dns-reload.sh [--check]: load shared/dc.lab.zone (gen.py) into the RUNNING resolvers without restarting them: dns-ntp1 (primary) gets the
# zone with a fresh serial and checks it (named-checkzone) before swapping it in, then reloads it; dns-ntp2 (secondary) is notified and transfers
# it (also-notify, svc-up.sh). Checks: both answer the same serial, and a sample of the lab's names from each resolver. --check only compares.
cd "$(dirname "$0")"; . ./lib.sh
q() { X $1 "dig +short @127.0.0.1 $2" | xargs; }
serials() { echo "dns-ntp1 $(X dns-ntp1 'dig +short @127.0.0.1 dc.lab SOA' | awk '{print $3}') dns-ntp2 $(X dns-ntp2 'dig +short @127.0.0.1 dc.lab SOA' | awk '{print $3}')"; }
if [ "${1:-}" != --check ]; then
  s=$(date +%s)
  X dns-ntp1 "sed 's/SERIAL/$s/' /shared/dc.lab.zone > /var/bind/dc.lab.zone.new && named-checkzone -q dc.lab /var/bind/dc.lab.zone.new" \
    || { say "the new zone does not load (named-checkzone), the running one is kept"; exit 1; }
  X dns-ntp1 "mv /var/bind/dc.lab.zone.new /var/bind/dc.lab.zone && chown named:named /var/bind/dc.lab.zone && (rndc reload dc.lab 2>/dev/null || kill -HUP \$(pidof named))" >/dev/null
  say "dns-ntp1: zone serial $s loaded"
  for i in $(seq 1 12); do set -- $(serials); [ "$2" = "$s" ] && [ "$4" = "$s" ] && break; sleep 5; done
fi
say "serials: $(serials)"
for r in dns-ntp1 dns-ntp2; do
  say "$r: api.prod $(q $r api.prod.dc.lab) | api.dev $(q $r api.dev.dc.lab) | api.gpu $(q $r api.gpu.dc.lab) | console.apps.prod $(q $r console-openshift-console.apps.prod.dc.lab) | chat.dev $(q $r chat.dev.dc.lab) | llm.apps.gpu $(q $r llm.apps.gpu.dc.lab) | model $(q $r model.dc.lab) | prod-cp1.prod $(q $r prod-cp1.prod.dc.lab) | bastion.gpu $(q $r bastion.gpu.dc.lab)"
done
