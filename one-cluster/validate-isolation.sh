#!/bin/bash
# validate-isolation.sh: one cluster, two tenants that never see each other. Every check from a real vantage point:
#   the tenant probes (probe-prod 10.10.2.10 in Vrf-Prod, probe-dev 10.20.2.10 in Vrf-Dev), a tenant pod on its UDN, bastion-ocp (Vrf-Ocp),
#   client-lan1 on the external LAN, and the BIG-IP's configuration.
# One PASS/FAIL line each -> results/<lab>_isolation_<ts>/result.txt
cd "$(dirname "$0")"; . ./lib.sh; . ./f5.env
P=0; F=0; RD=$(resdir isolation); OUT=$RD/result.txt; CMDLOG=$PWD/$RD/commands.txt; : > $OUT; : > $CMDLOG; B=$C-bastion-ocp
log() { echo "$*" | tee -a $OUT; }
ok() { if [ "$2" = 0 ]; then log "PASS  $1"; P=$((P+1)); else log "FAIL  $1  ($3)"; F=$((F+1)); fi; }
want() { local got; [ -n "${CMDLOG:-}" ] && printf '$ %s\n' "$2" | redact >> "$CMDLOG"; got=$(eval "$2" 2>&1 | tr '\n' ' ' | sed 's/ *$//'); echo "$got" | grep -q -E "$3"; ok "$1" $? "got: $(echo $got | head -c 160)"; }
deny() { local got; [ -n "${CMDLOG:-}" ] && printf '$ %s\n' "$2" | redact >> "$CMDLOG"; got=$(eval "$2" 2>&1); if echo "$got" | grep -q -E "$3"; then ok "$1" 1 "reached: $(echo $got | head -c 90)"; else ok "$1" 0; fi; }
OC() { docker exec $B oc "$@" 2>&1; }
CODE() { echo "$(X $1 "curl -sk -m 6 -o /dev/null -w %{http_code} $2" | tail -c 3)"; }        # an HTTP status from a lab host; 000 = no connection
PX() { local p; p=$(OC -n $1-apps get pod -l app=whoami -o name | head -1); OC -n $1-apps exec ${p#pod/} -c httpd -- sh -c "$2"; }   # in a tenant pod
udn() { OC -n $1-apps get pod -l app=whoami -o jsonpath='{.items[0].metadata.annotations.k8s\.ovn\.org/pod-networks}' | python3 -c 'import json,sys
d=json.load(sys.stdin); print(next(v["ip_address"].split("/")[0] for v in d.values() if v.get("role") == "primary"))'; }
key() { OC -n $1-platform get secret inference-api-key -o jsonpath='{.data.key}' | base64 -d; }
declare -A NET=([prod]=10.10 [dev]=10.20); declare -A VRF=([prod]=Vrf-Prod [dev]=Vrf-Dev)
UP=$(udn prod); UD=$(udn dev); declare -A UDN=([prod]=$UP [dev]=$UD)
log "== the tenant networks: each probe reaches its own tenant's apps, never the other's (VRF-lite)"
for t in prod dev; do o=$([ $t = prod ] && echo dev || echo prod); p=${NET[$t]}; q=${NET[$o]}
  want "probe-$t > $t's whoami LoadBalancer $p.1.200 answers as tenant $t" "X probe-$t 'curl -s -m 6 http://$p.1.200:8080/'" "^tenant $t "
  want "probe-$t > $t's whoami pod on its UDN (${UDN[$t]}) answers directly (routed pod network, RouteAdvertisements)" "X probe-$t 'curl -s -m 6 http://${UDN[$t]}:8080/'" "^tenant $t "
  want "probe-$t cannot reach any of $o's app addresses ($q.1.200-.204)" "for i in 200 201 202 203 204; do CODE probe-$t https://$q.1.\$i/; done | paste -sd' '" "^000 000 000 000 000$"
  want "probe-$t cannot reach $o's pod (${UDN[$o]})" "CODE probe-$t http://${UDN[$o]}:8080/" "^000$"
  want "probe-$t cannot reach the cluster's API (10.0.1.5) or ingress (10.0.1.7): Vrf-Ocp is not a tenant's" "CODE probe-$t https://10.0.1.5:6443/version; CODE probe-$t https://10.0.1.7/" "^000 000$"
  want "probe-$t reaches the shared model VIP model.dc.lab (10.0.5.11, the BIG-IP: the only door to Vrf-Ocp)" "CODE probe-$t https://model.dc.lab/health" "^200$"
done
log "== from inside a tenant pod (primary UDN, its egress through its tenant VRF)"
for t in prod dev; do o=$([ $t = prod ] && echo dev || echo prod)
  want "a $t pod reaches probe-$t (${NET[$t]}.2.10) through ${VRF[$t]}" "PX $t 'curl -s -m 6 -o /dev/null -w %{http_code} http://${NET[$t]}.2.10/'" "^[1-5][0-9][0-9]$"
  deny "a $t pod cannot reach probe-$o (${NET[$o]}.2.10)" "PX $t 'curl -s -m 6 -o /dev/null -w %{http_code} http://${NET[$o]}.2.10/'" "^[1-5][0-9][0-9]$"
  deny "a $t pod cannot reach $o's pod (${UDN[$o]}) across the UDNs" "PX $t 'curl -s -m 6 http://${UDN[$o]}:8080/'" "tenant $o"
  deny "a $t pod cannot reach $o's whoami LoadBalancer (${NET[$o]}.1.200)" "PX $t 'curl -s -m 6 http://${NET[$o]}.1.200:8080/'" "tenant $o"
done
log "== the platform network (Vrf-Ocp): bastion-ocp manages the cluster, sees no tenant"
want "bastion-ocp reaches the API (10.0.1.5) and the model API (llm.apps.ocp.dc.lab)" "docker exec $B curl -sk -m 6 -o /dev/null -w '%{http_code} ' https://api.ocp.dc.lab:6443/readyz; docker exec $B curl -sk -m 6 https://llm.apps.ocp.dc.lab/health" "^200 .*ok"
for t in prod dev; do
  want "bastion-ocp cannot reach $t's apps (${NET[$t]}.1.200) or $t's pod (${UDN[$t]})" "CODE bastion-ocp http://${NET[$t]}.1.200:8080/; CODE bastion-ocp http://${UDN[$t]}:8080/" "^000 000$"
done
log "== the users (client-lan1, external LAN): each tenant behind its own PA-VM address and BIG-IP route domain"
want "client-lan1 > 192.168.100.142 = prod, > .143 = dev" "X client-lan1 'curl -sk -m 15 --resolve whoami.prod.dc.lab:443:192.168.100.142 https://whoami.prod.dc.lab/; curl -sk -m 15 --resolve whoami.dev.dc.lab:443:192.168.100.143 https://whoami.dev.dc.lab/'" "^tenant prod .*tenant dev "
deny "client-lan1 > .142 with dev's name never reaches dev (prod's virtual server has no dev pool)" "X client-lan1 'curl -sk -m 15 --resolve whoami.dev.dc.lab:443:192.168.100.142 https://whoami.dev.dc.lab/'" "tenant dev"
deny "client-lan1 > .143 with prod's name never reaches prod" "X client-lan1 'curl -sk -m 15 --resolve whoami.prod.dc.lab:443:192.168.100.143 https://whoami.prod.dc.lab/'" "tenant prod"
deny "prod's API key is refused by dev's inference API" "docker exec -e K=\"\$(key prod)\" $C-client-lan1 sh -c 'curl -sk -m 20 -o /dev/null -w %{http_code} -H \"apikey: \$K\" https://inference.dev.dc.lab/models/lfm2.5-24b/proxy/v1/models'" "^200$"
deny "dev's API key is refused by prod's inference API" "docker exec -e K=\"\$(key dev)\" $C-client-lan1 sh -c 'curl -sk -m 20 -o /dev/null -w %{http_code} -H \"apikey: \$K\" https://inference.prod.dc.lab/models/lfm2.5-24b/proxy/v1/models'" "^200$"
log "== storage: each tenant's data on its own SVM, in its own IPspace"
want "each tenant's NFS marker comes from its own SVM" "X client-lan1 'curl -sk -m 15 https://whoami.prod.dc.lab/data/marker.txt; curl -sk -m 15 https://whoami.dev.dc.lab/data/marker.txt'" "written by prod on svm-prod .*written by dev on svm-dev"
want "ONTAP: the three SVMs sit in three IPspaces (ocp, prod, dev)" "ONTAP 'vserver show -vserver svm-ocp,svm-prod,svm-dev -fields ipspace' | awk '\$1 ~ /^svm-/ {print \$1\"=\"\$2}' | sort | paste -sd' '" "svm-dev=dev svm-ocp=ocp svm-prod=prod"
log "== the BIG-IP: no virtual server crosses tenants"
A=$(for u in $UNITS; do ./bigip-run.sh $u 'tmsh show cm failover-status' 2>/dev/null | grep -qE '^Status +ACTIVE' && echo $u; done | head -1)
want "no virtual server in rd-prod uses a dev pool, none in rd-dev a prod pool" "./bigip-run.sh $A 'tmsh list ltm virtual one-line' | grep -E '%1:.*pool-dev|%2:.*pool-prod' | wc -l" "^ *0 *$"
want "every prod pool member is in rd 1, every dev member in rd 2" "./bigip-run.sh $A 'tmsh list ltm pool one-line' | grep -oE 'pool-(prod|dev)-[a-z]+ .*members \\{ [0-9.]+%[0-9]+' | sed -E 's/^pool-(prod|dev)-[a-z]+ .*%([0-9]+)$/\\1=\\2/' | sort | uniq -c | tr -s ' ' | paste -sd' '" "^ ?5 dev=2 +5 prod=1"
log ""; log "RESULT: $P passed, $F failed ($RD)"
[ $F = 0 ]
