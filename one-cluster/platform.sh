#!/bin/bash
# platform.sh [step ...]: the platform of cluster ocp, through bastion-ocp; after tenant-net.sh. Idempotent; steps (default all, in order):
#   zones      topology.kubernetes.io/zone per node: ocp (masters, GPU workers), prod, dev (Trident topology)
#   trident    Trident 26.06.2 (operator chart 100.2606.2), the node plugin on every node (tolerates the tenant taints), 6 backends + classes
#   registry   the internal registry on ocp-nas (RWX), default route
#   images     lab images > the internal registry (skopeo in the bastion's network)
#   chrony     the day-1 MachineConfigs 99-{master,worker}-scd-chrony are present (manifests/, make-iso.sh) and a chrony.conf change
#              restarts chronyd instead of rebooting the node (MachineConfiguration cluster, nodeDisruptionPolicy)
#   monitoring cluster monitoring on the masters (the GPU workers keep their memory for the model shards)
#   keys       one API key per tenant for the models (Secret llm/llm-api-keys: line 1 prod, line 2 dev; generated here, never printed)
#   gpuops     OLM: Node Feature Discovery (redhat-operators) + NVIDIA Network Operator (certified-operators), default channels
#   netop      the network-operator resources: fake pci-15b3 rule, NicClusterPolicy (rdma_shared), MacvlanNetwork net-rail-0..7
#   fakegpu    run:ai fake-gpu-operator 0.0.59: 8 simulated GPUs (nvidia.com/gpu) per GPU worker
#   models     LFM2.5 24B (Ollama registry, sha256) + Qwen2.5-0.5B on ocp-nas
#   serve      the model API: Services + routes, then the sharded LFM replicas and Qwen (llm-serve.sh)
#   lldp       LLDP on every node: the DaemonSet scd-system/lldpd, so the switches name each node and NIC on their ports
# Secrets are generated inside the cluster; the SVM password comes from .env over stdin. Nothing is printed.
cd "$(dirname "$0")"; . ./lib.sh; . ./.env
STEPS=${*:-zones trident registry images chrony monitoring keys gpuops netop fakegpu models serve lldp}
FGO_VERSION=0.0.59
B=$C-bastion-ocp
OC() { docker exec -i $B oc "$@"; }
SH() { docker exec -i $B bash -c "$1"; }
apply() { python3 gen-platform.py $1 | OC apply -f - | sed 's/^/   /'; }
step() { say "platform: $*"; }
csv_wait() {   # csv_wait <namespace> <subscription>: its installed CSV Succeeded (a copied CSV of another operator never counts)
  SH "for i in \$(seq 1 90); do c=\$(oc -n $1 get sub $2 -o jsonpath={.status.installedCSV} 2>/dev/null)
        [ -n \"\$c\" ] && [ \"\$(oc -n $1 get csv \$c -o jsonpath={.status.phase} 2>/dev/null)\" = Succeeded ] && break; sleep 10; done
      echo \"    \$c \$(oc -n $1 get csv \$c -o jsonpath={.status.phase} 2>/dev/null)\""; }
for s in $STEPS; do case $s in
chrony)
  step "chrony from dns-ntp1/2 only: day-1 MachineConfigs, restart instead of reboot on change"
  OC patch machineconfiguration cluster --type merge -p "$(cat manifests-ocp/machineconfiguration-chrony-policy.json)" | sed 's/^/   /'
  echo "   $(OC get mc --no-headers 2>/dev/null | awk '$1 ~ /scd-chrony$/ {print $1}' | paste -sd' ') (expected: 99-master-scd-chrony 99-worker-scd-chrony)" ;;
monitoring)
  step "cluster monitoring on the masters"; apply monitoring ;;
lldp)
  step "LLDP on every node (DaemonSet scd-system/lldpd)"
  OC create ns scd-system --dry-run=client -o yaml | OC apply -f - >/dev/null; OC adm policy add-scc-to-user privileged -z lldpd -n scd-system >/dev/null
  apply lldp; SH "oc -n scd-system rollout status ds/lldpd --timeout=600s | tail -1" ;;
zones)
  step "zone labels (Trident topology)"
  for n in master1 master2 master3 gpu-worker1 gpu-worker2 gpu-worker3 gpu-worker4 gpu-worker5 gpu-worker6 gpu-worker7 gpu-worker8; do OC label node $n topology.kubernetes.io/zone=ocp --overwrite >/dev/null; done
  for t in prod dev; do for i in 1 2 3; do OC label node $t-worker$i topology.kubernetes.io/zone=$t --overwrite >/dev/null; done; done
  OC get nodes -L topology.kubernetes.io/zone --no-headers | awk '{print $NF}' | sort | uniq -c | sed 's/^/   /' ;;
trident)
  step "Trident 26.06.2, CSI topology on, node plugin everywhere"
  SH "helm repo add netapp-trident https://netapp.github.io/trident-helm-chart >/dev/null 2>&1; helm repo update >/dev/null 2>&1
      helm status trident -n trident >/dev/null 2>&1 || helm install trident netapp-trident/trident-operator --version 100.2606.2 -n trident --create-namespace \
        --set-json 'tridentNodePluginTolerations=[{\"operator\":\"Exists\"}]' --wait --timeout 15m | grep -E 'STATUS|REVISION'
      for i in \$(seq 1 60); do [ \"\$(oc get torc trident -o jsonpath={.status.status} 2>/dev/null)\" = Installed ] && break; sleep 10; done
      echo \"   torc: \$(oc get torc trident -o jsonpath={.status.status}), node plugins: \$(oc -n trident get ds trident-node-linux -o jsonpath={.status.numberReady}/{.status.desiredNumberScheduled})\""
  printf '%s' "$ONTAP_VSADMIN_PW" | SH "oc -n trident create secret generic ontap-svm --from-literal=username=vsadmin --from-file=password=/dev/stdin --dry-run=client -o yaml | oc apply -f - >/dev/null"
  apply trident
  SH "for i in \$(seq 1 60); do [ \"\$(oc -n trident get tbc --no-headers | grep -c Bound)\" = 6 ] && break; sleep 10; done
      oc -n trident get tbc --no-headers | awk '{print \"   \", \$1, \$3, \$4}'; oc get sc --no-headers | awk '{print \"   \", \$1, \$2}'" ;;
registry)
  step "internal registry on ocp-nas (RWX), default route"
  apply registry
  OC patch configs.imageregistry.operator.openshift.io cluster --type merge -p '{"spec":{"managementState":"Managed","defaultRoute":true,"replicas":1,"rolloutStrategy":"Recreate","storage":{"pvc":{"claim":"image-registry-storage"}}}}' | sed 's/^/   /'
  SH "for i in \$(seq 1 60); do oc -n openshift-image-registry get deploy/image-registry >/dev/null 2>&1 && break; sleep 10; done
      oc -n openshift-image-registry rollout status deploy/image-registry --timeout=900s | tail -1; oc -n openshift-image-registry get pvc image-registry-storage --no-headers | awk '{print \"   \", \$1, \$2}'" ;;
images)
  step "lab images > the internal registry"
  RES=$(docker inspect -f '{{.ResolvConfPath}}' $B); T=$(OC create token pusher -n scd-images --duration=2h)
  for i in c2/llm:2 c2/ai-sim:1 c2/minio:RELEASE.2025-09-07T16-13-09Z c2/mc:RELEASE.2025-08-13T08-35-41Z c2/lldpd:1 c2/rdma-tools:1 c2/generic-device-plugin:8dc84958; do
    docker run --rm --network container:$B -v "$RES:/etc/resolv.conf:ro" -v /var/run/docker.sock:/var/run/docker.sock quay.io/skopeo/stable:v1.18.0 \
      copy -q --dest-tls-verify=false --dest-creds "pusher:$T" docker-daemon:$i docker://default-route-openshift-image-registry.apps.ocp.dc.lab/scd-images/${i#c2/} \
      && echo "   ${i#c2/} pushed" || echo "   ${i#c2/} FAILED"
  done ;;
keys)
  step "an API key per tenant for the models (never printed)"
  SH "oc create ns llm --dry-run=client -o yaml | oc apply -f - >/dev/null
      oc -n llm get secret llm-api-keys >/dev/null 2>&1 || { printf 'sk-prod-%s\nsk-dev-%s\n' \$(openssl rand -hex 20) \$(openssl rand -hex 20) | oc -n llm create secret generic llm-api-keys --from-file=keys=/dev/stdin >/dev/null; }
      echo \"   llm/llm-api-keys: \$(oc -n llm get secret llm-api-keys -o jsonpath={.data.keys} | base64 -d | grep -c .) keys\"" ;;
gpuops)   # the NFD instance from NFD's own CSV: MetalLB's all-namespaces OperatorGroup copies its CSV into openshift-nfd too, and .items[0]
          # once picked it, so no NFD workers ran, no pci-15b3 label, no RDMA device plugin
  step "OLM: NFD + NVIDIA Network Operator"
  for o in "openshift-nfd nfd redhat-operators" "nvidia-network-operator nvidia-network-operator certified-operators"; do set -- $o
    ch=$(OC get packagemanifest $2 -n openshift-marketplace -o jsonpath='{.status.defaultChannel}')
    printf '{"apiVersion":"v1","kind":"Namespace","metadata":{"name":"%s"}}\n---\n{"apiVersion":"operators.coreos.com/v1","kind":"OperatorGroup","metadata":{"name":"%s","namespace":"%s"},"spec":{"targetNamespaces":["%s"]}}\n---\n{"apiVersion":"operators.coreos.com/v1alpha1","kind":"Subscription","metadata":{"name":"%s","namespace":"%s"},"spec":{"name":"%s","channel":"%s","source":"%s","sourceNamespace":"openshift-marketplace","installPlanApproval":"Automatic"}}\n' \
      $1 $1 $1 $1 $2 $1 $2 $ch $3 | OC apply -f - | sed 's/^/   /'
  done
  csv_wait openshift-nfd nfd; csv_wait nvidia-network-operator nvidia-network-operator
  SH "oc -n openshift-nfd get nodefeaturediscovery nfd-instance >/dev/null 2>&1 || oc -n openshift-nfd get \$(oc -n openshift-nfd get csv -o name | grep '/nfd\\.') -o jsonpath='{.metadata.annotations.alm-examples}' | jq '.[] | select(.kind==\"NodeFeatureDiscovery\") | .metadata.name=\"nfd-instance\" | .metadata.namespace=\"openshift-nfd\"' | oc apply -f - | sed 's/^/   /'" ;;
netop)
  step "network-operator resources"
  OC create ns scd-system --dry-run=client -o yaml | OC apply -f - >/dev/null
  # the operators register these CRDs only after their CSVs install; applying earlier fails with "no matches for kind"
  SH "oc wait --for=condition=Established --timeout=600s crd/nicclusterpolicies.mellanox.com crd/macvlannetworks.mellanox.com crd/nodefeaturerules.nfd.k8s-sigs.io" | sed "s/^/   /"
  apply gpu-netop
  OC adm policy add-scc-to-user privileged -z rdma-device-plugin -n scd-system >/dev/null   # a device plugin writes the kubelet socket (as lldpd)
  SH "for i in \$(seq 1 60); do [ \"\$(oc get nicclusterpolicy nic-cluster-policy -o jsonpath={.status.state})\" = ready ] && break; sleep 10; done
      echo \"   NicClusterPolicy: \$(oc get nicclusterpolicy nic-cluster-policy -o jsonpath={.status.state})\"; oc get net-attach-def -n default --no-headers | awk '{print \$1}' | paste -sd' ' | sed 's/^/    /'" ;;
fakegpu)
  step "run:ai fake-gpu-operator $FGO_VERSION: 8 simulated GPUs per GPU worker"
  SH "oc create ns gpu-operator --dry-run=client -o yaml | oc apply -f - >/dev/null; oc adm policy add-scc-to-group privileged system:serviceaccounts:gpu-operator >/dev/null
      helm repo add fake-gpu-operator https://runai.jfrog.io/artifactory/api/helm/fake-gpu-operator-charts-prod >/dev/null 2>&1; helm repo update >/dev/null 2>&1
      helm upgrade --install gpu-operator fake-gpu-operator/fake-gpu-operator --version $FGO_VERSION -n gpu-operator --wait --timeout 15m \
        --set topology.nodePools.default.gpuCount=8 --set topology.nodePools.default.gpuProduct=NVIDIA-H100-80GB-HBM3 --set topology.nodePools.default.gpuMemory=81559 | grep -E 'STATUS|REVISION'
      for i in \$(seq 1 60); do [ \"\$(oc get nodes -l scd/gpu=true -o json | jq '[.items[].status.allocatable[\"nvidia.com/gpu\"] | select(. == \"8\")] | length')\" = 8 ] && break; sleep 10; done
      oc get nodes -l scd/gpu=true -o json | jq -r '.items[] | \"    \" + .metadata.name + \" nvidia.com/gpu \" + (.status.allocatable[\"nvidia.com/gpu\"] // \"none\")'" ;;
models)
  step "models on ocp-nas: LFM2.5 24B (sha256) + Qwen2.5-0.5B"
  apply gpu-models
  SH "oc -n llm wait --for=condition=complete job/publish-models --timeout=5400s >/dev/null && oc -n llm logs job/publish-models -c lfm | tail -3 || { oc -n llm get pods -l job-name=publish-models; exit 1; }" ;;
serve)
  step "model API: Services + routes, then llm-serve.sh"
  apply gpu-serve; ./llm-serve.sh up ;;
*) say "unknown step $s"; exit 1 ;;
esac; done
