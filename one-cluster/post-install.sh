#!/bin/bash
# post-install.sh <prod|dev|gpu> [step ...]: the platform of one cluster, through its bastion. Idempotent; steps (default all, in order):
#   tenants (prod, dev): roles trident registry images secrets s3 harbor inference isolation
#   gpu:       roles trident registry images keys operators netop fakegpu models serve
#   (the tenants serve no model themselves; `inference` needs the gpu cluster's `keys` step first: it copies the tenant's key across)
# Secrets are generated INSIDE the cluster (openssl rand on the bastion); the SVM password comes from .env over stdin. Nothing is printed.
cd "$(dirname "$0")"; . ./lib.sh; . ./.env
CL=${1:?prod|dev|gpu}; shift
if [ $CL = gpu ]; then STEPS=${*:-roles trident registry images keys operators netop fakegpu models serve}
else STEPS=${*:-roles trident registry images secrets s3 harbor inference isolation}; fi
FGO_VERSION=0.0.59   # run:ai fake-gpu-operator chart (nvidia.com/gpu 8 per GPU worker)
B=$C-bastion-$CL; APPS=apps.$CL.dc.lab
OC() { docker exec -i $B oc "$@"; }
SH() { docker exec -i $B bash -c "$1"; }
apply() { python3 gen-platform.py $CL $1 | OC apply -f - | sed 's/^/   /'; }
step() { say "$CL: $*"; }
for s in $STEPS; do case $s in
roles)
  if [ $CL = gpu ]; then
    step "node roles: worker1-8 = GPU workers (scd/gpu, simulated 8-GPU pool for the fake-gpu-operator)"
    for i in 1 2 3 4 5 6 7 8; do OC label node worker$i scd/gpu=true run.ai/simulated-gpu-node-pool=default --overwrite >/dev/null; done
    OC get nodes -L scd/gpu --no-headers | awk '{print "   ", $1, $3, $6}'
  else
    step "node roles: worker-platform = platform (scd/platform); no model workers in the tenants"
    OC label node worker-platform scd/platform=true --overwrite >/dev/null
    OC get nodes -L scd/platform --no-headers | awk '{print "   ", $1, $3, $6}'
  fi ;;
trident)
  step "Trident 26.06.2 (chart 100.2606.2), backends on the SVM management LIF"
  SH "helm repo add netapp-trident https://netapp.github.io/trident-helm-chart >/dev/null 2>&1; helm repo update >/dev/null 2>&1
      helm status trident -n trident >/dev/null 2>&1 || helm install trident netapp-trident/trident-operator --version 100.2606.2 -n trident --create-namespace --wait --timeout 15m | grep -E 'STATUS|REVISION'
      for i in \$(seq 1 60); do [ \"\$(oc get torc trident -o jsonpath={.status.status} 2>/dev/null)\" = Installed ] && break; sleep 10; done; echo \"   torc: \$(oc get torc trident -o jsonpath={.status.status})\""
  printf '%s' "$ONTAP_VSADMIN_PW" | SH "oc -n trident create secret generic ontap-svm --from-literal=username=vsadmin --from-file=password=/dev/stdin --dry-run=client -o yaml | oc apply -f - >/dev/null"
  apply trident
  SH "for i in \$(seq 1 60); do [ \"\$(oc -n trident get tbc --no-headers | grep -c Bound)\" = 2 ] && break; sleep 10; done; oc -n trident get tbc --no-headers | awk '{print \"   \", \$1, \$3, \$4}'; oc get sc --no-headers | awk '{print \"   \", \$1, \$2}'" ;;
registry)
  step "internal registry on ontap-nas (RWX), default route"
  apply registry
  OC patch configs.imageregistry.operator.openshift.io cluster --type merge -p '{"spec":{"managementState":"Managed","defaultRoute":true,"replicas":1,"rolloutStrategy":"Recreate","storage":{"pvc":{"claim":"image-registry-storage"}}}}' | sed 's/^/   /'
  SH "for i in \$(seq 1 60); do oc -n openshift-image-registry get deploy/image-registry >/dev/null 2>&1 && break; sleep 10; done; oc -n openshift-image-registry rollout status deploy/image-registry --timeout=900s | tail -1; oc -n openshift-image-registry get pvc image-registry-storage --no-headers | awk '{print \"   \", \$1, \$2}'" ;;
images)
  step "lab images -> the internal registry (skopeo in the bastion's network, the bastion's resolver)"
  RES=$(docker inspect -f '{{.ResolvConfPath}}' $B); T=$(OC create token pusher -n scd-images --duration=2h)
  IMGS="c2/llm:2 c2/minio:RELEASE.2025-09-07T16-13-09Z c2/mc:RELEASE.2025-08-13T08-35-41Z"; [ $CL = gpu ] && IMGS="c2/llm:2 c2/ai-sim:1"
  for i in $IMGS; do
    docker run --rm --network container:$B -v "$RES:/etc/resolv.conf:ro" -v /var/run/docker.sock:/var/run/docker.sock quay.io/skopeo/stable:v1.18.0 \
      copy -q --dest-tls-verify=false --dest-creds "pusher:$T" docker-daemon:$i docker://default-route-openshift-image-registry.$APPS/scd-images/${i#c2/} \
      && echo "   ${i#c2/} pushed" || echo "   ${i#c2/} FAILED"
  done ;;
secrets)
  step "secrets (generated in the cluster, never printed)"
  SH "set -e; for n in s3 inference harbor; do oc create ns \$n --dry-run=client -o yaml | oc apply -f - >/dev/null; done
      oc -n s3 get secret minio-root >/dev/null 2>&1 || oc -n s3 create secret generic minio-root --from-literal=MINIO_ROOT_USER=scd-s3 --from-literal=MINIO_ROOT_PASSWORD=\$(openssl rand -hex 20) >/dev/null
      R=\$(oc -n s3 get secret models-ro -o name 2>/dev/null) || { P=\$(openssl rand -hex 16); for n in s3 inference; do oc -n \$n create secret generic models-ro --from-literal=MODELS_RO_USER=models-ro --from-literal=MODELS_RO_PASSWORD=\$P >/dev/null; done; }
      oc -n inference get secret models-ro >/dev/null 2>&1 || oc -n s3 get secret models-ro -o json | jq 'del(.metadata.namespace,.metadata.uid,.metadata.resourceVersion,.metadata.creationTimestamp,.metadata.managedFields)' | oc -n inference apply -f - >/dev/null
      oc -n inference get secret minio-root >/dev/null 2>&1 || oc -n s3 get secret minio-root -o json | jq 'del(.metadata.namespace,.metadata.uid,.metadata.resourceVersion,.metadata.creationTimestamp,.metadata.managedFields)' | oc -n inference apply -f - >/dev/null
      oc -n inference get secret litellm >/dev/null 2>&1 || oc -n inference create secret generic litellm --from-literal=master-key=sk-\$(openssl rand -hex 24) >/dev/null
      oc -n inference get secret inference-api-key >/dev/null 2>&1 || oc -n inference create secret generic inference-api-key --from-literal=key=\$(openssl rand -hex 24) >/dev/null
      oc -n harbor get secret harbor-admin >/dev/null 2>&1 || oc -n harbor create secret generic harbor-admin --from-literal=HARBOR_ADMIN_PASSWORD=Hb1-\$(openssl rand -hex 12) >/dev/null
      U=\$(oc -n s3 get secret minio-root -o jsonpath={.data.MINIO_ROOT_USER} | base64 -d); P=\$(oc -n s3 get secret minio-root -o jsonpath={.data.MINIO_ROOT_PASSWORD} | base64 -d)
      oc -n harbor create secret generic harbor-s3 --from-literal=REGISTRY_STORAGE_S3_ACCESSKEY=\$U --from-literal=REGISTRY_STORAGE_S3_SECRETKEY=\$P --dry-run=client -o yaml | oc apply -f - >/dev/null
      oc -n inference create sa anyuid --dry-run=client -o yaml | oc apply -f - >/dev/null; oc adm policy add-scc-to-user anyuid -z anyuid -n inference >/dev/null
      echo \"   \$(oc get secret -A --no-headers 2>/dev/null | awk '\$2 ~ /^(minio-root|models-ro|litellm|inference-api-key|harbor-admin|harbor-s3)\$/ {print \$1\"/\"\$2}' | paste -sd' ')\"" ;;
s3)
  step "MinIO on ontap-san (worker-platform), buckets models + harbor, read-only user for the loaders"
  apply s3
  SH "oc -n s3 rollout status deploy/minio --timeout=900s | tail -1; oc -n s3 wait --for=condition=complete job/minio-buckets --timeout=600s >/dev/null && oc -n s3 logs job/minio-buckets | tail -3" ;;
models)
  step "LFM2.5 24B: Ollama registry -> sha256 check -> s3://models (~15 GB, once)"
  apply models
  SH "oc -n inference wait --for=condition=complete job/publish-model-to-minio --timeout=5400s >/dev/null && oc -n inference logs job/publish-model-to-minio -c upload | tail -3 || { oc -n inference get pods -l job-name=publish-model-to-minio; exit 1; }" ;;
harbor)
  step "Harbor (chart 1.19.2): https://harbor.$APPS, blobs in s3://harbor, state on ontap-san, on worker-platform"
  python3 - $CL > /tmp/harbor-$CL.json <<'EOF'
import json, sys
cl = sys.argv[1]; host = "harbor.apps.%s.dc.lab" % cl; ns = {"nodeSelector": {"scd/platform": "true"}}
v = {"expose": {"type": "ingress", "tls": {"enabled": True, "certSource": "auto"}, "ingress": {"hosts": {"core": host}, "className": ""}},
     "externalURL": "https://" + host, "existingSecretAdminPassword": "harbor-admin", "existingSecretAdminPasswordKey": "HARBOR_ADMIN_PASSWORD",
     "persistence": {"enabled": True, "resourcePolicy": "keep",
                     "persistentVolumeClaim": {k: {"storageClass": "ontap-san", "size": s} for k, s in (("jobservice", {"jobLog": None}), ("database", "5Gi"), ("redis", "2Gi"), ("trivy", "5Gi"))},
                     "imageChartStorage": {"type": "s3", "disableredirect": True,
                                           "s3": {"region": "us-east-1", "bucket": "harbor", "regionendpoint": "http://minio.s3.svc:9000", "existingSecret": "harbor-s3", "secure": False, "v4auth": True}}},
     "portal": ns, "core": ns, "jobservice": ns, "registry": ns, "trivy": dict(ns, enabled=False), "database": {"internal": ns}, "redis": {"internal": ns}, "exporter": ns}
v["persistence"]["persistentVolumeClaim"]["jobservice"] = {"jobLog": {"storageClass": "ontap-san", "size": "1Gi"}}
print(json.dumps(v))
EOF
  docker cp /tmp/harbor-$CL.json $B:/tmp/harbor.json >/dev/null; rm -f /tmp/harbor-$CL.json
  apply harbor-scc
  SH "helm repo add harbor https://helm.goharbor.io >/dev/null 2>&1; helm repo update >/dev/null 2>&1
      helm upgrade --install harbor harbor/harbor --version 1.19.2 -n harbor -f /tmp/harbor.json --wait --timeout 20m | grep -E 'STATUS|REVISION'; oc -n harbor get pods --no-headers | awk '{print \"   \", \$1, \$3}'" ;;
inference)
  step "LiteLLM (> the gpu cluster through https://model.dc.lab) + APISIX + Open WebUI (worker-platform)"
  OC -n inference create configmap lab-ca --from-file=ca.crt=/dev/stdin --dry-run=client -o yaml < /root/scd-secrets/tls/ca.crt | OC apply -f - >/dev/null
  # this tenant's key for the gpu cluster: line <n> of the gpu cluster's llm-api-keys (prod 1, dev 2), never printed
  docker exec $C-bastion-gpu oc -n llm get secret llm-api-keys -o jsonpath='{.data.keys}' | base64 -d | sed -n "$([ $CL = prod ] && echo 1 || echo 2)p" | tr -d '\n' |
    OC -n inference create secret generic gpu-model-key --from-file=key=/dev/stdin --dry-run=client -o yaml | OC apply -f - >/dev/null
  apply inference
  SH "for d in litellm apisix open-webui; do oc -n inference rollout status deploy/\$d --timeout=900s | tail -1; done
      oc -n inference get pods -o wide --no-headers | awk '{print \"   \", \$1, \$3, \$7}'" ;;
isolation)
  step "isolation app: https://whoami.$APPS (the same app, the same IPs, in both clusters)"
  apply isolation; SH "oc -n isolation-check rollout status deploy/whoami --timeout=600s | tail -1" ;;
keys)
  step "one API key per tenant for the gpu cluster's models (Secret llm-api-keys: line 1 prod, line 2 dev; generated here, never printed)"
  SH "oc create ns llm --dry-run=client -o yaml | oc apply -f - >/dev/null
      oc -n llm get secret llm-api-keys >/dev/null 2>&1 || printf 'sk-prod-%s\\nsk-dev-%s\\n' \$(openssl rand -hex 20) \$(openssl rand -hex 20) | oc -n llm create secret generic llm-api-keys --from-file=keys=/dev/stdin >/dev/null
      echo \"   llm/llm-api-keys: \$(oc -n llm get secret llm-api-keys -o jsonpath={.data.keys} | base64 -d | grep -c .) keys\"" ;;
operators)
  step "OLM: Node Feature Discovery (redhat-operators) + NVIDIA Network Operator (certified-operators), default channels"
  for o in "openshift-nfd nfd redhat-operators" "nvidia-network-operator nvidia-network-operator certified-operators"; do set -- $o
    ch=$(OC get packagemanifest $2 -n openshift-marketplace -o jsonpath='{.status.defaultChannel}')
    printf '{"apiVersion":"v1","kind":"Namespace","metadata":{"name":"%s"}}\n---\n{"apiVersion":"operators.coreos.com/v1","kind":"OperatorGroup","metadata":{"name":"%s","namespace":"%s"},"spec":{"targetNamespaces":["%s"]}}\n---\n{"apiVersion":"operators.coreos.com/v1alpha1","kind":"Subscription","metadata":{"name":"%s","namespace":"%s"},"spec":{"name":"%s","channel":"%s","source":"%s","sourceNamespace":"openshift-marketplace","installPlanApproval":"Automatic"}}\n' \
      $1 $1 $1 $1 $2 $1 $2 $ch $3 | OC apply -f - | sed 's/^/   /'
  done
  SH "for ns in openshift-nfd nvidia-network-operator; do for i in \$(seq 1 90); do oc -n \$ns get csv --no-headers 2>/dev/null | grep -q Succeeded && break; sleep 10; done; oc -n \$ns get csv --no-headers | awk '{print \"   \", \$1, \$NF}'; done
      oc -n openshift-nfd get nodefeaturediscovery nfd-instance >/dev/null 2>&1 || oc -n openshift-nfd get csv -o jsonpath='{.items[0].metadata.annotations.alm-examples}' | jq '.[] | select(.kind==\"NodeFeatureDiscovery\") | .metadata.name=\"nfd-instance\" | .metadata.namespace=\"openshift-nfd\"' | oc apply -f - | sed 's/^/   /'" ;;
netop)
  step "network-operator resources: fake pci-15b3 rule, NicClusterPolicy (rdma_shared), MacvlanNetwork net-rail-0..7"
  apply gpu-netop
  SH "for i in \$(seq 1 60); do [ \"\$(oc get nicclusterpolicy nic-cluster-policy -o jsonpath={.status.state})\" = ready ] && break; sleep 10; done
      echo \"   NicClusterPolicy: \$(oc get nicclusterpolicy nic-cluster-policy -o jsonpath={.status.state})\"; oc get net-attach-def -n default --no-headers | awk '{print \"   \", \$1}' | paste -sd' '" ;;
fakegpu)
  step "run:ai fake-gpu-operator $FGO_VERSION: 8 simulated GPUs per GPU worker (nvidia.com/gpu)"
  SH "oc create ns gpu-operator --dry-run=client -o yaml | oc apply -f - >/dev/null; oc adm policy add-scc-to-group privileged system:serviceaccounts:gpu-operator >/dev/null
      helm repo add fake-gpu-operator https://runai.jfrog.io/artifactory/api/helm/fake-gpu-operator-charts-prod >/dev/null 2>&1; helm repo update >/dev/null 2>&1
      helm upgrade --install gpu-operator fake-gpu-operator/fake-gpu-operator --version $FGO_VERSION -n gpu-operator --wait --timeout 15m \
        --set topology.nodePools.default.gpuCount=8 --set topology.nodePools.default.gpuProduct=NVIDIA-H100-80GB-HBM3 --set topology.nodePools.default.gpuMemory=81559 | grep -E 'STATUS|REVISION'
      for i in \$(seq 1 60); do [ \"\$(oc get nodes -l scd/gpu=true -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\\.com/gpu}{\"\\n\"}{end}' | grep -c '^8\$')\" = 8 ] && break; sleep 10; done
      oc get nodes -l scd/gpu=true -o custom-columns=NODE:.metadata.name,GPU:.status.allocatable.nvidia\\.com/gpu --no-headers | sed 's/^/    /'" ;;
models)
  step "models on svm-gpu (ontap-nas RWX): LFM2.5 24B (Ollama registry, sha256) + Qwen2.5-0.5B (from the ai-sim image)"
  apply gpu-models
  SH "oc -n llm wait --for=condition=complete job/publish-models --timeout=5400s >/dev/null && oc -n llm logs job/publish-models -c lfm | tail -4 || { oc -n llm get pods -l job-name=publish-models; exit 1; }" ;;
serve)
  step "model API: Services + routes (llm.apps.gpu.dc.lab/<model>/), then the sharded LFM replicas and Qwen (llm-serve.sh)"
  apply gpu-serve; ./llm-serve.sh up ;;
*) say "unknown step $s"; exit 1 ;;
esac; done
