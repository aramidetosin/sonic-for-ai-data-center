#!/bin/bash
# validate-ocp.sh [prod|dev|gpu ...]: checks of the three OpenShift clusters, each run through its OWN bastion: nodes and roles,
# the node network and VIPs, storage bond, chrony, the day-2 networking (gpu: the rail NNCPs), MetalLB in the tenant VRF, and that
# a cluster's credentials reach that cluster only (hard tenancy). One PASS/FAIL line each -> results/<lab>_ocp_<ts>/result.txt
cd "$(dirname "$0")"; . ./lib.sh
P=0; F=0; RD=$(resdir ocp); OUT=$RD/result.txt; CMDLOG=$PWD/$RD/commands.txt; : > $OUT; : > $CMDLOG; WHICH=${*:-$CLUSTERS}
log() { echo "$*" | tee -a $OUT; }
ok() { if [ "$2" = 0 ]; then log "PASS  $1"; P=$((P+1)); else log "FAIL  $1  ($3)"; F=$((F+1)); fi; }
want() { local got; [ -n "${CMDLOG:-}" ] && printf '$ %s\n' "$2" | redact >> "$CMDLOG"; got=$(eval "$2" 2>&1); echo "$got" | grep -q -E "$3"; ok "$1" $? "got: $(echo $got | head -c 160)"; }
deny() { local got; [ -n "${CMDLOG:-}" ] && printf '$ %s\n' "$2" | redact >> "$CMDLOG"; got=$(eval "$2" 2>&1); if echo "$got" | grep -q -E "$3"; then ok "$1" 1 "reached: $(echo $got | head -c 90)"; else ok "$1" 0; fi; }
OC() { local cl=$1; shift; docker exec $C-bastion-$cl oc "$@" 2>&1; }
SSHC() { NSSH "$1" "$2" </dev/null; }
ctr() { case $2 in $1-*) echo $2;; *) echo $1-$2;; esac; }
declare -A NET=([prod]=10.0.1 [dev]=10.0.1 [gpu]=10.0.8) STOR=([prod]=10.0.3 [dev]=10.0.3 [gpu]=10.0.9) N=([prod]=3 [dev]=3 [gpu]=11)
declare -A HOSTS=([prod]="prod-cp1=21 prod-cp2=22 prod-cp3=23" [dev]="dev-cp1=21 dev-cp2=22 dev-cp3=23"
  [gpu]="master1=11 master2=12 master3=13 gpu-worker1=21 gpu-worker2=22 gpu-worker3=23 gpu-worker4=24 gpu-worker5=25 gpu-worker6=26 gpu-worker7=27 gpu-worker8=28")
for cl in $WHICH; do n=${N[$cl]}; p=${NET[$cl]}
  log "== OpenShift $cl ($cl.dc.lab) from bastion-$cl"
  want "$cl: $n nodes Ready" "OC $cl get nodes --no-headers | awk '\$2==\"Ready\"' | wc -l" "^$n$"
  if [ $cl = gpu ]; then
    want "gpu: 3 dedicated masters, 8 GPU workers" "OC gpu get nodes --no-headers | awk '{print \$3}' | sort | uniq -c | paste -sd' ' | tr -s ' '" "^ ?3 control-plane,master 8 worker$"
  else
    want "$cl: compact, 3 schedulable control-plane nodes, no separate workers" "{ OC $cl get nodes --no-headers | awk '{print \$3}' | sort -u; OC $cl get nodes -o jsonpath='{range .items[*]}{.spec.taints}{\"\\n\"}{end}' | grep -c NoSchedule; } | paste -sd' '" "^control-plane,master,worker 0$"
  fi
  exp=$(for h in ${HOSTS[$cl]}; do echo "${h%=*}=$p.${h#*=}"; done | sort | paste -sd' ')
  want "$cl: every node on $p.0/24 with its planned address ($(echo ${HOSTS[$cl]} | tr '=' '.'))" "OC $cl get nodes -o jsonpath='{range .items[*]}{.metadata.name}={.status.addresses[?(@.type==\"InternalIP\")].address}{\"\\n\"}{end}' | sort | paste -sd' '" "^$exp$"
  want "$cl: clusterversion 4.22.12 Available, not Progressing" "OC $cl get clusterversion --no-headers" "4\.22\.12 +True +False"
  want "$cl: every cluster operator Available, none Degraded" "OC $cl get co --no-headers | awk '\$3!=\"True\" || \$5!=\"False\"' | wc -l" "^0$"
  want "$cl: network type OVNKubernetes (default network = the cluster's VRF: no UDN, no RouteAdvertisements)" "{ OC $cl get network.config cluster -o jsonpath={.status.networkType}; echo; OC $cl get clusteruserdefinednetwork,userdefinednetwork -A -o name 2>/dev/null | grep -c 'userdefinednetwork'; OC $cl get routeadvertisements -o name 2>/dev/null | grep -c '^routeadvertisements'; } | paste -sd' '" "^OVNKubernetes 0 0$"
  want "$cl: machine config pools Updated, none Degraded" "OC $cl get mcp --no-headers | awk '\$3!=\"True\" || \$5!=\"False\"' | wc -l" "^0$"
  want "$cl: the API answers on api.$cl.dc.lab ($p.5) from bastion-$cl" "docker exec $C-bastion-$cl curl -sk -o /dev/null -w %{http_code} https://api.$cl.dc.lab:6443/readyz" "^200$"
  want "$cl: the console answers on the ingress VIP ($p.7) from bastion-$cl" "docker exec $C-bastion-$cl curl -sk -o /dev/null -w %{http_code} https://console-openshift-console.apps.$cl.dc.lab/" "^200$"
  want "$cl: every pod Running / Completed" "OC $cl get pods -A --no-headers | awk '\$4 != \"Running\" && \$4 != \"Completed\"' | wc -l" "^0$"
  for h in ${HOSTS[$cl]}; do hn=${h%=*}; o=${h#*=}; c=$(ctr $cl $hn)
    case $hn in master2|master3|gpu-worker[2-7]|prod-cp[23]|dev-cp[23]) continue;; esac   # one control-plane and one GPU node of each cluster in depth
    want "$cl/$hn: bond0 (data, the uplink of OVN-Kubernetes' br-ex, which holds $p.$o) and bond1 ${STOR[$cl]}.$o (storage) up, MTU 9000" "SSHC $c 'for b in bond0 bond1; do echo \$(cat /sys/class/net/\$b/operstate) \$(cat /sys/class/net/\$b/mtu); done; ip -br -4 addr show br-ex; ip -br -4 addr show bond1; sudo ovs-vsctl list-ports br-ex | grep -x bond0' | xargs" "^up 9000 up 9000 br-ex [A-Z]+ $p\.$o/24 169\.254\.0\.2/17( $p\.[57]/32)* bond1 UP ${STOR[$cl]}\.$o/24 bond0$"
    want "$cl/$hn: no VLAN sub-interface and no VRF on the node (the node network IS the tenant VRF)" "SSHC $c 'ip -o link show type vlan | wc -l; ip -o link show type vrf | wc -l' | paste -sd' '" "^0 0$"
    want "$cl/$hn: chrony polls only dns-ntp1 / dns-ntp2" "SSHC $c 'chronyc -n sources' | awk '\$1 ~ /^\\^/ {print \$2}' | sort | paste -sd' '" "^10\.250\.0\.11 10\.250\.0\.12$"
  done
  # hard tenancy: a cluster's kubeconfig is useless against the others (another CA, another API in another VRF)
  for o in $CLUSTERS; do [ $o = $cl ] && continue
    deny "$cl: bastion-$cl's kubeconfig cannot list cluster $o's nodes (api.$o.dc.lab)" "docker exec $C-bastion-$cl oc --server=https://api.$o.dc.lab:6443 --request-timeout=10s get nodes --no-headers" "Ready"
  done
  if [ $cl = gpu ]; then
    log "== gpu: placement and day-2 networking"
    want "gpu: 8 GPU workers labelled scd/gpu, 8 simulated GPUs allocatable each (64 in all)" "OC gpu get nodes -l scd/gpu=true -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\\.com/gpu}{\"\\n\"}{end}' | awk '{n++; s+=\$1} END {print n, s}'" "^8 64$"
    want "gpu: the model pods run on GPU workers only" "OC gpu -n llm get pod --field-selector=status.phase=Running --no-headers -o custom-columns=NODE:.spec.nodeName | grep -vc '^gpu-worker'" "^0$"
    want "gpu: Prometheus on the masters (the 10 GiB workers keep their memory)" "OC gpu -n openshift-monitoring get pod -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[*].spec.nodeName}' | tr ' ' '\\n' | grep -vc '^master'" "^0$"
    want "gpu: the 8 rail NNCPs (rails-gpu-worker1..8) Available, no other policy" "{ OC gpu get nncp --no-headers | awk '\$1 ~ /^rails-gpu-worker[1-8]\$/ && \$2 == \"Available\"' | wc -l; OC gpu get nncp --no-headers | wc -l; } | paste -sd' '" "^8 8$"
  else
    log "== $cl: MetalLB in ${cl^}'s own VRF"
    want "$cl: MetalLB pool 10.0.1.200-10.0.1.209 and its BGP peers (the rack leaves' loopbacks)" "{ OC $cl -n metallb-system get ipaddresspool -o jsonpath='{.items[*].spec.addresses}'; echo; OC $cl -n metallb-system get bgppeer -o jsonpath='{range .items[*]}{.spec.peerAddress} {end}'; } | paste -sd' '" "10\.0\.1\.200-10\.0\.1\.209.*10\.0\.0\.(15|17).*10\.0\.0\.(16|18)"
    want "$cl: the 5 app addresses 10.0.1.200-.204 assigned (whoami, chat, inference, harbor, minio)" "OC $cl get svc -A --field-selector spec.type=LoadBalancer -o jsonpath='{range .items[*]}{.status.loadBalancer.ingress[0].ip}{\"\\n\"}{end}' | sort -u | paste -sd' '" "^10\.0\.1\.200 10\.0\.1\.201 10\.0\.1\.202 10\.0\.1\.203 10\.0\.1\.204$"
  fi
done
log ""; log "RESULT: $P passed, $F failed ($RD)"
[ $F = 0 ]
