#!/bin/bash
# validate-f5.sh: the BIG-IP pair and the users' path, end to end. One PASS/FAIL line each -> results/<lab>_f5_<ts>/result.txt
#   licences + ledger | HA (one active, in sync) | eBGP per route domain to both border leaves | the apps VIP 10.0.5.10/32 in Vrf-Prod and
#   Vrf-Dev, from the active unit only | rd-ocp the parent of the tenants' route domains, the model VIP 10.0.5.11 | every app pool up |
#   client-lan1 / client-lan2 > PA .142 / .143 > F5 > the right tenant, with the lab CA | console / OAuth on .144 straight to the router |
#   the WAF blocks XSS / SQL injection / path traversal in both tenants, logs what it blocks, and lets a real chat request through;
#   it passes the gateways' 429 / 503 and logs the key headers masked
cd "$(dirname "$0")"; . ./lib.sh; . ./f5.env
P=0; F=0; RD=$(resdir f5); OUT=$RD/result.txt; CMDLOG=$PWD/$RD/commands.txt; : > $OUT; : > $CMDLOG
log() { echo "$*" | tee -a $OUT; }
ok() { if [ "$2" = 0 ]; then log "PASS  $1"; P=$((P+1)); else log "FAIL  $1  ($3)"; F=$((F+1)); fi; }
want() { local got; [ -n "${CMDLOG:-}" ] && printf '$ %s\n' "$2" | redact >> "$CMDLOG"; got=$(eval "$2" 2>&1 | tr '\n' ' '); echo "$got" | grep -q -E "$3"; ok "$1" $? "got: $(echo $got | head -c 160)"; }
deny() { local got; [ -n "${CMDLOG:-}" ] && printf '$ %s\n' "$2" | redact >> "$CMDLOG"; got=$(eval "$2" 2>&1); if echo "$got" | grep -q -E "$3"; then ok "$1" 1 "reached: $(echo $got | head -c 90)"; else ok "$1" 0; fi; }
BR() { ./bigip-run.sh "$@" | sed -E 's/[A-Z0-9]{5}(-[A-Z0-9]{5}){3}-[A-Z0-9]{7}/<regkey>/g'; }
CA=/root/scd-secrets/tls/ca.crt
log "== BIG-IP pair lb-f5a / lb-f5b"
for u in $UNITS; do want "$u: licensed (Best Bundle), the key bound to it in the ledger" "BR $u 'tmsh show sys license' | grep -E '^(Licensed Version|License End Date)'; grep '$LAB/$u' /root/scd-secrets/f5-licence-ledger | cut -d'|' -f2-3" "License End Date.*bound"; done
want "exactly one unit ACTIVE, the other STANDBY" "for u in $UNITS; do BR \$u 'tmsh show cm failover-status' | awk '/^Status/ {print \$2}'; done | sort | tr '\n' ' '" "^ACTIVE STANDBY $"
want "the pair is in sync (dg-lb-f5)" "for u in $UNITS; do BR \$u 'tmsh show cm sync-status' | awk '/^Status/ {print \$2,\$3}'; done | sort -u" "^In Sync $"
for cl in prod dev; do rd=RD_$cl; vrf=$([ $cl = prod ] && echo Vrf-Prod || echo Vrf-Dev)
  for u in $UNITS; do want "$u rd-$cl: eBGP up to both border leaves" "BR $u \"imish -r ${!rd} -e 'show ip bgp summary'\" | grep -E '^10\.254\.' | awk '\$NF ~ /^[0-9]+\$/' | wc -l" "^ *2 *$"; done
  for b in leaf6a-border leaf6b-border; do
    want "$b $vrf: $VIP/32 learnt from the BIG-IP (RHI)" "KL $b 'show ip route vrf $vrf $VIP/32'" "B>\*? *$VIP/32"
  done
done
A=$(for u in $UNITS; do BR $u 'tmsh show cm failover-status' | grep -qE '^Status +ACTIVE' && echo $u; done | head -1); S=$(echo $UNITS | tr ' ' '\n' | grep -vx "$A")
want "only the active unit ($A) holds the VIP route; the standby ($S) none" "for r in 1 2; do BR $S \"imish -r \$r -e 'show ip route kernel'\" | grep -c '$VIP'; done | tr '\n' ' '" "^0 0 $"
log "== the shared model API: rd-ocp (Vrf-Ocp) is the parent of rd-prod and rd-dev"
want "rd-ocp (3): strict isolation, no parent" "BR $A 'tmsh list net route-domain rd-ocp all-properties' | grep -E '^ +(parent|strict) ' | tr -s ' '" "parent none +strict enabled"
for cl in prod dev; do want "rd-$cl: parent rd-ocp, strict disabled (a child reaches only its parent)" "BR $A 'tmsh list net route-domain rd-$cl all-properties' | grep -E '^ +(parent|strict) ' | tr -s ' '" "parent (/Common/)?rd-ocp +strict disabled"; done
for u in $UNITS; do want "$u rd-ocp: eBGP up to both border leaves" "BR $u \"imish -r $RD_ocp -e 'show ip bgp summary'\" | grep -E '^10\.254\.' | awk '\$NF ~ /^[0-9]+\$/' | wc -l" "^ *2 *$"; done
want "rd-ocp learns the cluster network 10.0.1.0/24 from the borders" "BR $A \"imish -r $RD_ocp -e 'show ip route 10.0.1.0/24'\"" "10\.0\.1\.0/24"
want "pool-ocp-llm (10.0.1.7%3, the cluster's router, host llm.apps.ocp.dc.lab) up: /health answers ok" "BR $A 'tmsh show ltm pool pool-ocp-llm field-fmt' | awk '/status.availability-state/ {print \$2}' | head -1" "^available"
for vrf in Vrf-Prod Vrf-Dev; do for b in leaf6a-border leaf6b-border; do
  want "$b $vrf: model VIP $MODEL_VIP/32 learnt from the BIG-IP (RHI)" "KL $b 'show ip route vrf $vrf $MODEL_VIP/32'" "B>\\*? *$MODEL_VIP/32"; done; done
want "no virtual server in a tenant route domain uses a pool member of the other tenant (%1 > %2 or %2 > %1)" "BR $A 'tmsh list ltm virtual one-line' | grep -E '%1:.*pool-dev|%2:.*pool-prod' | wc -l" "^ *0 *$"
for cl in prod dev; do for n in whoami chat inference harbor minio; do
  want "pool-$cl-$n up (its MetalLB address in ${cl}'s VRF)" "BR $A 'tmsh show ltm pool pool-$cl-$n field-fmt' | awk '/status.availability-state/ {print \$2}' | head -1" "^available"; done; done
log "== the users: client-lan1 / client-lan2 on the external LAN"
for c in client-lan1 client-lan2; do
  docker cp $CA $C-$c:/tmp/lab-ca.crt >/dev/null 2>&1
  for cl in prod dev; do
    want "$c > whoami.$cl.dc.lab through the PA and the F5: tenant $cl, certificate from the lab CA" "X $c 'curl -s -m 15 --cacert /tmp/lab-ca.crt https://whoami.$cl.dc.lab/'" "^tenant $cl "
  done
  want "$c > console-openshift-console.apps.ocp.dc.lab on .144, straight to the router" "X $c 'curl -sk -m 15 -o /dev/null -w \"%{http_code} %{remote_ip}\" https://console-openshift-console.apps.ocp.dc.lab/'" "^(200|302) 10\.80\.15\.144$"
  deny "$c: prod's address with dev's name never reaches dev" "X $c 'curl -sk -m 15 --resolve whoami.dev.dc.lab:443:192.168.100.142 https://whoami.dev.dc.lab/'" "tenant dev"
done
# WAF helpers: the policy's settings, and what the event log keeps of a blocked request that carried an apikey header (a probe value, never a key)
pol() { python3 -I bigip_api.py $A GET "/mgmt/tm/asm/policies?\$filter=fullPath+eq+'/Common/waf-$1-apps'&\$select=id" | python3 -c 'import json,sys; print(json.load(sys.stdin)["items"][0]["id"])'; }
codes() { python3 -I bigip_api.py $A GET /mgmt/tm/asm/policies/$(pol $1)/general | python3 -c 'import json,sys; print(" ".join(map(str, json.load(sys.stdin)["allowedResponseCodes"])))'; }
masked() { python3 -I bigip_api.py $A GET /mgmt/tm/asm/policies/$(pol $1)/headers | python3 -c 'import json,sys; print(" ".join(sorted(i["name"] for i in json.load(sys.stdin)["items"] if i.get("maskValueInLogs"))))'; }
maskprobe() { local v=d94probe$(date +%s%N | tail -c 13); X client-lan1 "curl -sk -m 15 -H 'apikey: $v' 'https://whoami.$1.dc.lab/?q=%3Cscript%3Ealert(1)%3C/script%3E'" >/dev/null; sleep 8
  python3 -I bigip_api.py $A GET "/mgmt/tm/asm/events/requests?\$top=30&\$orderby=requestDatetime+desc" | V=$v python3 -c 'import json,os,sys
r=[i.get("rawRequest",{}).get("httpRequestUnescaped","") for i in json.load(sys.stdin).get("items",[])]; v=os.environ["V"]
n=r[0] if r else ""; print("logged", int("apikey:" in n.lower() and "alert(1)" in n), "clear", int(v in n))'; }   # the newest event is the probe
log "== WAF per tenant (waf-<tenant>-apps, blocking, illegal requests logged)"
for cl in prod dev; do
  for t in "XSS:?q=%3Cscript%3Ealert(document.cookie)%3C/script%3E" "SQL injection:?id=1%27%20or%201=1--" "path traversal:/../../etc/passwd"; do
    n=${t%%:*}; q=${t#*:}
    want "$cl: $n is rejected by the WAF" "X client-lan1 'curl -sk -m 15 --path-as-is \"https://whoami.$cl.dc.lab/${q#/}\"'" "Request Rejected"
  done
  want "$cl: a normal request still passes the WAF" "X client-lan1 'curl -sk -m 15 https://whoami.$cl.dc.lab/'" "^tenant $cl "
  want "$cl: the policy lets the apps' 403, 429, 502, 503 and 504 answers through" "codes $cl" "(^| )403 .*429 .*502 503 504"
  want "$cl: apikey, authorization and x-api-key are masked in the event log" "masked $cl" "^apikey authorization x-api-key *$"
  want "$cl: a blocked request's apikey header is logged masked, never in clear" "maskprobe $cl" "^logged [1-9][0-9]* clear 0 *$"
  want "$cl: vs-$cl-apps logs illegal requests" "BR $A 'tmsh list ltm virtual vs-$cl-apps security-log-profiles'" "Log illegal requests"
  want "$cl: the last blocked request is in the ASM event log (support ID)" "python3 -I bigip_api.py $A GET \"/mgmt/tm/asm/events/requests?\\\$top=50&\\\$orderby=requestDatetime+desc\" | python3 -c 'import json,sys; print(sum(1 for r in json.load(sys.stdin).get(\"items\",[]) if r.get(\"requestStatus\")==\"blocked\"))'" "^[1-9][0-9]* *$"
  want "$cl: a chat completion (JSON POST, the API key) passes the WAF end to end" "docker exec -e K=\"\$(docker exec $C-bastion-ocp oc -n $cl-platform get secret inference-api-key -o jsonpath={.data.key} | base64 -d)\" $C-client-lan1 sh -c 'curl -sk -m 600 -H \"apikey: \$K\" -H content-type:application/json https://inference.$cl.dc.lab/models/qwen2.5-0.5b/proxy/v1/chat/completions -d \"{\\\"model\\\":\\\"qwen2.5-0.5b\\\",\\\"max_tokens\\\":16,\\\"messages\\\":[{\\\"role\\\":\\\"user\\\",\\\"content\\\":\\\"hi\\\"}]}\"'" "chat\.completion"
done
log ""; log "RESULT: $P passed, $F failed ($RD)"
[ $F = 0 ]
