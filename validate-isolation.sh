#!/bin/bash
# validate-isolation.sh: hard tenancy: a cluster per tenant on the SAME addresses, each in its own VRF, PA-VM virtual router, BIG-IP route
# domain and ONTAP IPspace. Every check from a real vantage point: the tenant probes (probe-prod / probe-dev, both 10.0.2.10), a tenant pod, the
# tenant bastions (both 10.0.2.11), bastion-gpu (Vrf-Ocp), client-lan1 on the external LAN, and the BIG-IP's configuration.
#   1 the same address answers as a different tenant in each VRF (node API .5, ingress .7, apps .200-.204, SVM .250)
#   2 what a tenant can reach outside itself: only the model VIP 10.0.5.11 toward the gpu cluster, nothing of the other tenant
#   3 a tenant pod: its own probe at 10.0.2.10, never the gpu node network
#   4 credentials: one cluster's admin credentials, carried into the other tenant's VRF, reach that tenant's API (the same address) and are refused
#   5 the users, the keys, the storage, the BIG-IP
# One PASS/FAIL line each -> results/<lab>_isolation_<ts>/result.txt. The vsadmin password from appliances.env (stdin to curl); kubeconfigs never leave the bastions' /tmp (600).
cd "$(dirname "$0")"; . ./lib.sh; . ./f5.env
P=0; F=0; RD=$(resdir isolation); OUT=$RD/result.txt; CMDLOG=$PWD/$RD/commands.txt; : > $OUT; : > $CMDLOG
log() { echo "$*" | tee -a $OUT; }
ok() { if [ "$2" = 0 ]; then log "PASS  $1"; P=$((P+1)); else log "FAIL  $1  ($3)"; F=$((F+1)); fi; }
want() { local got; [ -n "${CMDLOG:-}" ] && printf '$ %s\n' "$2" | redact >> "$CMDLOG"; got=$(eval "$2" 2>&1 | tr '\n' ' ' | sed 's/ *$//'); echo "$got" | grep -q -E "$3"; ok "$1" $? "got: $(echo $got | head -c 160)"; }
deny() { local got; [ -n "${CMDLOG:-}" ] && printf '$ %s\n' "$2" | redact >> "$CMDLOG"; got=$(eval "$2" 2>&1); if echo "$got" | grep -q -E "$3"; then ok "$1" 1 "reached: $(echo $got | head -c 90)"; else ok "$1" 0; fi; }
OC() { local cl=$1; shift; docker exec $C-bastion-$cl oc "$@" 2>&1; }
CODE() { echo "$(X $1 "curl -sk -m 6 -o /dev/null -w %{http_code} $2" | tail -c 3)"; }        # an HTTP status from a lab host; 000 = no connection
PX() { local p; p=$(OC $1 -n whoami get pod -l app=whoami -o name | head -1); OC $1 -n whoami exec ${p#pod/} -c httpd -- sh -c "$2"; }   # in a tenant pod
key() { OC $1 -n platform get secret inference-api-key -o jsonpath='{.data.key}' | base64 -d; }
# which cluster an API / ingress address belongs to, as seen from a host: the OAuth issuer of the API, the router's default certificate
issuer() { X $1 "curl -sk -m 8 https://$2:6443/.well-known/oauth-authorization-server" | grep -oE 'oauth-openshift\.apps\.[a-z]+\.dc\.lab' | head -1; }
ingcert() { X $1 "curl -skv -m 8 -o /dev/null https://$2/ 2>&1" | grep -oE 'subject: .*CN *= *\*\.apps\.[a-z]+\.dc\.lab' | grep -oE '\*\.apps\.[a-z]+\.dc\.lab' | head -1; }
# the SVM behind 10.0.3.250 in a host's VRF (vsadmin, the password on stdin)
svmat() { printf 'user = "vsadmin:%s"\n' "$ONTAP_VSADMIN_PW" | docker exec -i $C-$1 sh -c "curl -sk -m 8 -K - https://$2/api/svm/svms" | grep -oE '"name": *"svm-[a-z]+"' | grep -oE 'svm-[a-z]+' | sort -u | xargs; }
# xcred <whose cluster> <from bastion>: <whose>'s admin client certificate, used from the other tenant's bastion against https://10.0.1.5:6443
# (the same address, the other cluster's API): the HTTP code of a node list. The key lives in a 600 file in that bastion's /tmp for one call.
xcred() { docker exec $C-bastion-$1 cat /w/agent/build/auth/kubeconfig | docker exec -i $C-bastion-$2 sh -c 'umask 077; d=$(mktemp -d); cat > $d/kc
  grep "client-certificate-data:" $d/kc | head -1 | awk "{print \$2}" | base64 -d > $d/c.pem; grep "client-key-data:" $d/kc | head -1 | awk "{print \$2}" | base64 -d > $d/k.pem
  curl -sk -m 10 --cert $d/c.pem --key $d/k.pem -o /dev/null -w "%{http_code}" https://10.0.1.5:6443/api/v1/nodes; rm -rf $d'; }
# xkube <whose cluster> <from bastion>: oc with <whose> kubeconfig as is (its own CA) from the other bastion: TLS must fail (another cluster answers)
xkube() { docker exec $C-bastion-$1 cat /w/agent/build/auth/kubeconfig | docker exec -i $C-bastion-$2 sh -c 'umask 077; f=$(mktemp); cat > $f
  oc --kubeconfig $f --request-timeout=10s get nodes --no-headers 2>&1 | head -2; rm -f $f'; }

log "== 1. the same address, another tenant: probe-prod and probe-dev are both 10.0.2.10"
for t in prod dev; do
  want "probe-$t > 10.0.1.5:6443 is cluster $t's API (OAuth issuer oauth-openshift.apps.$t.dc.lab)" "issuer probe-$t 10.0.1.5" "^oauth-openshift\.apps\.$t\.dc\.lab$"
  want "probe-$t > 10.0.1.7:443 is cluster $t's router (default certificate *.apps.$t.dc.lab)" "ingcert probe-$t 10.0.1.7" "^\*\.apps\.$t\.dc\.lab$"
  want "probe-$t > whoami at 10.0.1.200:8080 (MetalLB in Vrf-${t^}) answers as tenant $t" "X probe-$t 'curl -s -m 6 http://10.0.1.200:8080/'" "^tenant $t "
  want "probe-$t > 10.0.1.201-.204 (chat, inference, harbor, minio) all answer in Vrf-${t^}" "for a in 201:8080 202:80 203:443 204:9001; do X probe-$t \"curl -sk -m 6 -o /dev/null -w %{http_code} \$([ \${a#*:} = 443 ] && echo https || echo http)://10.0.1.\${a%:*}:\${a#*:}/\"; echo; done | paste -sd' '" "^[1-4][0-9][0-9] [1-4][0-9][0-9] [1-4][0-9][0-9] [1-4][0-9][0-9]$"
  want "probe-$t > 10.0.3.250 (vsadmin) is svm-$t (IPspace $t)" "svmat probe-$t 10.0.3.250" "^svm-$t$"
done
log "== 2. what a tenant reaches beyond itself: the model VIP only"
for t in prod dev; do
  want "probe-$t reaches the shared model VIP model.dc.lab (10.0.5.11, the BIG-IP: the only door to the gpu cluster)" "CODE probe-$t https://model.dc.lab/health" "^200$"
  want "probe-$t cannot reach the gpu cluster itself (API 10.0.8.5, ingress 10.0.8.7, a GPU worker 10.0.8.21, svm-gpu 10.0.9.250)" "for u in https://10.0.8.5:6443/version https://10.0.8.7/ http://10.0.8.21:10250/ https://10.0.9.250/; do CODE probe-$t \$u; done | paste -sd' '" "^000 000 000 000$"
done
log "== 3. from inside a tenant pod (its cluster's default network, egress through its own VRF)"
for t in prod dev; do
  want "a $t pod > 10.0.2.10 reaches probe-$t (the page of the probe in ITS tenant)" "PX $t 'curl -s -m 6 http://10.0.2.10/'" "^probe-$t 10\.0\.2\.10"
  want "a $t pod reaches the model VIP (10.0.5.11)" "PX $t 'curl -sk -m 8 -o /dev/null -w %{http_code} https://model.dc.lab/health'" "^200$"
  deny "a $t pod cannot reach the gpu cluster's router 10.0.8.7 or API 10.0.8.5" "PX $t 'curl -sk -m 6 -o /dev/null -w %{http_code} https://10.0.8.7/; curl -sk -m 6 -o /dev/null -w %{http_code} https://10.0.8.5:6443/version'" "[1-5][0-9][0-9]"
done
log "== 4. credentials: one cluster's admin, carried into the other tenant's VRF"
for t in prod dev; do o=$([ $t = prod ] && echo dev || echo prod)
  want "$o's kubeconfig used on bastion-$t: api.$o.dc.lab resolves to 10.0.1.5, which in Vrf-${t^} is $t's API: TLS refuses it ($o's CA)" "xkube $o $t" "x509|certificate|tls"
  want "$o's admin client certificate presented to 10.0.1.5 from bastion-$t ($t's API, verification off): refused (401)" "xcred $o $t" "^401$"
  want "$t's own admin certificate on the same call: answered (200, the control of the check above)" "xcred $t $t" "^200$"
done
log "== the platform network (Vrf-Ocp): bastion-gpu runs the gpu cluster, sees no tenant"
want "bastion-gpu reaches its API (api.gpu.dc.lab 10.0.8.5) and the model API (llm.apps.gpu.dc.lab)" "docker exec $C-bastion-gpu curl -sk -m 6 -o /dev/null -w '%{http_code} ' https://api.gpu.dc.lab:6443/readyz; docker exec $C-bastion-gpu curl -sk -m 6 https://llm.apps.gpu.dc.lab/health" "^200 .*ok"
want "bastion-gpu cannot reach a tenant API, ingress or app (10.0.1.5, 10.0.1.7, 10.0.1.200: no 10.0.1.0/24 in Vrf-Ocp)" "CODE bastion-gpu https://10.0.1.5:6443/version; CODE bastion-gpu https://10.0.1.7/; CODE bastion-gpu http://10.0.1.200:8080/" "^000 000 000$"
log "== 5. the users (client-lan1, external LAN): each tenant behind its own PA-VM address and BIG-IP route domain"
want "client-lan1 > 192.168.100.142 = prod, > .143 = dev" "X client-lan1 'curl -sk -m 15 --resolve whoami.prod.dc.lab:443:192.168.100.142 https://whoami.prod.dc.lab/; curl -sk -m 15 --resolve whoami.dev.dc.lab:443:192.168.100.143 https://whoami.dev.dc.lab/'" "^tenant prod .*tenant dev "
deny "client-lan1 > .142 with dev's name never reaches dev (prod's virtual server has no dev pool)" "X client-lan1 'curl -sk -m 15 --resolve whoami.dev.dc.lab:443:192.168.100.142 https://whoami.dev.dc.lab/'" "tenant dev"
deny "client-lan1 > .143 with prod's name never reaches prod" "X client-lan1 'curl -sk -m 15 --resolve whoami.prod.dc.lab:443:192.168.100.143 https://whoami.prod.dc.lab/'" "tenant prod"
deny "client-lan1 > .144 (prod's console address) with dev's console name never reaches dev's cluster" "X client-lan1 'curl -skv -m 15 -o /dev/null --resolve console-openshift-console.apps.dev.dc.lab:443:192.168.100.144 https://console-openshift-console.apps.dev.dc.lab/ 2>&1' | grep -o 'CN *= *[^ ,]*'" "apps\.dev\.dc\.lab"
deny "prod's API key is refused by dev's inference API" "docker exec -e K=\"\$(key prod)\" $C-client-lan1 sh -c 'curl -sk -m 20 -o /dev/null -w %{http_code} -H \"apikey: \$K\" https://inference.dev.dc.lab/models/lfm2.5-24b/proxy/v1/models'" "^200$"
deny "dev's API key is refused by prod's inference API" "docker exec -e K=\"\$(key dev)\" $C-client-lan1 sh -c 'curl -sk -m 20 -o /dev/null -w %{http_code} -H \"apikey: \$K\" https://inference.prod.dc.lab/models/lfm2.5-24b/proxy/v1/models'" "^200$"
log "== storage: each tenant's data on its own SVM, in its own IPspace"
want "each tenant's NFS marker comes from its own SVM" "X client-lan1 'curl -sk -m 15 https://whoami.prod.dc.lab/data/marker.txt; curl -sk -m 15 https://whoami.dev.dc.lab/data/marker.txt'" "written by prod on svm-prod .*written by dev on svm-dev"
want "ONTAP: the three SVMs sit in three IPspaces (gpu, prod, dev)" "ONTAP 'vserver show -vserver svm-gpu,svm-prod,svm-dev -fields ipspace' | awk '\$1 ~ /^svm-/ {print \$1\"=\"\$2}' | sort | paste -sd' '" "svm-dev=dev svm-gpu=gpu svm-prod=prod"
log "== the BIG-IP: no virtual server crosses tenants"
A=$(for u in $UNITS; do ./bigip-run.sh $u 'tmsh show cm failover-status' 2>/dev/null | grep -qE '^Status +ACTIVE' && echo $u; done | head -1)
want "no virtual server in rd-prod uses a dev pool, none in rd-dev a prod pool" "./bigip-run.sh $A 'tmsh list ltm virtual one-line' | grep -E '%1:.*pool-dev|%2:.*pool-prod' | wc -l" "^ *0 *$"
want "every prod pool member is in rd 1, every dev member in rd 2 (the same addresses 10.0.1.200-.204)" "./bigip-run.sh $A 'tmsh list ltm pool one-line' | grep -oE 'pool-(prod|dev)-[a-z]+ .*members \\{ [0-9.]+%[0-9]+' | sed -E 's/^pool-(prod|dev)-[a-z]+ .*%([0-9]+)$/\\1=\\2/' | sort | uniq -c | tr -s ' ' | paste -sd' '" "^ ?5 dev=2 +5 prod=1"
log ""; log "RESULT: $P passed, $F failed ($RD)"
[ $F = 0 ]
