#!/bin/bash
# tenant-apps.sh <prod|dev> [step ...]: the platform and apps of tenant cluster <t>, through its own
# bastion (bastion-<t>: the installer, oc host and the only load path). The cluster IS the tenant: compact, 3 schedulable control-plane
# nodes, its node network in its tenant VRF, its own SVM. Idempotent; steps (default all, in order):
#   common     platform.sh <t> trident registry images lldp chrony (Trident on svm-<t>, the internal registry on <t>-nas, lab images, LLDP, chrony)
#   metallb    MetalLB in the tenant VRF: operator, pool 10.0.1.200-.209, eBGP multihop to the rack leaves' loopbacks; MLB_MODE=l2 for the
#              layer-2 fallback
#   secrets    generated in the cluster, never printed: MinIO root, LiteLLM master key, the API key users present to APISIX, Harbor admin and S3
#              credentials, MinIO ops user; the tenant's key for the models (line 1 prod / 2 dev of the gpu cluster's llm/llm-api-keys, copied
#              from bastion-gpu over a pipe); the lab CA (configmap lab-ca)
#   isolation  whoami in namespace whoami: https://whoami.<t>.dc.lab (BIG-IP > 10.0.1.200:8080 in the tenant's route domain)
#   s3         MinIO on <t>-san, buckets harbor + data: console https://minio.<t>.dc.lab
#   harbor     Harbor 1.19.2 (chart): https://harbor.<t>.dc.lab, blobs in s3://harbor, state on <t>-san, LoadBalancer 10.0.1.203
#   bastion    on bastion-<t> (tenant-bastion.sh up): Harbor project apps (private) + robot robot$apps+ops (push, pull), MinIO user <t>-ops
#              (bucket data read-write, nothing else), Harbor's CA; skopeo and mc of the ops user set up with them (files mode 600)
#   seed       from bastion-<t> as <t>-ops: the dataset s3://data/dataset-<t>.csv and the image apps/mc (the only load path: LAN users
#              SSH to the bastion through the PA-VM; the WAF blocks registry uploads through the BIG-IP)
#   inference  LiteLLM > https://model.dc.lab (BIG-IP model VIP, rd-gpu pool) + APISIX https://inference.<t>.dc.lab + Open WebUI https://chat.<t>.dc.lab
cd "$(dirname "$0")"; . ./lib.sh
T=${1:?prod|dev}; shift; case $T in prod|dev) ;; *) echo "usage: $0 prod|dev [step ...]"; exit 2;; esac
STEPS=${*:-common metallb secrets isolation s3 harbor bastion seed inference}
B=$(BAST $T); PLAT=platform; APPS=whoami; DOM=$T.dc.lab
OC() { OCL $T "$@"; }
SH() { SHL $T "$1"; }
apply() { python3 gen-platform.py $T $1 | OC apply -f - | sed 's/^/   /'; }
step() { say "tenant-apps $T: $*"; }
for s in $STEPS; do case $s in
common)
  step "common platform steps (platform.sh $T)"; ./platform.sh $T trident registry images lldp chrony || exit 1 ;;
metallb)
  step "MetalLB in Vrf-$([ $T = prod ] && echo Prod || echo Dev) (${MLB_MODE:-bgp})"
  ch=$(OC get packagemanifest metallb-operator -n openshift-marketplace -o jsonpath='{.status.defaultChannel}')
  printf '{"apiVersion":"v1","kind":"Namespace","metadata":{"name":"metallb-system"}}\n---\n{"apiVersion":"operators.coreos.com/v1","kind":"OperatorGroup","metadata":{"name":"metallb-system","namespace":"metallb-system"},"spec":{}}\n---\n{"apiVersion":"operators.coreos.com/v1alpha1","kind":"Subscription","metadata":{"name":"metallb-operator","namespace":"metallb-system"},"spec":{"name":"metallb-operator","channel":"%s","source":"redhat-operators","sourceNamespace":"openshift-marketplace","installPlanApproval":"Automatic"}}\n' "$ch" | OC apply -f - | sed 's/^/   /'
  SH "for i in \$(seq 1 90); do oc -n metallb-system get csv --no-headers 2>/dev/null | grep metallb | grep -q Succeeded && break; sleep 10; done; oc -n metallb-system get csv --no-headers | awk '/metallb/ {print \"   \", \$1, \$NF}'
      for i in \$(seq 1 30); do oc get crd ipaddresspools.metallb.io >/dev/null 2>&1 && break; sleep 10; done"
  if [ "${MLB_MODE:-bgp}" = l2 ]; then OC -n metallb-system delete bgpadvertisement apps bgppeer leaf-a bgppeer leaf-b --ignore-not-found >/dev/null; apply metallb-l2
  else OC -n metallb-system delete l2advertisement apps --ignore-not-found >/dev/null; apply metallb; fi
  SH "for i in \$(seq 1 30); do oc -n metallb-system get ds speaker >/dev/null 2>&1 && break; sleep 10; done; oc -n metallb-system rollout status ds/speaker --timeout=600s 2>/dev/null | tail -1" ;;
secrets)
  step "secrets (generated in the cluster, never printed)"
  SH "for n in $PLAT $APPS; do oc create ns \$n --dry-run=client -o yaml | oc apply -f - >/dev/null; done"
  SH "set -e; P=$PLAT
      oc -n \$P get secret minio-root >/dev/null 2>&1 || oc -n \$P create secret generic minio-root --from-literal=MINIO_ROOT_USER=scd-s3 --from-literal=MINIO_ROOT_PASSWORD=\$(openssl rand -hex 20) >/dev/null
      oc -n \$P get secret litellm >/dev/null 2>&1 || oc -n \$P create secret generic litellm --from-literal=master-key=sk-\$(openssl rand -hex 24) >/dev/null
      oc -n \$P get secret inference-api-key >/dev/null 2>&1 || oc -n \$P create secret generic inference-api-key --from-literal=key=\$(openssl rand -hex 24) >/dev/null
      oc -n \$P get secret minio-ops >/dev/null 2>&1 || oc -n \$P create secret generic minio-ops --from-literal=user=$T-ops --from-literal=password=\$(openssl rand -hex 20) >/dev/null
      oc -n \$P get secret harbor-admin >/dev/null 2>&1 || oc -n \$P create secret generic harbor-admin --from-literal=HARBOR_ADMIN_PASSWORD=Hb1-\$(openssl rand -hex 12) >/dev/null
      U=\$(oc -n \$P get secret minio-root -o jsonpath={.data.MINIO_ROOT_USER} | base64 -d); K=\$(oc -n \$P get secret minio-root -o jsonpath={.data.MINIO_ROOT_PASSWORD} | base64 -d)
      oc -n \$P create secret generic harbor-s3 --from-literal=REGISTRY_STORAGE_S3_ACCESSKEY=\$U --from-literal=REGISTRY_STORAGE_S3_SECRETKEY=\$K --dry-run=client -o yaml | oc apply -f - >/dev/null
      oc -n \$P create sa anyuid --dry-run=client -o yaml | oc apply -f - >/dev/null; oc adm policy add-scc-to-user anyuid -z anyuid -n \$P >/dev/null
      echo \"   \$(oc -n \$P get secret --no-headers | awk '\$1 ~ /^(minio-root|minio-ops|litellm|inference-api-key|harbor-admin|harbor-s3|gpu-model-key)\$/ {print \$1}' | paste -sd' ')\""
  # the tenant's key for the models: line 1 (prod) / 2 (dev) of the gpu cluster's llm/llm-api-keys, bastion-gpu > pipe > bastion-<t>, never printed
  OCL gpu -n llm get secret llm-api-keys -o jsonpath='{.data.keys}' | base64 -d | sed -n "$([ $T = prod ] && echo 1 || echo 2)p" | tr -d '\n' |
    OC -n $PLAT create secret generic gpu-model-key --from-file=key=/dev/stdin --dry-run=client -o yaml | OC apply -f - >/dev/null
  echo "   gpu-model-key: $(OC -n $PLAT get secret gpu-model-key -o jsonpath='{.data.key}' | base64 -d | wc -c) bytes"
  OC -n $PLAT create configmap lab-ca --from-file=ca.crt=/dev/stdin --dry-run=client -o yaml < $SECRETS/tls/ca.crt | OC apply -f - >/dev/null ;;
isolation)
  step "whoami: https://whoami.$DOM"; apply isolation; SH "oc -n $APPS rollout status deploy/whoami --timeout=600s | tail -1" ;;
s3)
  step "MinIO on $T-san"; apply s3
  SH "oc -n $PLAT rollout status deploy/minio --timeout=900s | tail -1; oc -n $PLAT wait --for=condition=complete job/minio-buckets --timeout=600s >/dev/null && oc -n $PLAT logs job/minio-buckets | tail -2" ;;
harbor)
  step "Harbor 1.19.2: https://harbor.$DOM"
  python3 - $T > /tmp/harbor-$T.json <<'EOF'
import json, sys
t = sys.argv[1]; host = "harbor.%s.dc.lab" % t
place = {}   # the cluster is the tenant; Harbor may run on any of its 3 nodes
ip = "10.0.1.203"   # Harbor's own LoadBalancer address in the tenant VRF (the same in prod and dev)
v = {"expose": {"type": "loadBalancer", "tls": {"enabled": True, "certSource": "auto", "auto": {"commonName": host}},
                "loadBalancer": {"name": "harbor", "IP": "", "ports": {"httpPort": 80, "httpsPort": 443},
                                 "annotations": {"metallb.io/loadBalancerIPs": ip}}},
     "externalURL": "https://" + host, "existingSecretAdminPassword": "harbor-admin", "existingSecretAdminPasswordKey": "HARBOR_ADMIN_PASSWORD",
     "persistence": {"enabled": True, "resourcePolicy": "keep",
                     "persistentVolumeClaim": {"jobservice": {"jobLog": {"storageClass": "%s-san" % t, "size": "1Gi"}},
                                               "database": {"storageClass": "%s-san" % t, "size": "5Gi"}, "redis": {"storageClass": "%s-san" % t, "size": "2Gi"},
                                               "trivy": {"storageClass": "%s-san" % t, "size": "5Gi"}},
                     "imageChartStorage": {"type": "s3", "disableredirect": True,
                                           "s3": {"region": "us-east-1", "bucket": "harbor", "regionendpoint": "http://minio:9000", "existingSecret": "harbor-s3", "secure": False, "v4auth": True}}},
     "portal": place, "core": place, "jobservice": place, "registry": place, "trivy": dict(place, enabled=False), "database": {"internal": place},
     "redis": {"internal": place}, "exporter": place, "nginx": place,
     # the job-log PVC is ReadWriteOnce (<t>-san): a rolling update put the new jobservice on another node while the old one held the volume
     # (Multi-Attach, the upgrade hangs); the chart's own advice for RWO volumes is Recreate
     "updateStrategy": {"type": "Recreate"}}
print(json.dumps(v))
EOF
  docker cp /tmp/harbor-$T.json $B:/tmp/harbor-$T.json >/dev/null; rm -f /tmp/harbor-$T.json
  apply harbor-scc
  SH "helm repo add harbor https://helm.goharbor.io >/dev/null 2>&1; helm repo update >/dev/null 2>&1
      helm upgrade --install harbor harbor/harbor --version 1.19.2 -n $PLAT -f /tmp/harbor-$T.json --wait --timeout 20m | grep -E 'STATUS|REVISION'; oc -n $PLAT get pods --no-headers | awk '/harbor/ {print \"   \", \$1, \$3}'
      # like every tenant LB, announced by every node of the cluster (Cluster; an earlier build patched Harbor to Local)
      oc -n $PLAT patch svc harbor --type merge -p '{\"spec\":{\"externalTrafficPolicy\":\"Cluster\"}}' | sed 's/^/   /'"
  # the next step needs the API: wait until it answers on its address in the tenant VRF
  up=; for i in $(seq 1 30); do [ "$(docker exec $C-bastion-$T curl -sk -m 5 -o /dev/null -w %{http_code} https://10.0.1.203/api/v2.0/ping)" = 200 ] && { up=1; break; }; sleep 10; done
  [ -n "$up" ] || { say "Harbor's API on 10.0.1.203 does not answer from bastion-$T"; exit 1; }
  echo "   Harbor API answers on 10.0.1.203 from bastion-$T" ;;
bastion)   # what the ops user of bastion-<t> works with (tenant-bastion.sh up made the host and the key): Harbor's CA, a robot account of
           # project apps (push + pull on its repositories, Secret harbor-robot-ops), a MinIO user with read-write on bucket data only (Secret
           # minio-ops), skopeo and mc set up in /home/<t>-ops (mode 600). Values travel by stdin only; nothing is printed
  step "bastion-$T: Harbor project apps + robot, MinIO user $T-ops, credentials into /home/$T-ops"
  BN=$C-bastion-$T; U=$T-ops; HIP=$(OC -n $PLAT get svc harbor -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  docker inspect $BN >/dev/null 2>&1 || { say "bastion-$T missing: ./tenant-bastion.sh up $T"; exit 1; }
  OC -n $PLAT get secret harbor-nginx -o jsonpath='{.data.ca\.crt}' | base64 -d | docker exec -i $BN sh -c "mkdir -p /etc/containers/certs.d/harbor.$DOM && cat > /etc/containers/certs.d/harbor.$DOM/ca.crt"
  # /etc/hosts is docker's bind mount: rewritten in place (cat >), never replaced (sed -i)
  docker exec $BN sh -c "{ grep -v ' harbor.$DOM\$' /etc/hosts; echo '$HIP harbor.$DOM'; } > /tmp/hosts && cat /tmp/hosts > /etc/hosts && rm -f /tmp/hosts"
  # the admin API from the bastion's root, straight to Harbor in the tenant VRF (no WAF), the admin password on stdin and in a 600 file for
  # the call only. Prints the robot's secret only when it was (re)made, into the Secret; with a Secret in place and the robot present, nothing
  HAVE=$(OC -n $PLAT get secret harbor-robot-ops -o name 2>/dev/null)
  OC -n $PLAT get secret harbor-admin -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' | base64 -d | docker exec -i -e HAVE="$HAVE" $BN bash -c '
    umask 077; read -r HP; printf "user = \"admin:%s\"\n" "$HP" > /root/.hk; H=https://harbor.'$DOM'/api/v2.0
    c() { curl -s -m 30 --cacert /etc/containers/certs.d/harbor.'$DOM'/ca.crt -K /root/.hk "$@"; }
    # Harbor answers before its API is ready: a robot made then comes back without a secret. Retry (2 min) until it does
    for i in $(seq 1 12); do
      [ "$(c -o /dev/null -w %{http_code} -I "$H/projects?project_name=apps")" = 200 ] || c -o /dev/null -X POST -H content-type:application/json "$H/projects" \
        -d "{\"project_name\":\"apps\",\"metadata\":{\"public\":\"false\"}}"
      pid=$(c "$H/projects/apps" | jq -r .project_id 2>/dev/null)   # project robots are listed per project only (a plain /robots shows none)
      id=$(c -G "$H/robots" --data-urlencode "q=Level=project,ProjectID=$pid" | jq -r ".[] | select(.name == \"robot\$apps+ops\") | .id" 2>/dev/null)
      [ -n "$HAVE" ] && [ -n "$id" ] && break
      [ -n "$id" ] && c -o /dev/null -X DELETE "$H/robots/$id"
      s=$(c -X POST -H content-type:application/json "$H/robots" -d "{\"name\":\"ops\",\"level\":\"project\",\"duration\":-1,\"description\":\"bastion-'$T' ops: push + pull on apps\",
        \"permissions\":[{\"kind\":\"project\",\"namespace\":\"apps\",\"access\":[{\"resource\":\"repository\",\"action\":\"push\"},{\"resource\":\"repository\",\"action\":\"pull\"}]}]}" | jq -r ".secret // empty" 2>/dev/null)
      [ -n "$s" ] && { echo "$s"; break; }; sleep 10
    done; rm -f /root/.hk' | { read -r RS; [ -z "$RS" ] || printf '%s' "$RS" | OC -n $PLAT create secret generic harbor-robot-ops --from-literal='name=robot$apps+ops' --from-file=secret=/dev/stdin --dry-run=client -o yaml | OC apply -f - >/dev/null; }
  OC -n $PLAT get secret harbor-robot-ops >/dev/null 2>&1 || { say "the Harbor robot was not created (Secret harbor-robot-ops missing)"; exit 1; }
  echo "   Harbor: project apps, robot $(OC -n $PLAT get secret harbor-robot-ops -o jsonpath='{.data.name}' | base64 -d) (Secret harbor-robot-ops)"
  # the MinIO user and its policy (Job minio-ops, re-run every time: user add sets the password from the Secret)
  OC -n $PLAT delete job minio-ops --ignore-not-found >/dev/null; apply ops
  SH "oc -n $PLAT wait --for=condition=complete job/minio-ops --timeout=600s >/dev/null && oc -n $PLAT logs job/minio-ops | sed 's/^/   /'"
  # the ops user's tools: skopeo's auth file (the robot), mc's config (alias s3 = MinIO's S3 API on its LoadBalancer address, the ops user)
  MIP=$(OC -n $PLAT get svc minio-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  { OC -n $PLAT get secret harbor-robot-ops -o jsonpath='{.data.secret}' | base64 -d; echo; OC -n $PLAT get secret minio-ops -o jsonpath='{.data.user}' | base64 -d; echo
    OC -n $PLAT get secret minio-ops -o jsonpath='{.data.password}' | base64 -d; echo; } | docker exec -i -u $U -e HOME=/home/$U $BN bash -c '
    umask 077; read -r RS; read -r MU; read -r MP; mkdir -p ~/.config/containers ~/.mc
    jq -n --arg h harbor.'$DOM' --arg a "$(printf "%s:%s" "robot\$apps+ops" "$RS" | base64 -w0)" "{auths: {(\$h): {auth: \$a}}}" > ~/.config/containers/auth.json
    jq -n --arg u "$MU" --arg p "$MP" "{version: \"10\", aliases: {s3: {url: \"http://'$MIP':9000\", accessKey: \$u, secretKey: \$p, api: \"s3v4\", path: \"auto\"}}}" > ~/.mc/config.json
    chmod 600 ~/.config/containers/auth.json ~/.mc/config.json
    echo "   $(whoami): skopeo login $(skopeo login --get-login harbor.'$DOM' 2>&1), mc alias s3 = $(mc alias list s3 --json | jq -r .URL) ($(mc ls s3/data >/dev/null 2>&1 && echo data readable || echo data NOT readable))"' ;;
seed)   # real data in each tenant's MinIO and Harbor, loaded on bastion-<t> by its ops user (tenant-apps.sh <t> bastion first)
  step "seed from bastion-$T as $T-ops: s3://data/dataset-$T.csv, apps/$SEED_IMG"
  BN=$C-bastion-$T; U=$T-ops
  python3 gen-platform.py $T dataset | docker exec -i -u $U -e HOME=/home/$U $BN sh -c "mc pipe s3/data/dataset-$T.csv >/dev/null && mc stat s3/data/dataset-$T.csv | head -3 | sed 's/^/   /'"
  # the image as an operator brings it: an archive (docker save from the lab host's image store, the c2/ image platform.sh put in the internal
  # registry), pushed by skopeo with the robot to harbor.<t>.dc.lab = Harbor's LoadBalancer address in the tenant VRF, Harbor's CA trusted
  docker save c2/$SEED_IMG | docker exec -i -u $U -e HOME=/home/$U $BN sh -c "umask 077; cat > ~/seed.tar && skopeo copy -q --retry-times 3 docker-archive:\$HOME/seed.tar docker://harbor.$DOM/apps/$SEED_IMG; rc=\$?; rm -f ~/seed.tar
    [ \$rc = 0 ] && echo \"   apps/$SEED_IMG \$(skopeo inspect --format '{{.Digest}}' docker://harbor.$DOM/apps/$SEED_IMG) (pushed by \$(whoami) on \$(hostname))\"; exit \$rc" \
    || { say "the push of apps/$SEED_IMG to harbor.$DOM failed"; exit 1; } ;;
inference)
  step "LiteLLM > https://model.dc.lab, APISIX https://inference.$DOM, Open WebUI https://chat.$DOM"; apply inference
  SH "for d in litellm apisix open-webui; do oc -n $PLAT rollout status deploy/\$d --timeout=900s | tail -1; done" ;;
*) say "unknown step $s"; exit 1 ;;
esac; done
