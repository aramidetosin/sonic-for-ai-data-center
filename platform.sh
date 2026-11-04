#!/bin/bash
# platform.sh <prod|dev|gpu> [step ...]: the platform of one cluster, through that cluster's own
# bastion (bastion-<cl>, OCL / SHL in lib.sh). Idempotent. tenant-apps.sh <t> runs the common steps of a tenant cluster through this script.
# Common steps (every cluster):
#   trident    Trident 26.06.2 (operator chart 100.2606.2), backends <cl>-san / <cl>-nas on svm-<cl>, default class <cl>-san
#   registry   the internal registry on <cl>-nas (RWX), default route
#   images     the lab images this cluster runs > its internal registry (skopeo in the bastion's network, the bastion's resolver)
#   lldp       LLDP on every node: DaemonSet scd-system/lldpd, system name <host>.<cl>.dc.lab
#   chrony     the day-1 MachineConfigs 99-{master,worker}-scd-chrony are present (manifests/, make-iso.sh) and a chrony.conf change
#              restarts chronyd instead of rebooting (nodeDisruptionPolicy)
# gpu cluster only (default order):
#   roles      scd/gpu=true + run.ai/simulated-gpu-node-pool=default on gpu-worker1..8
#   monitoring cluster monitoring on the masters
#   keys       one API key per tenant for the models (Secret llm/llm-api-keys: line 1 prod, line 2 dev; generated here, never printed)
#   nmstate    the NMState operator + instance, then the 8 day-2 rail policies (gen.py manifests-day2-rails.yaml); waits until Available
#   gpuops     OLM: Node Feature Discovery (redhat-operators) + NVIDIA Network Operator (certified-operators), default channels
#   netop      the network-operator resources: fake pci-15b3 rule, NicClusterPolicy, generic RDMA device plugin, MacvlanNetwork net-rail-0..7
#   fakegpu    run:ai fake-gpu-operator 0.0.59: 8 simulated GPUs (nvidia.com/gpu) per GPU worker
#   models     LFM2.5 24B (Ollama registry, sha256) + Qwen2.5-0.5B on gpu-nas
#   serve      the model API: Services + routes (llm.apps.gpu.dc.lab), then the sharded LFM replicas and Qwen (llm-serve.sh)
# Secrets are generated inside the cluster; the vsadmin password comes from appliances.env (lib.sh) over stdin. Nothing is printed.
cd "$(dirname "$0")"; . ./lib.sh
CL=${1:?prod|dev|gpu}; shift
case $CL in prod|dev) DEF="trident registry images lldp chrony";;
  gpu) DEF="roles trident registry images lldp chrony monitoring keys nmstate gpuops netop fakegpu models serve";;
  *) echo "usage: $0 prod|dev|gpu [step ...]"; exit 2;; esac
STEPS=${*:-$DEF}
FGO_VERSION=0.0.59
B=$(BAST $CL)
docker inspect $B >/dev/null 2>&1 || { say "$B missing (bastion of cluster $CL)"; exit 1; }
OC() { OCL $CL "$@"; }
SH() { SHL $CL "$1"; }
apply() { python3 gen-platform.py $CL $1 | OC apply -f - | sed 's/^/   /'; }
step() { say "platform $CL: $*"; }
gpuonly() { [ $CL = gpu ] || { say "step $1 belongs to the gpu cluster"; exit 1; }; }
sub() {   # sub <namespace> <package> <source> [all]: an OLM subscription on the package's default channel, then wait for its CSV
  local ch og; ch=$(OC get packagemanifest $2 -n openshift-marketplace -o jsonpath='{.status.defaultChannel}')
  og="{\"targetNamespaces\":[\"$1\"]}"; [ "${4:-}" = all ] && og="{}"
  printf '{"apiVersion":"v1","kind":"Namespace","metadata":{"name":"%s"}}\n---\n{"apiVersion":"operators.coreos.com/v1","kind":"OperatorGroup","metadata":{"name":"%s","namespace":"%s"},"spec":%s}\n---\n{"apiVersion":"operators.coreos.com/v1alpha1","kind":"Subscription","metadata":{"name":"%s","namespace":"%s"},"spec":{"name":"%s","channel":"%s","source":"%s","sourceNamespace":"openshift-marketplace","installPlanApproval":"Automatic"}}\n' \
    $1 $1 $1 "$og" $2 $1 $2 $ch $3 | OC apply -f - | sed 's/^/   /'
  csv_wait $1 $2; }
csv_wait() {   # csv_wait <namespace> <subscription>: its installed CSV Succeeded (a copied CSV of another operator never counts)
  SH "for i in \$(seq 1 90); do c=\$(oc -n $1 get sub $2 -o jsonpath={.status.installedCSV} 2>/dev/null)
        [ -n \"\$c\" ] && [ \"\$(oc -n $1 get csv \$c -o jsonpath={.status.phase} 2>/dev/null)\" = Succeeded ] && break; sleep 10; done
      echo \"    \$c \$(oc -n $1 get csv \$c -o jsonpath={.status.phase} 2>/dev/null)\""; }
case $CL in gpu) IMGS="c2/llm:2 c2/ai-sim:1 c2/mc:RELEASE.2025-08-13T08-35-41Z c2/lldpd:1 c2/rdma-tools:1 c2/generic-device-plugin:8dc84958";;
  *) IMGS="c2/minio:RELEASE.2025-09-07T16-13-09Z c2/mc:RELEASE.2025-08-13T08-35-41Z c2/lldpd:1";; esac
for s in $STEPS; do case $s in
roles) gpuonly roles
  step "GPU workers: scd/gpu, simulated 8-GPU pool"
  for n in $(nodes_of gpu | grep '^gpu-worker'); do OC label node $n scd/gpu=true run.ai/simulated-gpu-node-pool=default --overwrite >/dev/null; done
  OC get nodes -L scd/gpu --no-headers | awk '{print "   ", $1, $3, $NF}' ;;
trident)
  step "Trident 26.06.2, backends on svm-$CL"
  SH "helm repo add netapp-trident https://netapp.github.io/trident-helm-chart >/dev/null 2>&1; helm repo update >/dev/null 2>&1
      helm status trident -n trident >/dev/null 2>&1 || helm install trident netapp-trident/trident-operator --version 100.2606.2 -n trident --create-namespace \
        --set-json 'tridentNodePluginTolerations=[{\"operator\":\"Exists\"}]' --wait --timeout 15m | grep -E 'STATUS|REVISION'
      for i in \$(seq 1 60); do [ \"\$(oc get torc trident -o jsonpath={.status.status} 2>/dev/null)\" = Installed ] && break; sleep 10; done
      echo \"   torc: \$(oc get torc trident -o jsonpath={.status.status}), node plugins: \$(oc -n trident get ds trident-node-linux -o jsonpath={.status.numberReady}/{.status.desiredNumberScheduled})\""
  [ -n "${ONTAP_VSADMIN_PW:-}" ] || { say "ONTAP_VSADMIN_PW not set (appliances.env)"; exit 1; }
  printf '%s' "$ONTAP_VSADMIN_PW" | SH "oc -n trident create secret generic ontap-svm --from-literal=username=vsadmin --from-file=password=/dev/stdin --dry-run=client -o yaml | oc apply -f - >/dev/null"
  apply trident
  SH "for i in \$(seq 1 60); do [ \"\$(oc -n trident get tbc --no-headers | grep -c Bound)\" = 2 ] && break; sleep 10; done
      oc -n trident get tbc --no-headers | awk '{print \"   \", \$1, \$3, \$4}'; oc get sc --no-headers | awk '{print \"   \", \$1, \$2}'" ;;
registry)
  step "internal registry on $CL-nas (RWX), default route"
  apply registry
  OC patch configs.imageregistry.operator.openshift.io cluster --type merge -p '{"spec":{"managementState":"Managed","defaultRoute":true,"replicas":1,"rolloutStrategy":"Recreate","storage":{"pvc":{"claim":"image-registry-storage"}}}}' | sed 's/^/   /'
  SH "for i in \$(seq 1 60); do oc -n openshift-image-registry get deploy/image-registry >/dev/null 2>&1 && break; sleep 10; done
      oc -n openshift-image-registry rollout status deploy/image-registry --timeout=900s | tail -1; oc -n openshift-image-registry get pvc image-registry-storage --no-headers | awk '{print \"   \", \$1, \$2}'" ;;
images)
  step "lab images > the internal registry of $CL"
  RES=$(docker inspect -f '{{.ResolvConfPath}}' $B)
  CREDS="pusher:$(OC create token pusher -n scd-images --duration=2h)"   # by environment into the skopeo container, never on a command line
  for i in $IMGS; do
    CREDS=$CREDS docker run --rm --network container:$B -e CREDS -v "$RES:/etc/resolv.conf:ro" -v /var/run/docker.sock:/var/run/docker.sock --entrypoint bash $SKOPEO -c \
      "skopeo copy -q --dest-tls-verify=false --dest-creds \"\$CREDS\" docker-daemon:$i docker://default-route-openshift-image-registry.apps.$CL.dc.lab/scd-images/${i#c2/}" \
      && echo "   ${i#c2/} pushed" || echo "   ${i#c2/} FAILED"
  done; unset CREDS ;;
lldp)
  step "LLDP on every node (DaemonSet scd-system/lldpd)"
  OC create ns scd-system --dry-run=client -o yaml | OC apply -f - >/dev/null
  OC -n scd-system create sa lldpd --dry-run=client -o yaml | OC apply -f - >/dev/null; OC adm policy add-scc-to-user privileged -z lldpd -n scd-system >/dev/null
  apply lldp; SH "oc -n scd-system rollout status ds/lldpd --timeout=600s | tail -1" ;;
chrony)
  step "chrony from dns-ntp1/2 only: day-1 MachineConfigs, restart instead of reboot on change"
  OC patch machineconfiguration cluster --type merge -p "$(cat manifests-ocp/machineconfiguration-chrony-policy.json)" | sed 's/^/   /'
  echo "   $(OC get mc --no-headers 2>/dev/null | awk '$1 ~ /scd-chrony$/ {print $1}' | paste -sd' ') (expected: 99-master-scd-chrony 99-worker-scd-chrony)" ;;
monitoring) gpuonly monitoring
  step "cluster monitoring on the masters"; apply monitoring ;;
keys) gpuonly keys
  step "an API key per tenant for the models (never printed)"
  SH "oc create ns llm --dry-run=client -o yaml | oc apply -f - >/dev/null
      oc -n llm get secret llm-api-keys >/dev/null 2>&1 || { printf '%s\n%s\n' \$(openssl rand -hex 20) \$(openssl rand -hex 20) | oc -n llm create secret generic llm-api-keys --from-file=keys=/dev/stdin >/dev/null; }
      echo \"   llm/llm-api-keys: \$(oc -n llm get secret llm-api-keys -o jsonpath={.data.keys} | base64 -d | grep -c .) keys\"" ;;
nmstate) gpuonly nmstate
  step "NMState + the GPU rails"
  sub openshift-nmstate kubernetes-nmstate-operator redhat-operators
  echo '{"apiVersion":"nmstate.io/v1","kind":"NMState","metadata":{"name":"nmstate"}}' | OC apply -f - | sed 's/^/   /'
  SH "for i in \$(seq 1 60); do oc get crd nodenetworkconfigurationpolicies.nmstate.io >/dev/null 2>&1 && oc -n openshift-nmstate get ds nmstate-handler >/dev/null 2>&1 && break; sleep 10; done"
  OC apply -f - < manifests-day2-rails.yaml | sed 's/^/   /'
  SH "for i in \$(seq 1 60); do [ \"\$(oc get nncp --no-headers | grep -c Available)\" = 8 ] && break; sleep 10; done; oc get nncp --no-headers | awk '{print \"   \", \$1, \$2, \$3}'" ;;
gpuops) gpuonly gpuops   # the NFD instance from NFD's own CSV (an all-namespaces OperatorGroup can copy another CSV into openshift-nfd)
  step "OLM: NFD + NVIDIA Network Operator"
  sub openshift-nfd nfd redhat-operators; sub nvidia-network-operator nvidia-network-operator certified-operators
  SH "oc -n openshift-nfd get nodefeaturediscovery nfd-instance >/dev/null 2>&1 || oc -n openshift-nfd get \$(oc -n openshift-nfd get csv -o name | grep '/nfd\\.') -o jsonpath='{.metadata.annotations.alm-examples}' | jq '.[] | select(.kind==\"NodeFeatureDiscovery\") | .metadata.name=\"nfd-instance\" | .metadata.namespace=\"openshift-nfd\"' | oc apply -f - | sed 's/^/   /'" ;;
netop) gpuonly netop
  step "network-operator resources"
  OC create ns scd-system --dry-run=client -o yaml | OC apply -f - >/dev/null
  # the operators register these CRDs only after their CSVs install; applying earlier fails with "no matches for kind"
  SH "oc wait --for=condition=Established --timeout=600s crd/nicclusterpolicies.mellanox.com crd/macvlannetworks.mellanox.com crd/nodefeaturerules.nfd.k8s-sigs.io" | sed "s/^/   /"
  apply gpu-netop
  OC adm policy add-scc-to-user privileged -z rdma-device-plugin -n scd-system >/dev/null   # a device plugin writes the kubelet socket (as lldpd)
  SH "for i in \$(seq 1 60); do [ \"\$(oc get nicclusterpolicy nic-cluster-policy -o jsonpath={.status.state})\" = ready ] && break; sleep 10; done
      echo \"   NicClusterPolicy: \$(oc get nicclusterpolicy nic-cluster-policy -o jsonpath={.status.state})\"; oc get net-attach-def -n default --no-headers | awk '{print \$1}' | paste -sd' ' | sed 's/^/    /'
      oc -n scd-system rollout status ds/rdma-device-plugin --timeout=600s | tail -1" ;;
fakegpu) gpuonly fakegpu
  step "run:ai fake-gpu-operator $FGO_VERSION: 8 simulated GPUs per GPU worker"
  SH "oc create ns gpu-operator --dry-run=client -o yaml | oc apply -f - >/dev/null; oc adm policy add-scc-to-group privileged system:serviceaccounts:gpu-operator >/dev/null
      helm repo add fake-gpu-operator https://runai.jfrog.io/artifactory/api/helm/fake-gpu-operator-charts-prod >/dev/null 2>&1; helm repo update >/dev/null 2>&1
      helm upgrade --install gpu-operator fake-gpu-operator/fake-gpu-operator --version $FGO_VERSION -n gpu-operator --wait --timeout 15m \
        --set topology.nodePools.default.gpuCount=8 --set topology.nodePools.default.gpuProduct=NVIDIA-H100-80GB-HBM3 --set topology.nodePools.default.gpuMemory=81559 | grep -E 'STATUS|REVISION'
      for i in \$(seq 1 60); do [ \"\$(oc get nodes -l scd/gpu=true -o json | jq '[.items[].status.allocatable[\"nvidia.com/gpu\"] | select(. == \"8\")] | length')\" = 8 ] && break; sleep 10; done
      oc get nodes -l scd/gpu=true -o json | jq -r '.items[] | \"    \" + .metadata.name + \" nvidia.com/gpu \" + (.status.allocatable[\"nvidia.com/gpu\"] // \"none\")'" ;;
models) gpuonly models
  step "models on gpu-nas: LFM2.5 24B (sha256) + Qwen2.5-0.5B"
  apply gpu-models
  SH "oc -n llm wait --for=condition=complete job/publish-models --timeout=5400s >/dev/null && oc -n llm logs job/publish-models -c lfm | tail -3 || { oc -n llm get pods -l job-name=publish-models; exit 1; }" ;;
serve) gpuonly serve
  step "model API: Services + routes, then llm-serve.sh"
  apply gpu-serve; ./llm-serve.sh up ;;
*) say "unknown step $s"; exit 1 ;;
esac; done
