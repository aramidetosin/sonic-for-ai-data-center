#!/bin/bash
# validate-fabric.sh [fabric|firewall|all]: the fabric and the firewall (PA-VM + Vrf-Svc services) checks of sonic-clos-dc, one
# PASS/FAIL line each -> results/<lab>_fabric-<part>_<ts>/result.txt (commands.txt: every command run).
cd "$(dirname "$0")"; . ./lib.sh
PART=${1:-all}; P=0; F=0; RD=$(resdir fabric-$PART); OUT=$RD/result.txt; CMDLOG=$PWD/$RD/commands.txt; : > $OUT; : > $CMDLOG
log() { echo "$*" | tee -a $OUT; }
ok() { if [ "$2" = 0 ]; then log "PASS  $1"; P=$((P+1)); else log "FAIL  $1  ($3)"; F=$((F+1)); fi; }
want() { local got; [ -n "${CMDLOG:-}" ] && printf '$ %s\n' "$2" | redact >> "$CMDLOG"; got=$(eval "$2" 2>&1); echo "$got" | grep -q -E "$3"; ok "$1" $? "got: $(echo $got | head -c 140)"; }
deny() { local got; [ -n "${CMDLOG:-}" ] && printf '$ %s\n' "$2" | redact >> "$CMDLOG"; got=$(eval "$2" 2>&1); if echo "$got" | grep -q -E "$3"; then ok "$1" 1 "reached: $(echo $got | head -c 90)"; else ok "$1" 0; fi; }
SPINES="spine1 spine2 spine3 spine4"; LEAVES="leaf1a-control leaf1b-control leaf2a-control leaf2b-control leaf3a-compute leaf3b-compute leaf4a-compute leaf4b-compute leaf5a-storage leaf5b-storage leaf6a-border leaf6b-border"

if [ $PART = fabric ] || [ $PART = all ]; then
log "== fabric"
for s in $SPINES; do want "$s: 12 underlay sessions up" "KL $s 'show bgp ipv4 unicast summary'" "established 12"; done
for l in $LEAVES; do want "$l: 4 underlay sessions up" "KL $l 'show bgp ipv4 unicast summary'" "established 4"; done
# every PortChannel whose LACP partner is up must see its ES on the partner leaf (type L R); down ones are listed, not failed
# (the OpenShift node bonds stay down until ocp-install.sh releases the guests)
es_check() { local l=$1 up es miss=""; up=$(KL $l "show interface PortChannel" | awk '/line protocol is up/{print $1}')
  es=$(KL $l "show evpn es" | awk '$2 ~ /R/ {print $3}')
  for p in $up; do echo "$es" | grep -qx "$p" || miss="$miss $p"; done
  echo "up=$(echo $up | wc -w) missing-partner=[${miss# }] down=[$(KL $l "show interface PortChannel" | awk '/line protocol is down/{printf "%s ", $1}')]"; }
for l in $LEAVES; do want "$l: every up PortChannel has its ES partner" "es_check $l" "missing-partner=\[\]"; done
# probes in the tenant VRFs, bastion-ocp in Vrf-Ocp; the probes' gateways answer from their rack pair
want "leaf3a-compute reaches probe-prod 10.10.2.10 in Vrf-Prod" "SW leaf3a-compute 'ping -c2 -W1 -I Vrf-Prod 10.10.2.10'" " 0% packet loss"
want "leaf4a-compute reaches probe-dev 10.20.2.10 in Vrf-Dev" "SW leaf4a-compute 'ping -c2 -W1 -I Vrf-Dev 10.20.2.10'" " 0% packet loss"
want "bastion-ocp reaches the Vrf-Mgmt anycast gateway on eth3" "X bastion-ocp 'ping -c2 -W1 -I eth3 172.16.0.1'" " 0% packet loss"
want "bastion-ocp reaches its Vrf-Ocp gateway 10.0.4.1" "X bastion-ocp 'ping -c2 -W1 10.0.4.1'" " 0% packet loss"
deny "probe-prod cannot reach Vrf-Mgmt" "X probe-prod 'ping -c2 -W1 172.16.0.10'" " [12] received"
want "jumbo 8972 DF across the fabric: leaf1a-control -> leaf6b-border Vrf-Mgmt loopback over VXLAN (tenant VLANs are down until their nodes boot)" "SW leaf1a-control 'ping -c2 -W1 -M do -s 8972 -I Vrf-Mgmt 172.16.255.32'" " 0% packet loss"
want "in-band management: leaf1a-control reaches leaf6b-border's Vrf-Mgmt loopback" "SW leaf1a-control 'ping -c2 -W1 -I Vrf-Mgmt 172.16.255.32'" " 0% packet loss"
fi

if [ $PART = firewall ] || [ $PART = all ]; then
log "== firewall: PA-VM + Vrf-Svc"
for vn in Vrf-Prod:1 Vrf-Dev:1 Vrf-Mgmt:1 Vrf-Svc:3 Vrf-Ocp:1; do v=${vn%:*}; n=${vn#*:}   # transits per border VRF (gen.py TRANSITS)
  want "leaf6a-border $v: $n eBGP session(s) to the PA up" "KL leaf6a-border 'show bgp ipv4 unicast vrf $v summary' | grep -c '^10.254.* 65500 .* [0-9][0-9]* *$'" "^$n$"
done
for h in bastion-ocp probe-prod probe-dev; do want "$h DNS internal (dns-ntp1)" "X $h 'dig +short +time=2 +tries=2 api.ocp.dc.lab @10.250.0.11'" "^10\.0\.1\.5$"; done
want "dns-ntp2 serves the zone (transfer)" "X probe-dev 'dig +short +time=2 +tries=2 netapp-01.mgmt.dc.lab @10.250.0.12'" "^172\.16\.0\.41$"
for h in probe-prod probe-dev; do want "$h DNS external via dns-ntp1" "X $h 'dig +short +time=3 +tries=2 quay.io @10.250.0.11'" "^[0-9]+\."; done
for h in probe-prod probe-dev; do want "$h NTP from dns-ntp1" "X $h 'chronyd -Q -t 8 \"server 10.250.0.11 iburst\"'" "System clock wrong"; done
for h in bastion-ocp probe-prod probe-dev; do want "$h Internet https" "X $h 'curl -s -o /dev/null -w %{http_code} -m 10 https://quay.io/v2/'" "^(200|401)$"; done
deny "prod cannot reach dev (probe-prod > probe-dev 10.20.2.10)" "X probe-prod 'ping -c2 -W1 10.20.2.10'" " [12] received"
deny "dev cannot reach prod (probe-dev > probe-prod 10.10.2.10)" "X probe-dev 'ping -c2 -W1 10.10.2.10'" " [12] received"
deny "prod cannot reach the cluster (probe-prod > API 10.0.1.5)" "X probe-prod 'ping -c2 -W1 10.0.1.5'" " [12] received"
deny "prod cannot reach the dev transit" "X probe-prod 'ping -c2 -W1 10.254.2.3'" " [12] received"
deny "prod cannot reach dns-ntp1 on tcp/80" "X probe-prod 'curl -s -m 4 http://10.250.0.11/'" "dns-ntp1 "
deny "Vrf-Mgmt has no Internet (bastion eth3 source)" "X bastion-ocp 'curl -s -o /dev/null -w %{http_code} -m 5 --interface eth3 http://1.1.1.1/'" "^[1-5][0-9][0-9]$"
fi

log ""; log "RESULT: $P passed, $F failed ($RD)"
[ $F = 0 ]
