#!/bin/bash
# validate-fabric.sh [fabric|firewall|all]: the fabric and the firewall (PA-VM + Vrf-Svc services) checks of sonic-clos-dc, one
# PASS/FAIL line each -> results/<lab>_fabric-<part>_<ts>/result.txt (commands.txt: every command run).
# prod and dev on the SAME addresses (10.0.1.0/24 nodes, 10.0.2.0/24 probe + bastion, 10.0.3.0/24 storage)
# in Vrf-Prod / Vrf-Dev; the gpu cluster in Vrf-Ocp (10.0.8.0/24, storage 10.0.9.0/24); MetalLB peers from the rack leaves' tenant loopbacks.
cd "$(dirname "$0")"; . ./lib.sh
PART=${1:-all}; P=0; F=0; RD=$(resdir fabric-$PART); OUT=$RD/result.txt; CMDLOG=$PWD/$RD/commands.txt; : > $OUT; : > $CMDLOG
log() { echo "$*" | tee -a $OUT; }
ok() { if [ "$2" = 0 ]; then log "PASS  $1"; P=$((P+1)); else log "FAIL  $1  ($3)"; F=$((F+1)); fi; }
want() { local got; [ -n "${CMDLOG:-}" ] && printf '$ %s\n' "$2" | redact >> "$CMDLOG"; got=$(eval "$2" 2>&1); echo "$got" | grep -q -E "$3"; ok "$1" $? "got: $(echo $got | head -c 140)"; }
deny() { local got; [ -n "${CMDLOG:-}" ] && printf '$ %s\n' "$2" | redact >> "$CMDLOG"; got=$(eval "$2" 2>&1); if echo "$got" | grep -q -E "$3"; then ok "$1" 1 "reached: $(echo $got | head -c 90)"; else ok "$1" 0; fi; }
SPINES="spine1 spine2 spine3 spine4"; LEAVES="leaf1a-control leaf1b-control leaf2a-control leaf2b-control leaf3a-compute leaf3b-compute leaf4a-compute leaf4b-compute leaf5a-storage leaf5b-storage leaf6a-border leaf6b-border"
declare -A VRF=([prod]=Vrf-Prod [dev]=Vrf-Dev) RACKA=([prod]=leaf3a-compute [dev]=leaf4a-compute) RACKB=([prod]=leaf3b-compute [dev]=leaf4b-compute)

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
# the VRFs each pair carries now (racks 1/2 lost Vrf-Prod / Vrf-Dev with the retired VLANs 111 / 211)
vrfs() { KL $1 "show ip vrf" | awk '$1 ~ /^Vrf-/ {print $1}' | sort | xargs; }
for l in leaf1a-control leaf2b-control; do want "$l: VRFs Vrf-Mgmt + Vrf-Ocp only (the tenant VRFs left racks 1/2)" "vrfs $l" "^Vrf-Mgmt Vrf-Ocp$"; done
want "leaf3a-compute: Vrf-Mgmt, Vrf-Ocp, Vrf-Prod (no Vrf-Dev on prod's rack)" "vrfs leaf3a-compute" "^Vrf-Mgmt Vrf-Ocp Vrf-Prod$"
want "leaf4a-compute: Vrf-Dev, Vrf-Mgmt, Vrf-Ocp (no Vrf-Prod on dev's rack)" "vrfs leaf4a-compute" "^Vrf-Dev Vrf-Mgmt Vrf-Ocp$"
want "leaf5a-storage: Vrf-Dev, Vrf-Mgmt, Vrf-Ocp, Vrf-Prod (the three storage VLANs 103 / 203 / 109)" "vrfs leaf5a-storage" "^Vrf-Dev Vrf-Mgmt Vrf-Ocp Vrf-Prod$"
deny "no retired VLAN left on any leaf (100, 104, 106, 107, 111-113, 211-213)" "for l in $LEAVES; do KL \$l 'show vlan' | awk '\$1 ~ /^(100|104|106|107|111|112|113|211|212|213)\$/ {print l\":\"\$1}' l=\$l; done" "."
# the same subnet and the same gateway in two VRFs on the same leaf pair would be fine; here the pairs differ, the addresses do not
want "leaf3a-compute Vlan101 and leaf4a-compute Vlan201 both carry 10.0.1.1 (the same gateway in Vrf-Prod and Vrf-Dev)" "{ KL leaf3a-compute 'show ip static-anycast-gateway' | grep -E '^Vlan101 '; KL leaf4a-compute 'show ip static-anycast-gateway' | grep -E '^Vlan201 '; } | grep -c '10\.0\.1\.1/24'" "^2$"
for t in prod dev; do
  want "${RACKA[$t]} reaches probe-$t 10.0.2.10 in ${VRF[$t]}" "SW ${RACKA[$t]} 'ping -c2 -W1 -I ${VRF[$t]} 10.0.2.10'" " 0% packet loss"
  want "${RACKA[$t]} reaches bastion-$t 10.0.2.11 in ${VRF[$t]}" "SW ${RACKA[$t]} 'ping -c2 -W1 -I ${VRF[$t]} 10.0.2.11'" " 0% packet loss"
done
want "bastion-gpu reaches the Vrf-Mgmt anycast gateway on eth3" "X bastion-gpu 'ping -c2 -W1 -I eth3 172.16.0.1'" " 0% packet loss"
want "bastion-gpu reaches its Vrf-Ocp gateway 10.0.8.1" "X bastion-gpu 'ping -c2 -W1 10.0.8.1'" " 0% packet loss"
deny "probe-prod cannot reach Vrf-Mgmt" "X probe-prod 'ping -c2 -W1 172.16.0.10'" " [12] received"
# MetalLB's eBGP multihop sessions from each rack leaf's tenant loopback (Loopback 11) to the 3 nodes of its cluster
for t in prod dev; do for l in ${RACKA[$t]} ${RACKB[$t]}; do
  want "$l ${VRF[$t]}: 3 MetalLB sessions (AS 65030, nodes 10.0.1.21-.23) established from its loopback" "KL $l 'show bgp ipv4 unicast vrf ${VRF[$t]} summary' | grep -cE '^10\.0\.1\.2[1-3] .* 65030 .* [0-9]+ *$'" "^3$"
  # every app address (whoami, chat, inference, harbor, minio) is advertised by all 3 nodes, so no announcement moves when a pod goes
  want "$l ${VRF[$t]}: the 5 app addresses 10.0.1.200-.204 each via the 3 nodes (Cluster)" "for a in 200 201 202 203 204; do SW $l \"vtysh -c 'show ip route vrf ${VRF[$t]} 10.0.1.\$a/32'\" | grep -oE '^ +\\* 10\\.0\\.1\\.2[1-3],' | sort -u | wc -l; done | paste -sd' '" "^3 3 3 3 3$"
done; done
want "jumbo 8972 DF across the fabric: leaf1a-control -> leaf6b-border Vrf-Mgmt loopback over VXLAN" "SW leaf1a-control 'ping -c2 -W1 -M do -s 8972 -I Vrf-Mgmt 172.16.255.32'" " 0% packet loss"
for t in prod dev; do want "jumbo 8972 DF in ${VRF[$t]}: ${RACKA[$t]} -> svm-$t's NFS LIF 10.0.3.253 over VXLAN to the storage pair" "SW ${RACKA[$t]} 'ping -c2 -W1 -M do -s 8972 -I ${VRF[$t]} 10.0.3.253'" " 0% packet loss"; done
want "in-band management: leaf1a-control reaches leaf6b-border's Vrf-Mgmt loopback" "SW leaf1a-control 'ping -c2 -W1 -I Vrf-Mgmt 172.16.255.32'" " 0% packet loss"
fi

if [ $PART = firewall ] || [ $PART = all ]; then
log "== firewall: PA-VM + Vrf-Svc"
for vn in Vrf-Prod:1 Vrf-Dev:1 Vrf-Mgmt:1 Vrf-Svc:3 Vrf-Ocp:1; do v=${vn%:*}; n=${vn#*:}   # transits per border VRF (gen.py TRANSITS)
  want "leaf6a-border $v: $n eBGP session(s) to the PA up" "KL leaf6a-border 'show bgp ipv4 unicast vrf $v summary' | grep -c '^10.254.* 65500 .* [0-9][0-9]* *$'" "^$n$"
done
want "zone answers per cluster: api.prod / api.dev = 10.0.1.5 (the same address), api.gpu = 10.0.8.5" "for c in prod dev gpu; do X probe-prod \"dig +short +time=2 +tries=2 api.\$c.dc.lab @10.250.0.11\"; done | paste -sd' '" "^10\.0\.1\.5 10\.0\.1\.5 10\.0\.8\.5$"
for h in bastion-gpu probe-prod probe-dev bastion-prod bastion-dev; do want "$h DNS internal (dns-ntp1)" "X $h 'dig +short +time=2 +tries=2 model.dc.lab @10.250.0.11'" "^10\.0\.5\.11$"; done
want "dns-ntp2 serves the zone (transfer)" "X probe-dev 'dig +short +time=2 +tries=2 netapp-01.mgmt.dc.lab @10.250.0.12'" "^172\.16\.0\.41$"
for h in probe-prod probe-dev; do want "$h DNS external via dns-ntp1" "X $h 'dig +short +time=3 +tries=2 quay.io @10.250.0.11'" "^[0-9]+\."; done
for h in probe-prod probe-dev; do want "$h NTP from dns-ntp1" "X $h 'chronyd -Q -t 8 \"server 10.250.0.11 iburst\"'" "System clock wrong"; done
# tenant egress (registry pulls) through the tenant's own virtual router, the platform's through vr-shared
for h in bastion-gpu probe-prod probe-dev bastion-prod bastion-dev; do want "$h Internet https" "X $h 'curl -s -o /dev/null -w %{http_code} -m 10 https://quay.io/v2/'" "^(200|401)$"; done
log "-- hard tenancy on the fabric: the same addresses, never the same network"
# probe-prod and probe-dev both are 10.0.2.10; each sees its OWN tenant's 10.0.2.11 (the bastion) and nothing of the other
for t in prod dev; do
  want "probe-$t: 10.0.2.11 answers with bastion-$t's own MAC (the same address in the other tenant is another host)" "X probe-$t 'ping -c1 -W1 10.0.2.11 >/dev/null; ip neigh show 10.0.2.11' | grep -oi \"\$(docker exec $C-bastion-$t cat /sys/class/net/eth1/address)\"" "^[0-9a-f:]{17}$"
done
deny "prod cannot reach the dev transit" "X probe-prod 'ping -c2 -W1 10.254.2.3'" " [12] received"
deny "dev cannot reach the prod transit" "X probe-dev 'ping -c2 -W1 10.254.1.3'" " [12] received"
deny "prod cannot reach the gpu node network (10.0.8.5 API, 10.0.8.7 ingress, 10.0.8.21 a GPU worker): only the BIG-IP model VIP leads there" "X probe-prod 'for a in 10.0.8.5 10.0.8.7 10.0.8.21; do ping -c1 -W1 \$a; done'" " 1 received"
deny "dev cannot reach the gpu node network" "X probe-dev 'for a in 10.0.8.5 10.0.8.7 10.0.8.21; do ping -c1 -W1 \$a; done'" " 1 received"
deny "prod cannot reach svm-gpu (10.0.9.250-.254)" "X probe-prod 'for a in 10.0.9.250 10.0.9.251 10.0.9.253; do ping -c1 -W1 \$a; done'" " 1 received"
deny "the gpu cluster's bastion cannot reach a tenant node network (10.0.1.21 lives only in Vrf-Prod / Vrf-Dev)" "X bastion-gpu 'ping -c2 -W1 10.0.1.21'" " [12] received"
deny "prod cannot reach dns-ntp1 on tcp/80" "X probe-prod 'curl -s -m 4 http://10.250.0.11/'" "dns-ntp1 "
deny "Vrf-Mgmt has no Internet (bastion-gpu eth3 source)" "X bastion-gpu 'curl -s -o /dev/null -w %{http_code} -m 5 --interface eth3 http://1.1.1.1/'" "^[1-5][0-9][0-9]$"
fi

log ""; log "RESULT: $P passed, $F failed ($RD)"
[ $F = 0 ]
