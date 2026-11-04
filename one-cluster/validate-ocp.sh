#!/bin/bash
# validate-ocp.sh: checks of cluster ocp (one cluster for both tenants), run through bastion-ocp (Vrf-Ocp): nodes and roles,
# the tenant and GPU placement (labels, taints, racks), the day-2 networking (NNCPs, tenant VRFs on every node), operators.
# One PASS/FAIL line each -> results/<lab>_ocp_<ts>/result.txt
cd "$(dirname "$0")"; . ./lib.sh
P=0; F=0; RD=$(resdir ocp); OUT=$RD/result.txt; CMDLOG=$PWD/$RD/commands.txt; : > $OUT; : > $CMDLOG; B=$C-bastion-ocp
log() { echo "$*" | tee -a $OUT; }
ok() { if [ "$2" = 0 ]; then log "PASS  $1"; P=$((P+1)); else log "FAIL  $1  ($3)"; F=$((F+1)); fi; }
want() { local got; [ -n "${CMDLOG:-}" ] && printf '$ %s\n' "$2" | redact >> "$CMDLOG"; got=$(eval "$2" 2>&1); echo "$got" | grep -q -E "$3"; ok "$1" $? "got: $(echo $got | head -c 160)"; }
deny() { local got; [ -n "${CMDLOG:-}" ] && printf '$ %s\n' "$2" | redact >> "$CMDLOG"; got=$(eval "$2" 2>&1); if echo "$got" | grep -q -E "$3"; then ok "$1" 1 "reached: $(echo $got | head -c 90)"; else ok "$1" 0; fi; }
OC() { docker exec $B oc "$@" 2>&1; }
SSHC() { ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8 core@"$(mip $1)" "$2" </dev/null 2>&1; }
log "== OpenShift ocp (ocp.dc.lab): 3 masters, 3 prod + 3 dev workers, 8 GPU workers"
want "17 nodes Ready" "OC get nodes --no-headers | awk '\$2==\"Ready\"' | wc -l" "^17$"
want "3 dedicated masters, 14 workers" "OC get nodes --no-headers | awk '{print \$3}' | sort | uniq -c | paste -sd' ' | tr -s ' '" "^ ?3 control-plane,master 14 worker$"
want "every node on 10.0.1.0/24: masters .11-.13, prod .21-.23, dev .31-.33, GPU .41-.48" "OC get nodes -o jsonpath='{range .items[*]}{.metadata.name}={.status.addresses[0].address}{\"\\n\"}{end}' | grep -cE '^(master[1-3]=10\.0\.1\.1[1-3]|prod-worker[1-3]=10\.0\.1\.2[1-3]|dev-worker[1-3]=10\.0\.1\.3[1-3]|gpu-worker[1-8]=10\.0\.1\.4[1-8])$'" "^17$"
want "clusterversion 4.22.12 Available, not Progressing" "OC get clusterversion --no-headers" "4\.22\.12 +True +False"
want "every cluster operator Available, none Degraded" "OC get co --no-headers | awk '\$3!=\"True\" || \$5!=\"False\"' | wc -l" "^0$"
want "network type OVNKubernetes, local gateway (routingViaHost)" "{ OC get network.config cluster -o jsonpath={.status.networkType}; echo; OC get network.operator cluster -o jsonpath={.spec.defaultNetwork.ovnKubernetesConfig.gatewayConfig.routingViaHost}; } | paste -sd' '" "^OVNKubernetes true$"
want "machine config pools master + worker Updated" "OC get mcp -o jsonpath='{range .items[*]}{.metadata.name}={.status.conditions[?(@.type==\"Updated\")].status}{\" \"}{end}'" "master=True.*worker=True"
want "the API answers on api.ocp.dc.lab (10.0.1.5) from the bastion" "docker exec $B curl -sk -o /dev/null -w %{http_code} https://api.ocp.dc.lab:6443/readyz" "^200$"
want "the console answers on the ingress VIP (10.0.1.7) from the bastion" "docker exec $B curl -sk -o /dev/null -w %{http_code} https://console-openshift-console.apps.ocp.dc.lab/" "^200$"
want "nodes use dns-ntp1/dns-ntp2 for NTP" "SSHC ocp-prod-worker1 'chronyc -n sources'" "10\.250\.0\.1[12]"
log "== placement: tenants, GPU workers, racks"
for t in prod dev; do
  want "$t workers tainted scd/tenant=$t:NoSchedule and labelled for it" "OC get nodes -l scd/tenant=$t -o jsonpath='{range .items[*]}{.metadata.name}:{.spec.taints[?(@.key==\"scd/tenant\")].value}/{.spec.taints[?(@.key==\"scd/tenant\")].effect} {end}'" "^$t-worker1:$t/NoSchedule $t-worker2:$t/NoSchedule $t-worker3:$t/NoSchedule $"
  want "every running pod of the $t namespaces sits on a $t worker" "{ OC get pod -A --field-selector=status.phase=Running --no-headers -o custom-columns=NS:.metadata.namespace,NODE:.spec.nodeName | awk '\$1 ~ /^$t-/ && \$2 !~ /^$t-worker/' | wc -l; OC get pod -A --field-selector=status.phase=Running --no-headers -o custom-columns=NS:.metadata.namespace | grep -c '^$t-'; } | paste -sd' '" "^0 [1-9]"
done
want "8 GPU workers labelled scd/gpu, 8 simulated GPUs allocatable each (64 in all)" "OC get nodes -l scd/gpu=true -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\\.com/gpu}{\"\\n\"}{end}' | awk '{n++; s+=\$1} END {print n, s}'" "^8 64$"
want "the model pods run on GPU workers only" "OC -n llm get pod --field-selector=status.phase=Running --no-headers -o custom-columns=NODE:.spec.nodeName | grep -vc '^gpu-worker'" "^0$"
want "every node carries its rack (scd/rack: 2 rack1, 1 rack2, 7 rack3, 7 rack4)" "OC get nodes -L scd/rack --no-headers | awk '{print \$NF}' | sort | uniq -c | paste -sd' ' | tr -s ' '" "^ ?2 rack1 1 rack2 7 rack3 7 rack4$"
want "Prometheus on the masters (the 10 GiB workers keep their memory)" "OC -n openshift-monitoring get pod -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[*].spec.nodeName}' | tr ' ' '\\n' | grep -vc '^master'" "^0$"
log "== day-2 networking"
want "every NodeNetworkConfigurationPolicy Available" "OC get nncp --no-headers | awk '{print \$2}' | sort | uniq -c | tr -s ' '" "^ ?[0-9]+ Available$"
want "tenant-vrf-join on all 17 nodes" "OC -n scd-system get ds tenant-vrf-join -o jsonpath='{.status.numberReady}/{.status.desiredNumberScheduled}'" "^17/17$"
for n in prod-worker1 dev-worker1 gpu-worker1 master1; do
  want "$n: bond0.111 in tenant-prod and bond0.211 in tenant-dev, IPv4 forwarding on both" "SSHC ocp-$n 'for v in 111:tenant-prod 211:tenant-dev; do i=bond0.\${v%%:*}; ip -o link show \$i | grep -o \"master \${v#*:}\"; cat /proc/sys/net/ipv4/conf/\$i/forwarding; done' | paste -sd' '" "^master tenant-prod 1 master tenant-dev 1$"
  want "$n: storage bond bond1 up, separate from the data bond" "SSHC ocp-$n 'cat /sys/class/net/bond1/operstate; cat /sys/class/net/bond0/operstate' | paste -sd' '" "^up up$"
done
want "UDNs tenant-prod / tenant-dev Ready (layer3, primary)" "OC get clusteruserdefinednetwork -o jsonpath='{range .items[*]}{.metadata.name}={.status.conditions[?(@.type==\"NetworkCreated\")].status}{\" \"}{end}'" "tenant-dev=True tenant-prod=True"
want "RouteAdvertisements accepted for both tenants" "OC get routeadvertisements -o jsonpath='{range .items[*]}{.metadata.name}={.status.status}{\" \"}{end}'" "udn-dev=Accepted udn-prod=Accepted"
log ""; log "RESULT: $P passed, $F failed ($RD)"
[ $F = 0 ]
