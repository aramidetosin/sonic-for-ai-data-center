#!/bin/bash
# tenant-net.sh [step ...]: the cluster-wide network layer of ocp, through bastion-ocp. Idempotent; steps (default all, in order):
#   roles      node labels and taints: scd/tenant=prod|dev on the tenant workers (+ NoSchedule taint), scd/gpu=true on the GPU workers
#   operators  OLM: kubernetes-nmstate-operator (openshift-nmstate), metallb-operator (metallb-system); default channels
#   rails      NMState instance, then the 8 day-2 rail policies (gen.py manifests-day2-rails.yaml); waits until all are Available
#   routing    network.operator: the FRR provider, route advertisements, local gateway mode (routingViaHost: VRF-lite needs it)
#   udn        the tenant namespaces and their ClusterUserDefinedNetworks; OVN-K creates VRFs tenant-prod / tenant-dev on every node
#   vrfjoin    DaemonSet scd-system/tenant-vrf-join: bond0.111 -> tenant-prod, bond0.211 -> tenant-dev (+ the connected route) on every node
#   attach     NMState: bond0.111 / bond0.211 and their addresses on every node (no controller: tenant-vrf-join owns the enslaving)
#   frr        every node peers in tenant-prod AND tenant-dev with its rack's two leaves (FRRConfiguration per rack, nodes labelled scd/rack)
#   ra         RouteAdvertisements: each tenant UDN into its VRF
#   tuned      tcp_l3mdev_accept=1 on the tenant workers, live, no reboot
#   metallb    the MetalLB instance on the network operator's FRR-K8s (no tenant pools; the shards do not use it)
#   shards     an IngressController per tenant on its workers' host network
#   check      what each step should have produced, one line each
cd "$(dirname "$0")"; . ./lib.sh
STEPS=${*:-roles operators rails routing udn vrfjoin frr ra metallb check}   # no attach: tenant-vrf-join creates the VLANs; tuned and shards are not used
B=$C-bastion-ocp
OC() { docker exec -i $B oc "$@"; }
SH() { docker exec -i $B bash -c "$1"; }
apply() { python3 gen-tenantnet.py $1 | OC apply -f - | sed 's/^/   /'; }
step() { say "tenant-net: $*"; }
sub() {   # sub <namespace> <package> <source> [all]: an OLM subscription on the package's default channel, then wait for its CSV;
          # all = an OperatorGroup that watches every namespace (the MetalLB operator supports no other install mode)
  local ch og; ch=$(OC get packagemanifest $2 -n openshift-marketplace -o jsonpath='{.status.defaultChannel}')
  og="{\"targetNamespaces\":[\"$1\"]}"; [ "${4:-}" = all ] && og="{}"
  printf '{"apiVersion":"v1","kind":"Namespace","metadata":{"name":"%s"}}\n---\n{"apiVersion":"operators.coreos.com/v1","kind":"OperatorGroup","metadata":{"name":"%s","namespace":"%s"},"spec":%s}\n---\n{"apiVersion":"operators.coreos.com/v1alpha1","kind":"Subscription","metadata":{"name":"%s","namespace":"%s"},"spec":{"name":"%s","channel":"%s","source":"%s","sourceNamespace":"openshift-marketplace","installPlanApproval":"Automatic"}}\n' \
    $1 $1 $1 "$og" $2 $1 $2 $ch $3 | OC apply -f - | sed 's/^/   /'
  csv_wait $1 $2; }
csv_wait() {   # csv_wait <namespace> <subscription>: its installed CSV Succeeded (a copied CSV of another operator never counts)
  SH "for i in \$(seq 1 90); do c=\$(oc -n $1 get sub $2 -o jsonpath={.status.installedCSV} 2>/dev/null)
        [ -n \"\$c\" ] && [ \"\$(oc -n $1 get csv \$c -o jsonpath={.status.phase} 2>/dev/null)\" = Succeeded ] && break; sleep 10; done
      echo \"    \$c \$(oc -n $1 get csv \$c -o jsonpath={.status.phase} 2>/dev/null)\""; }
for s in $STEPS; do case $s in
roles)
  step "labels and taints"
  for t in prod dev; do for i in 1 2 3; do OC label node $t-worker$i scd/tenant=$t --overwrite >/dev/null; OC adm taint node $t-worker$i scd/tenant=$t:NoSchedule --overwrite >/dev/null; done; done
  for i in 1 2 3 4 5 6 7 8; do OC label node gpu-worker$i scd/gpu=true run.ai/simulated-gpu-node-pool=default --overwrite >/dev/null; done
  # the rack of each node (its data bond's leaf pair): the per-rack FRR configs select on it
  for r in "rack1 master1 master2" "rack2 master3" "rack3 prod-worker1 prod-worker2 prod-worker3 gpu-worker1 gpu-worker2 gpu-worker3 gpu-worker4" \
           "rack4 dev-worker1 dev-worker2 dev-worker3 gpu-worker5 gpu-worker6 gpu-worker7 gpu-worker8"; do set -- $r; k=$1; shift
    for n in "$@"; do OC label node $n scd/rack=$k --overwrite >/dev/null; done; done
  OC get nodes -L scd/tenant,scd/gpu --no-headers | awk '{print "   ", $1, $3, $6, $7}' ;;
operators)
  step "OLM: NMState and MetalLB"; sub openshift-nmstate kubernetes-nmstate-operator redhat-operators; sub metallb-system metallb-operator redhat-operators all ;;
rails)
  step "NMState instance + the GPU rails"
  echo '{"apiVersion":"nmstate.io/v1","kind":"NMState","metadata":{"name":"nmstate"}}' | OC apply -f - | sed 's/^/   /'
  SH "for i in \$(seq 1 60); do oc get crd nodenetworkconfigurationpolicies.nmstate.io >/dev/null 2>&1 && oc -n openshift-nmstate get ds nmstate-handler >/dev/null 2>&1 && break; sleep 10; done"
  OC apply -f - < manifests-day2-rails.yaml | sed 's/^/   /'
  SH "for i in \$(seq 1 60); do [ \"\$(oc get nncp --no-headers | grep -c Available)\" = 8 ] && break; sleep 10; done; oc get nncp --no-headers | awk '{print \"   \", \$1, \$2, \$3}'" ;;
routing)
  step "network.operator: FRR provider, route advertisements, local gateway (rolls out OVN-K on every node)"
  OC patch network.operator cluster --type merge -p '{"spec":{"additionalRoutingCapabilities":{"providers":["FRR"]},"defaultNetwork":{"ovnKubernetesConfig":{"routeAdvertisements":"Enabled","gatewayConfig":{"routingViaHost":true,"ipForwarding":"Global"}}}}}' | sed 's/^/   /'
  SH "sleep 60; for i in \$(seq 1 90); do oc get co network -o jsonpath='{.status.conditions[?(@.type==\"Progressing\")].status}' | grep -q False && break; sleep 20; done
      oc get co network --no-headers; oc -n openshift-frr-k8s get ds --no-headers 2>/dev/null | awk '{print \"   frr-k8s:\", \$1, \$4\"/\"\$2}'" ;;
udn) step "tenant namespaces + ClusterUserDefinedNetworks"; apply udn
  SH "oc get clusteruserdefinednetwork -o custom-columns=NAME:.metadata.name,READY:.status.conditions[0].status --no-headers | sed 's/^/    /'" ;;
frr) step "FRR-K8s in the tenant VRFs"; apply frr ;;
vrfjoin) step "tenant-vrf-join DaemonSet"
  OC create ns scd-system --dry-run=client -o yaml | OC apply -f - >/dev/null; OC adm policy add-scc-to-user privileged -z tenant-vrf-join -n scd-system >/dev/null
  apply vrf-join; SH "oc -n scd-system rollout status ds/tenant-vrf-join --timeout=900s | tail -1" ;;
attach) step "NMState: the tenant VLANs on every node"; apply attach
  SH "for i in \$(seq 1 60); do [ \"\$(oc get nncp --no-headers | grep tenant-vlans | grep -c Available)\" = 17 ] && break; sleep 15; done; oc get nncp --no-headers | grep tenant-vlans | awk '{print \$2}' | sort | uniq -c | sed 's/^/   /'" ;;
ra) step "RouteAdvertisements (VRF-lite, targetVRF auto, all nodes)"; apply ra; sleep 20
  SH "oc get routeadvertisements -o custom-columns=NAME:.metadata.name,STATUS:.status.status --no-headers | sed 's/^/    /'" ;;
tuned) step "Tuned scd-tenant-vrf"; apply tuned ;;
metallb) step "MetalLB instance (frr-k8s-external)"; apply metallb ;;
shards) step "IngressController per tenant"; apply shards
  SH "for t in prod dev; do for i in \$(seq 1 60); do ip=\$(oc -n openshift-ingress get svc router-\$t -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null); [ -n \"\$ip\" ] && break; sleep 10; done; echo \"    router-\$t: \${ip:-no LoadBalancer IP}\"; done" ;;
check)
  step "checks: per tenant worker, the leaf session in the tenant VRF, its UDN slice, the shard answering through the VRF"
  for t in prod dev; do l=$([ $t = prod ] && echo leaf3a-compute || echo leaf4a-compute); v=$([ $t = prod ] && echo Vrf-Prod || echo Vrf-Dev)
    p=$([ $t = prod ] && echo 10.10 || echo 10.20); o=$([ $t = prod ] && echo "21 22 23" || echo "31 32 33")
    for n in $o; do
      st=$(KL $l "show bgp ipv4 unicast vrf $v summary" | awk -v a=$p.1.$n '$1 == a {print ($9 ~ /^[0-9]+$/) ? "established, " $9 " prefix(es)" : $9}')
      udn=$(SW $l "sudo vtysh -c \"show ip route vrf $v bgp\"" | grep -cE "^B>\* +$p\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.0/24 .* via $p\.1\.$n,")
      code=$(X probe-$t "curl -sk -o /dev/null -w %{http_code} -m 8 https://$p.1.$n/")
      echo "    $t worker $p.1.$n: $st | UDN slice in $v: $udn | shard through $v: HTTP $code"
    done
  done ;;
*) say "unknown step $s"; exit 1 ;;
esac; done
