#!/usr/bin/env bash
# f5.sh <step> [step ...]: the BIG-IP pair lb-f5a / lb-f5b. Every step is re-runnable.
#   secrets   write /root/scd-secrets/<unit>.env from f5-regkeys.txt: one key per unit, ONE admin password for the pair (config sync copies
#             users); refuses if the ledger shows a key bound to another lab                                         (up.sh, before the deploy)
#   licence   wait until both units hold their licence (auto-license at boot, needs the management NAT); ledger: bound, activation, end date
#   status    licence state of both units + the ledger
#   revoke    revoke both licences (REST, management routes to DNS and activate.f5.com), ledger: free; exit 1 if one is not confirmed free
#   base      per unit: LTM + ASM, distinct device names, route domains rd-ocp (3, strict) and its children rd-prod (1) / rd-dev (2)
#             (strict disabled, parent rd-ocp: a tenant may reach only the cluster route domain, never its sibling), tagged VLANs per border link, self IPs, eBGP
#             per route domain (advertisement-interval 0), tmrouted restart; then HA: trust, dg-lb-f5 (sync-failover, auto-sync, ASM sync),
#             floating self IPs, datasync check
#   model     the model API: VIP $MODEL_VIP in rd-prod and rd-dev (model.dc.lab, lab CA), one pool in rd-ocp = the cluster's default router
#             $MODEL_POOL%3, Host rewritten to $MODEL_HOST
# Keys are never printed: every output goes through mask(). The steps account for: distinct device names per unit, one admin password for
# the pair, bgpd%N starting late (loaded until present), tmrouted missing a route domain's VIP (restarted before VIPs), advertisement-interval 0,
# datasync-global-dg.
set -uo pipefail
cd "$(dirname "$0")"; . ./lib.sh; . ./f5.env
SEC=/root/scd-secrets; KEYS=$SEC/f5-regkeys.txt; LEDGER=$SEC/f5-licence-ledger
KEYRE='[A-Z0-9]{5}(-[A-Z0-9]{5}){3}-[A-Z0-9]{7}'
U=($UNITS); A=${U[0]}; Bu=${U[1]}
mask() { sed -E "s/$KEYRE/<regkey>/g"; }
keyid() { sed -E 's/^(.{5}).*(.{4})$/\1-…-\2/'; }
key_of() { local n=1; [ "$1" = "$Bu" ] && n=2; sed -n "${n}p" $KEYS; }   # never echoed: callers pipe it to keyid
B() { python3 -I bigip_api.py "$@"; }
BR() { ./bigip-run.sh "$@"; }
tm() { local u=$1; shift; BR $u "tmsh $*"; }    # one tmsh command per call (REST bash runs only the first line)
v() { local n="$1_${2//-/_}"; echo "${!n}"; }    # v OCTET lb-f5a > the variable OCTET_lb_f5a from f5.env

ledger_set() { umask 077; touch $LEDGER; { grep -v "^$1 |" $LEDGER; echo "$1 | $2 | $3 | $4 | $5"; } > $LEDGER.t && mv $LEDGER.t $LEDGER; }
ledger_get() { grep "^$1 |" $LEDGER 2>/dev/null; }

secrets() {
  [ "$(grep -cE "^$KEYRE$" $KEYS 2>/dev/null)" = 2 ] || { say "FAIL: $KEYS must hold exactly two keys"; return 1; }
  local u k l pw; pw=$(sed -n 's/^PASSWORD=//p' $SEC/$A.env 2>/dev/null); [ -n "$pw" ] || pw=$(openssl rand -hex 12)
  for u in "${U[@]}"; do
    k=$(key_of $u | keyid); l=$(ledger_get "$k")
    case "$l" in *"| bound |"*) echo "$l" | grep -q "| $LAB/$u |" || { say "FAIL: $k is bound elsewhere: $l"; return 1; };; esac
    if [ ! -s $SEC/$u.env ]; then
      umask 077   # ROOT_PASSWORD stays factory: the launcher's console fallback logs in with it and sets F5_NEW_PASSWORD (twinsite)
      printf 'F5_REGKEY=%s\nPASSWORD=%s\nROOT_PASSWORD=default\nF5_NEW_PASSWORD=%s\nF5_HOSTNAME=%s\nF5_DNS=1.1.1.1,8.8.8.8\n' \
        "$(key_of $u)" "$pw" "$pw" "$u.dc.lab" > $SEC/$u.env
    fi
    say "$u <- $k (ledger: ${l:-no entry})"
  done; }

licensed() { local out; out=$(B $1 GET /mgmt/tm/sys/license 2>/dev/null) || { echo unreachable; return; }
  if grep -q '"registrationKey"' <<<"$out"; then echo yes; elif grep -q '"kind"' <<<"$out"; then echo no; else echo unreachable; fi; }
lic_dates() { BR $1 "tmsh show sys license" 2>/dev/null | awk -F'  +' '/^Licensed On/ {a=$2} /^License End Date/ {e=$2} END {print a"|"e}'; }

licence() { local u s i k d f=0
  for u in "${U[@]}"; do k=$(key_of $u | keyid)
    for i in $(seq 1 120); do s=$(licensed $u); [ "$s" = yes ] && break; sleep 20; done
    if [ "$s" = yes ]; then d=$(lic_dates $u); ledger_set "$k" bound "$LAB/$u" "${d%%|*}" "${d##*|}"; say "$u: licensed ($k, ends ${d##*|})"
    else say "$u: NOT licensed after 40 min ($s)"; BR $u "tail -5 /var/log/autolicense.log" | mask; ledger_set "$k" unknown "$LAB/$u" - -; f=1; fi
  done; return $f; }

status() { local u; for u in "${U[@]}"; do docker inspect $C-$u >/dev/null 2>&1 && echo "$u: $(licensed $u)" || echo "$u: not deployed"; done
  echo "ledger:"; sed 's/^/  /' $LEDGER 2>/dev/null; }

# management routes to the resolvers and the licence server (safeguard; the data plane lives in route domains 1 / 2). One line (REST bash).
LIC_ROUTES='gw=172.21.30.1; n=0; for ip in 1.1.1.1 8.8.8.8 $(getent ahostsv4 activate.f5.com | awk "{print \$1}" | sort -u); do n=$((n+1)); tmsh create sys management-route lic-$n network $ip/32 gateway $gw 2>/dev/null; done'
revoke() { local u s i k f=0
  for u in "${U[@]}"; do k=$(key_of $u | keyid)
    docker inspect $C-$u >/dev/null 2>&1 || { say "$u: not deployed"; continue; }
    s=$(licensed $u)
    case $s in
      no) say "$u: not licensed, nothing to revoke"; ledger_set "$k" free - - - ;;
      yes) say "$u: revoking"; BR $u "$LIC_ROUTES" >/dev/null
           BR $u 'nohup sh -c "tmsh revoke sys license >/var/tmp/revoke.log 2>&1" >/dev/null 2>&1 &' >/dev/null
           for i in $(seq 1 18); do sleep 10; s=$(licensed $u); [ "$s" = no ] && break; done
           if [ "$s" = no ]; then say "$u: revoked"; ledger_set "$k" free - - -
           else say "$u: REVOKE FAILED ($s)"; BR $u "cat /var/tmp/revoke.log" | mask | tail -5; f=1; fi ;;
      *) say "$u: management unreachable, cannot confirm the licence is free"; f=1 ;;
    esac
  done; return $f; }

ready() { local u=$1 i r; for i in $(seq 1 90); do
    r=$(BR $u "tmsh show sys ready" 2>/dev/null); grep -qE "^provision +yes" <<<"$r" && grep -qE "^config +yes" <<<"$r" && return 0; sleep 10; done
  say "$u: not ready after 15 min"; return 1; }

provision() { local u=$1 m cur
  for m in ltm asm; do tm $u "list sys provision $m one-line" | grep -q "level nominal" && continue
    tm $u "modify sys provision $m level nominal" >/dev/null; sleep 30; ready $u || return 1; done
  cur=$(tm $u 'list cm device one-line' | awk '/self-device true/ {print $3}' | head -1)   # P-1: every vrnetlab VE boots as "bigip1"
  [ "$cur" = $u.dc.lab ] || { tm $u "modify sys global-settings hostname $u.dc.lab" >/dev/null; tm $u "mv cm device $cur $u.dc.lab" >/dev/null; }
  say "$u: $(tm $u 'list sys provision one-line' | grep -oE 'provision [a-z]+ \{ level [a-z]+' | awk '{print $2"="$5}' | tr '\n' ' ')device $u.dc.lab"; }

network() { local u=$1 o cl rd rn i
  o=$(v OCTET $u); local ha=192.168.255.$([ $u = $A ] && echo 1 || echo 2)
  tm $u "create net vlan ha-link interfaces add { 1.3 { untagged } } mtu 1500" >/dev/null 2>&1
  tm $u "create net self ha-self address $ha/30 vlan ha-link allow-service default traffic-group traffic-group-local-only" >/dev/null 2>&1
  for cl in $PARENT $TENANTS; do rd=$(v RD $cl); rn=$(v RDNAME $cl)
    for i in 1 2; do   # VLAN <tenant>-to-<border leaf>: 1.<i> tagged toward border i
      local b=BORDER_$i n=NET_$i t=TAG_${i}_$cl; local vl=$cl-to-${!b%%-*}
      tm $u "create net vlan $vl interfaces add { 1.$i { tagged } } tag ${!t} mtu 1500" >/dev/null 2>&1
    done
    local rdopt="strict enabled"; [ $cl = $PARENT ] || rdopt="strict disabled parent $(v RDNAME $PARENT)"   # a child route domain: strict disabled, parent the model route domain
    tm $u "create net route-domain $rn id $rd vlans add { $cl-to-leaf6a $cl-to-leaf6b } routing-protocol add { BGP } $rdopt" >/dev/null 2>&1
    for i in 1 2; do local n=NET_$i
      tm $u "create net self $cl-to-leaf6$([ $i = 1 ] && echo a || echo b)-self address ${!n}.$o%$rd/29 vlan $cl-to-leaf6$([ $i = 1 ] && echo a || echo b) allow-service replace-all-with { tcp:179 } traffic-group traffic-group-local-only" >/dev/null 2>&1
    done
  done
  tm $u "save sys config" >/dev/null
  say "$u: route domains $(tm $u 'list net route-domain one-line' | grep -oE 'route-domain [a-z0-9-]+ \{ id [0-9]+' | awk '{print $2"="$5}' | tr '\n' ' ')"
  say "$u: self IPs $(tm $u 'list net self one-line' | grep -oE 'address [^ ]+' | awk '{print $2}' | tr '\n' ' ')"; }

bgp() { local u=$1 o cl rd f i
  o=$(v OCTET $u)
  for cl in $TENANTS $PARENT; do rd=$(v RD $cl)
    f="ip prefix-list VIPS seq 10 permit $VIP/32\nip prefix-list VIPS seq 20 permit $MODEL_VIP/32\nroute-map VIPS permit 10\n match ip address prefix-list VIPS\n!\nrouter bgp $F5_ASN\n bgp router-id $NET_1.$o\n bgp log-neighbor-changes\n"
    for i in 1 2; do local n=NET_$i; f+=" neighbor ${!n}.1 remote-as $BORDER_ASN\n neighbor ${!n}.1 timers 3 9\n neighbor ${!n}.1 advertisement-interval 0\n"; done
    f+=" redistribute kernel route-map VIPS\n!\n"
    for i in $(seq 1 30); do BR $u "pgrep -f '[b]gpd%$rd' >/dev/null && echo up" | grep -q up && break; sleep 5; done
    BR $u "printf '$f' > /var/tmp/bgp-$cl.conf" >/dev/null
    for i in $(seq 1 12); do   # P-3: load until the running config holds it
      BR $u "imish -r $rd -f /var/tmp/bgp-$cl.conf >/dev/null 2>&1; imish -r $rd -e 'write memory' >/dev/null" >/dev/null
      BR $u "imish -r $rd -e 'show running-config'" | grep -q "advertisement-interval 0" && break; sleep 10; done
  done
  BR $u "bigstart restart tmrouted" >/dev/null   # P-4: before any VIP exists
  for cl in $TENANTS $PARENT; do rd=$(v RD $cl); local up=0
    for i in $(seq 1 24); do   # sessions come back within a minute after tmrouted; a route domain whose bgpd lost its config is re-loaded
      up=$(BR $u "imish -r $rd -e 'show ip bgp summary'" | grep -E '^10\.254\.' | awk '$NF ~ /^[0-9]+$/' | wc -l)
      [ "$up" = 2 ] && break
      [ $i = 12 ] && BR $u "imish -r $rd -f /var/tmp/bgp-$cl.conf >/dev/null 2>&1; imish -r $rd -e 'write memory' >/dev/null" >/dev/null
      sleep 10; done
    say "$u: $(v RDNAME $cl) BGP $(BR $u "imish -r $rd -e 'show ip bgp summary'" | grep -E '^10\.254\.' | awk '{print $1"="$NF}' | tr '\n' ' ')"; done; }

ha() { local pw u cl i
  for u in "${U[@]}"; do local ha=192.168.255.$([ $u = $A ] && echo 1 || echo 2)
    tm $u "modify cm device $u.dc.lab configsync-ip $ha unicast-address { { ip $ha } { ip $(v MGMT $u) } } mirror-ip any6all" >/dev/null 2>&1; done
  pw=$(sed -n 's/^PASSWORD=//p' $SEC/$Bu.env)
  tm $A "list cm trust-domain Root" | grep -q "$Bu.dc.lab" || \
    tm $A "modify cm trust-domain Root ca-devices add { 192.168.255.2 } name $Bu.dc.lab username admin password $pw" >/dev/null 2>&1
  sleep 10
  tm $A "create cm device-group dg-lb-f5 devices add { $A.dc.lab $Bu.dc.lab } type sync-failover auto-sync enabled network-failover enabled asm-sync enabled" >/dev/null 2>&1
  tm $A "run cm config-sync to-group dg-lb-f5" >/dev/null; sleep 15
  for cl in $TENANTS $PARENT; do local rd=$(v RD $cl)   # floating self IPs (SNAT automap source), traffic-group-1 with the VIPs
    tm $A "create net self $cl-to-leaf6a-floating address $NET_1.5%$rd/29 vlan $cl-to-leaf6a allow-service none traffic-group traffic-group-1" >/dev/null 2>&1
    tm $A "create net self $cl-to-leaf6b-floating address $NET_2.5%$rd/29 vlan $cl-to-leaf6b allow-service none traffic-group traffic-group-1" >/dev/null 2>&1
  done
  tm $A "save sys config" >/dev/null
  for i in $(seq 1 24); do   # P-6: the internal datasync group can stay "Changes Pending" after the pair forms: sync it from the unit that has it
    for u in "${U[@]}"; do tm $u "show cm sync-status" | grep -q "datasync-global-dg (Changes Pending)" && tm $u "run cm config-sync to-group datasync-global-dg" >/dev/null; done
    [ "$(for u in "${U[@]}"; do tm $u 'show cm sync-status' | awk '/^Status/ {print $2,$3}'; done | sort -u)" = "In Sync" ] && break; sleep 5; done
  for u in "${U[@]}"; do say "$u: $(tm $u 'show cm failover-status' | awk '/^Status/ {print $2}') | $(tm $u 'show cm sync-status' | awk '/^Status/ {print $2,$3}')"; done; }

base() { local u; for u in "${U[@]}"; do provision $u && network $u && bgp $u || return 1; done; ha; }

active() { local u; for u in "${U[@]}"; do tm $u "show cm failover-status" 2>/dev/null | grep -qE "^Status +ACTIVE" && { echo $u; return; }; done; }

tls() {   # one lab CA, a wildcard certificate per cluster; installed on the active unit (config sync carries it)
  local d=$SEC/tls a cl; a=$(active); [ -n "$a" ] || { say "no active unit"; return 1; }
  install -d -m 700 $d
  # keyUsage is required: Python 3.13 clients (LiteLLM) verify strictly and refuse a CA without it ("CA cert does not include key usage
  # extension")
  [ -s $d/ca.crt ] || openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 365 -subj "/CN=sonic-clos-dc lab CA" \
                        -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" -keyout $d/ca.key -out $d/ca.crt 2>/dev/null
  for cl in prod dev; do
    # (re)issued when missing or when its name is not *.<tenant>.dc.lab: a pair for *.apps.<cl>.dc.lab gives every user a name
    # mismatch; the old pair is kept as apps-<t>.*.<date>
    if [ -s $d/apps-$cl.crt ] && ! openssl x509 -in $d/apps-$cl.crt -noout -ext subjectAltName 2>/dev/null | grep -qx " *DNS:\*\.$cl\.dc\.lab"; then
      for f in crt key csr ext; do mv $d/apps-$cl.$f $d/apps-$cl.$f.$(date +%Y%m%d) 2>/dev/null; done; fi
    if [ ! -s $d/apps-$cl.crt ]; then
      openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -subj "/CN=*.$cl.dc.lab" -keyout $d/apps-$cl.key -out $d/apps-$cl.csr 2>/dev/null
      printf 'subjectAltName=DNS:*.%s.dc.lab\nextendedKeyUsage=serverAuth\n' $cl > $d/apps-$cl.ext
      openssl x509 -req -in $d/apps-$cl.csr -CA $d/ca.crt -CAkey $d/ca.key -CAcreateserial -days 365 -extfile $d/apps-$cl.ext -out $d/apps-$cl.crt 2>/dev/null
    fi
    chmod 600 $d/*
    B $a UPLOAD $d/apps-$cl.crt apps-$cl.crt >/dev/null; B $a UPLOAD $d/apps-$cl.key apps-$cl.key >/dev/null
    # install creates a pair but never replaces one (it fails silently and the VIP keeps serving the old certificate), and tmsh
    # batch mode has no transactions: a changed certificate is installed under a NEW name (apps-<t>-<time>) and the client-ssl profile is
    # switched to it in one modify (rotation); the profile's cert is compared with the local one by SHA-256 fingerprint
    local fp cur n; fp=$(openssl x509 -in $d/apps-$cl.crt -noout -fingerprint -sha256 | sed 's/.*=//')
    cur=$(BR $a "tmsh list ltm profile client-ssl clientssl-$cl-apps cert-key-chain 2>/dev/null" | awk '$1 == "cert" {print $2; exit}')
    if [ -z "$cur" ]; then n=apps-$cl
    elif BR $a "tmsh list sys file ssl-cert $cur fingerprint" | grep -qi "SHA256/$fp"; then n=""
    else n=apps-$cl-$(date +%Y%m%d%H%M); fi
    if [ -n "$n" ]; then
      tm $a "install sys crypto key $n from-local-file /var/config/rest/downloads/apps-$cl.key" >/dev/null
      tm $a "install sys crypto cert $n from-local-file /var/config/rest/downloads/apps-$cl.crt" >/dev/null
      [ -z "$cur" ] || { tm $a "modify ltm profile client-ssl clientssl-$cl-apps cert-key-chain replace-all-with { apps-$cl { cert $n key $n } }" >/dev/null; say "$a: clientssl-$cl-apps rotated $cur > $n"; }
    fi
    BR $a "rm -f /var/config/rest/downloads/apps-$cl.key" >/dev/null
    # the existence test runs ON the BIG-IP (BR's own exit code is the REST call's, always 0)
    BR $a "tmsh list ltm profile client-ssl clientssl-$cl-apps >/dev/null 2>&1 || tmsh create ltm profile client-ssl clientssl-$cl-apps defaults-from clientssl cert-key-chain replace-all-with { apps-$cl { cert apps-$cl key apps-$cl } } cipher-group f5-secure ciphers none options { dont-insert-empty-fragments no-tlsv1 no-tlsv1.1 }" >/dev/null
    BR $a "tmsh list ltm profile server-ssl serverssl-$cl-apps >/dev/null 2>&1 || tmsh create ltm profile server-ssl serverssl-$cl-apps defaults-from serverssl" >/dev/null
    say "$a: *.$cl.dc.lab (lab CA), clientssl-$cl-apps, serverssl-$cl-apps"
  done; }

apps() {   # per tenant one VS on the apps VIP in its route domain (lab-CA certificate *.<t>.dc.lab, WAF); an iRule picks the pool by Host;
           # each pool = the app's MetalLB address in the tenant VRF (10.x0.1.200-.204); server-side TLS only for Harbor (it serves HTTPS itself)
  local a cl rd p app ip port mon r; a=$(active); [ -n "$a" ] || { say "no active unit"; return 1; }
  for cl in $TENANTS; do rd=$(v RD $cl); p=$([ $cl = prod ] && echo 10.10 || echo 10.20)
    tm $a "create ltm monitor http mon-$cl-whoami defaults-from http interval 5 timeout 16 send \"GET / HTTP/1.1\\\\r\\\\nHost: whoami.$cl.dc.lab\\\\r\\\\nConnection: close\\\\r\\\\n\\\\r\\\\n\" recv \"tenant $cl\"" >/dev/null 2>&1
    for app in whoami:200:8080 chat:201:8080 inference:202:80 harbor:203:443 minio:204:9001; do IFS=: read -r n o port <<<"$app"; ip=$p.1.$o
      mon=tcp; [ $n = whoami ] && mon=mon-$cl-whoami
      tm $a "create ltm pool pool-$cl-$n monitor $mon members add { $ip%$rd:$port { address $ip%$rd } }" >/dev/null 2>&1
    done
    r="when HTTP_REQUEST {\n  switch -glob [string tolower [HTTP::host]] {\n"
    for n in whoami chat inference harbor minio; do r+="    \"$n.$cl.dc.lab*\" { pool pool-$cl-$n }\n"; done
    r+="    default { HTTP::respond 404 content \"unknown application\" }\n  }\n}\nwhen SERVER_CONNECTED {\n  if { [LB::server pool] ne \"/Common/pool-$cl-harbor\" } { SSL::disable serverside }\n}"
    B $a GET /mgmt/tm/ltm/rule/~Common~rule-$cl-apps >/dev/null 2>&1 && B $a DELETE /mgmt/tm/ltm/rule/~Common~rule-$cl-apps >/dev/null 2>&1
    B $a POST /mgmt/tm/ltm/rule "$(python3 -c 'import json,sys; print(json.dumps({"name": sys.argv[1], "apiAnonymous": sys.argv[2].replace("\\n", "\n")}))' rule-$cl-apps "$r")" >/dev/null
    tm $a "create ltm virtual-address $VIP%$rd address $VIP%$rd route-advertisement any icmp-echo enabled arp enabled traffic-group traffic-group-1" >/dev/null 2>&1
    tm $a "delete ltm virtual vs-$cl-apps" >/dev/null 2>&1
    tm $a "create ltm virtual vs-$cl-apps destination $VIP%$rd:443 ip-protocol tcp profiles add { http tcp { context all } clientssl-$cl-apps { context clientside } serverssl-$cl-apps { context serverside } } source-address-translation { type automap } rules { rule-$cl-apps }" >/dev/null 2>&1
    say "$a: vs-$cl-apps $VIP%$rd:443 > $(for n in whoami chat inference harbor minio; do echo -n "$n=$(tm $a "show ltm pool pool-$cl-$n field-fmt" | awk '/status.availability-state/ {print $2}' | head -1) "; done)"
  done
  tm $a "save sys config" >/dev/null; }

model() {   # the model API for both tenants through the parent route domain rd-ocp
  local a d=$SEC/tls cl rd g; a=$(active); [ -n "$a" ] || { say "no active unit"; return 1; }; g=$(v RD $PARENT)
  [ -s $d/ca.crt ] || { say "no lab CA: run ./f5.sh tls first"; return 1; }
  if [ ! -s $d/model.crt ]; then
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -subj "/CN=model.dc.lab" -keyout $d/model.key -out $d/model.csr 2>/dev/null
    printf 'subjectAltName=DNS:model.dc.lab\nextendedKeyUsage=serverAuth\n' > $d/model.ext
    openssl x509 -req -in $d/model.csr -CA $d/ca.crt -CAkey $d/ca.key -CAcreateserial -days 365 -extfile $d/model.ext -out $d/model.crt 2>/dev/null
  fi; chmod 600 $d/*
  B $a UPLOAD $d/model.crt model.crt >/dev/null; B $a UPLOAD $d/model.key model.key >/dev/null
  tm $a "install sys crypto key model from-local-file /var/config/rest/downloads/model.key" >/dev/null 2>&1
  tm $a "install sys crypto cert model from-local-file /var/config/rest/downloads/model.crt" >/dev/null 2>&1
  BR $a "rm -f /var/config/rest/downloads/model.key" >/dev/null
  BR $a "tmsh list ltm profile client-ssl clientssl-model >/dev/null 2>&1 || tmsh create ltm profile client-ssl clientssl-model defaults-from clientssl cert-key-chain replace-all-with { model { cert model key model } } cipher-group f5-secure ciphers none options { dont-insert-empty-fragments no-tlsv1 no-tlsv1.1 }" >/dev/null
  BR $a "tmsh list ltm profile server-ssl serverssl-model >/dev/null 2>&1 || tmsh create ltm profile server-ssl serverssl-model defaults-from serverssl" >/dev/null
  # the default router picks the route by Host: every request leaves with Host $MODEL_HOST (iRule through REST: tmsh quoting)
  B $a GET /mgmt/tm/ltm/rule/~Common~rule-model-host >/dev/null 2>&1 || \
    B $a POST /mgmt/tm/ltm/rule '{"name":"rule-model-host","apiAnonymous":"when HTTP_REQUEST {\n  HTTP::header replace Host '$MODEL_HOST'\n}"}' >/dev/null
  tm $a "create ltm monitor https mon-ocp-llm defaults-from https interval 5 timeout 16 send \"GET /health HTTP/1.1\\\\r\\\\nHost: $MODEL_HOST\\\\r\\\\nConnection: close\\\\r\\\\n\\\\r\\\\n\" recv \"ok\"" >/dev/null 2>&1
  tm $a "create ltm pool pool-ocp-llm monitor mon-ocp-llm members add { $MODEL_POOL%$g:443 { address $MODEL_POOL%$g } }" >/dev/null 2>&1
  for cl in prod dev; do rd=$(v RD $cl)
    tm $a "create ltm virtual-address $MODEL_VIP%$rd address $MODEL_VIP%$rd route-advertisement any icmp-echo enabled arp enabled traffic-group traffic-group-1" >/dev/null 2>&1
    tm $a "create ltm virtual vs-$cl-model destination $MODEL_VIP%$rd:443 ip-protocol tcp profiles add { http tcp { context all } clientssl-model { context clientside } serverssl-model { context serverside } } source-address-translation { type automap } rules { rule-model-host } pool pool-ocp-llm" >/dev/null 2>&1
    say "$a: vs-$cl-model $MODEL_VIP%$rd:443 > pool-ocp-llm ($MODEL_POOL%$g): $(tm $a "show ltm pool pool-ocp-llm field-fmt" | awk '/status.availability-state/ {print $2}' | head -1)"
  done
  tm $a "save sys config" >/dev/null; }

waf_tune() {   # <unit> <policy id>. Allow 403 (MinIO: not logged in; its console stayed blank), 429 (rate limits) and 502 / 504 (gateway answers; 500 stays blocked) so a tenant sees the app.s answer,
  # not a block page (VIOL_HTTP_RESPONSE_STATUS); mask the headers that carry tenant keys in the event log.
  local a=$1 pid=$2 h id
  B $a PATCH /mgmt/tm/asm/policies/$pid/general '{"allowedResponseCodes":[400,401,403,404,407,417,429,502,503,504]}' >/dev/null
  for h in authorization apikey x-api-key; do
    id=$(B $a GET "/mgmt/tm/asm/policies/$pid/headers?\$filter=name+eq+'$h'&\$select=id" | python3 -c "import json,sys; i=json.load(sys.stdin).get('items',[]); print(i[0]['id'] if i else '')")
    if [ -n "$id" ]; then B $a PATCH /mgmt/tm/asm/policies/$pid/headers/$id '{"maskValueInLogs":true}' >/dev/null
    else B $a POST /mgmt/tm/asm/policies/$pid/headers '{"name":"'$h'","type":"explicit","maskValueInLogs":true,"checkSignatures":true}' >/dev/null; fi
  done; }

wafupdate() {   # the WAF tuning on the running policies: tune both tenants' policies on the active unit, apply, save (config sync carries it to the standby)
  local a pid cl task st i; a=$(active); [ -n "$a" ] || { say "no active unit"; return 1; }
  j() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
  for cl in prod dev; do
    pid=$(B $a GET "/mgmt/tm/asm/policies?\$filter=fullPath+eq+'/Common/waf-$cl-apps'&\$select=id" | j 'd["items"][0]["id"]')
    waf_tune $a $pid
    task=$(B $a POST /mgmt/tm/asm/tasks/apply-policy '{"policyReference":{"link":"https://localhost/mgmt/tm/asm/policies/'$pid'"}}' | j 'd["id"]')
    for i in $(seq 1 60); do st=$(B $a GET /mgmt/tm/asm/tasks/apply-policy/$task | j 'd["status"]'); [ "$st" = COMPLETED -o "$st" = FAILURE ] && break; sleep 5; done
    say "$a: waf-$cl-apps tuned (429 allowed, key headers masked), apply $st"
  done
  tm $a "save sys config" >/dev/null; }

waf() {   # one Advanced WAF policy per tenant (the attack signature sets added, signatures AND wildcard parameters / URLs unstaged)
  local a cl pol body task st pid i; a=$(active); [ -n "$a" ] || { say "no active unit"; return 1; }
  j() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
  for cl in prod dev; do
    pol='{"policy":{"name":"waf-'$cl'-apps","template":{"name":"POLICY_TEMPLATE_FUNDAMENTAL"},"applicationLanguage":"utf-8","enforcementMode":"blocking","signature-settings":{"signatureStaging":false},"signature-sets":[{"name":"Generic Detection Signatures (High/Medium Accuracy)","block":true,"alarm":true},{"name":"SQL Injection Signatures","block":true,"alarm":true},{"name":"Cross Site Scripting Signatures","block":true,"alarm":true},{"name":"OS Command Injection Signatures","block":true,"alarm":true},{"name":"Path Traversal Signatures","block":true,"alarm":true}]}}'
    body=$(python3 -c 'import json,sys; print(json.dumps({"file": sys.argv[1], "isBase64": False, "policy": {"fullPath": "/Common/waf-"+sys.argv[2]+"-apps"}}))' "$pol" $cl)
    task=$(B $a POST /mgmt/tm/asm/tasks/import-policy "$body" | j 'd["id"]')
    for i in $(seq 1 60); do st=$(B $a GET /mgmt/tm/asm/tasks/import-policy/$task | j 'd["status"]'); [ "$st" = COMPLETED -o "$st" = FAILURE ] && break; sleep 5; done
    pid=$(B $a GET "/mgmt/tm/asm/policies?\$filter=fullPath+eq+'/Common/waf-$cl-apps'&\$select=id" | j 'd["items"][0]["id"]')
    B $a PATCH /mgmt/tm/asm/policies/$pid '{"virtualServers":["/Common/vs-'$cl'-apps"]}' >/dev/null
    # the built-in "Log illegal requests" profile: without one the policy blocks without a trace
    tm $a "modify ltm virtual vs-$cl-apps security-log-profiles replace-all-with { \\\"Log illegal requests\\\" }" >/dev/null
    for e in signatures parameters urls; do B $a PATCH "/mgmt/tm/asm/policies/$pid/$e?\$filter=performStaging+eq+true" '{"performStaging":false}' >/dev/null; done
    waf_tune $a $pid
    task=$(B $a POST /mgmt/tm/asm/tasks/apply-policy '{"policyReference":{"link":"https://localhost/mgmt/tm/asm/policies/'$pid'"}}' | j 'd["id"]')
    for i in $(seq 1 60); do st=$(B $a GET /mgmt/tm/asm/tasks/apply-policy/$task | j 'd["status"]'); [ "$st" = COMPLETED -o "$st" = FAILURE ] && break; sleep 5; done
    say "$a: waf-$cl-apps on vs-$cl-apps, apply $st"
  done
  tm $a "save sys config" >/dev/null; }

case ${1:-} in
  secrets|licence|status|revoke|base|ha|tls|apps|model|waf|wafupdate)
    for s in "$@"; do case $s in secrets|licence|status|revoke|base|ha|tls|apps|model|waf|wafupdate) $s || { say "f5.sh $s failed"; exit 1; } ;; *) echo "$0: $s cannot follow another step"; exit 2 ;; esac; done ;;
  provision|network|bgp) s=$1; shift; for u in ${@:-${U[@]}}; do $s $u; done ;;
  *) echo "usage: $0 secrets|licence|status|revoke|base|ha|tls|apps|model|waf|wafupdate | provision|network|bgp [unit]"; exit 2 ;;
esac
