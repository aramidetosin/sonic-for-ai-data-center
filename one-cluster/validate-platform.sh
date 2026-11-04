#!/bin/bash
# validate-platform.sh <ocp|prod|dev>: platform checks of cluster ocp, one PASS/FAIL line each -> results/<lab>_platform-<part>_<ts>/result.txt
#   ocp        the shared platform: Trident (6 backends, 3 SVMs), the GPU stack (fake GPUs, network operator, rails), the models on ocp-nas and
#              their serving (LFM sharded over rails 3 / 6, Qwen), the model API with the tenants' keys, and a FRESH run of the DDP training job
#              (ai-train.sh: 8 ranks, gloo all-reduce on rail 1, a ring on rails 2-8)
#   prod|dev   one tenant, as its users see it from client-lan1 (through the PA-VM and the BIG-IP, lab CA): its storage on its own SVM,
#              whoami + its NFS marker, MinIO, Harbor, Open WebUI, the inference API (APISIX key > LiteLLM > the model VIP), both models
#              and its data: the image apps/mc in its Harbor (API, a pull on the LAN), its blobs in MinIO's harbor bucket, the
#              dataset s3://data/dataset-<t>.csv read back (mc, the console); the other tenant's credentials and pods read none of it
cd "$(dirname "$0")"; . ./lib.sh
T=${1:?ocp|prod|dev}; P=0; F=0; K=0; RD=$(resdir platform-$T); OUT=$RD/result.txt; CMDLOG=$PWD/$RD/commands.txt; : > $OUT; : > $CMDLOG; B=$C-bastion-ocp; CA=/root/scd-secrets/tls/ca.crt
log() { echo "$*" | tee -a $OUT; }
ok() { if [ "$2" = 0 ]; then log "PASS  $1"; P=$((P+1)); else log "FAIL  $1  ($3)"; F=$((F+1)); fi; }
want() { local got; [ -n "${CMDLOG:-}" ] && printf '$ %s\n' "$2" | redact >> "$CMDLOG"; got=$(eval "$2" 2>&1); echo "$got" | grep -q -E "$3"; ok "$1" $? "got: $(echo $got | head -c 160)"; }
known() { log "KNOWN $1  ($2)"; K=$((K+1)); }
deny() { local got; [ -n "${CMDLOG:-}" ] && printf '$ %s\n' "$2" | redact >> "$CMDLOG"; got=$(eval "$2" 2>&1); if echo "$got" | grep -q -E "$3"; then ok "$1" 1 "reached: $(echo $got | head -c 90)"; else ok "$1" 0; fi; }
OC() { docker exec $B oc "$@" 2>&1; }
# mrun <tenant> <sh cmd>: cmd now, in a one-shot copy of the tenant's minio-buckets Job (same image, node placement and credentials Secret),
# after `mc alias set s3 http://minio:9000`; its output. Never the old Job's logs: a node drain removes a finished Job's pod.
mrun() { local n=minio-q-$(date +%s%N | cut -c1-13)
  OC -n $1-platform get job minio-buckets -o json | N=$n CMD="$2" python3 -c 'import json, os, sys
j = json.load(sys.stdin); sp = j["spec"]["template"]["spec"]; c = sp["containers"][0]
c["command"] = ["sh", "-c", "export HOME=/tmp; mc alias set s3 http://minio:9000 \"$MINIO_ROOT_USER\" \"$MINIO_ROOT_PASSWORD\" >/dev/null && " + os.environ["CMD"]]
print(json.dumps({"apiVersion": "batch/v1", "kind": "Job", "metadata": {"name": os.environ["N"], "namespace": j["metadata"]["namespace"]},
                  "spec": {"backoffLimit": 3, "ttlSecondsAfterFinished": 600, "template": {"spec": sp}}}))' | docker exec -i $B oc create -f - >/dev/null 2>&1
  OC -n $1-platform wait --for=condition=complete job/$n --timeout=180s >/dev/null; OC -n $1-platform logs job/$n; }
mls() { mrun $1 "mc ls s3"; }
# the tenant's Harbor admin password, into the environment of one command (HP=$(hpw t) lan_harbor|lan_skopeo ..., lib.sh); never printed
hpw() { OC -n $1-platform get secret harbor-admin -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' | base64 -d; }
mpw() { OC -n $1-platform get secret minio-root -o jsonpath='{.data.MINIO_ROOT_PASSWORD}' | base64 -d; }
HAPI() { HP="$(hpw $1)" lan_harbor "printf 'user = \"admin:%s\"\n' \"\$HP\" | curl -s -m 30 --cacert /tmp/lab-ca.crt -K - $2"; }   # <whose admin> <curl args>
# MCON <whose root password> <tenant> [object]: log in to the tenant's MinIO console through the BIG-IP as scd-s3; with an object, then
# download it from bucket data with that session (this console takes the object name as is, not base64). Prints "login <code>" [and the object]; the password and the session stay in client-lan1
MCON() { local get=""; [ -n "${3:-}" ] && get="; echo; curl -s -m 30 --cacert /tmp/lab-ca.crt -b /tmp/mcj.\$\$ 'https://minio.$2.dc.lab/api/v1/buckets/data/objects/download?prefix=$3'"
  MP="$(mpw $1)" docker exec -e MP $C-client-lan1 sh -c "printf '{\"accessKey\":\"scd-s3\",\"secretKey\":\"%s\"}' \"\$MP\" | curl -s -m 30 --cacert /tmp/lab-ca.crt -c /tmp/mcj.\$\$ -o /dev/null -w 'login %{http_code}' -H content-type:application/json -d @- https://minio.$2.dc.lab/api/v1/login$get; rm -f /tmp/mcj.\$\$" 2>&1; }
# the tenant bastions. BX <t> <cmd>: as <t>-ops on bastion-<t> (its skopeo and mc, loaded by tenant-apps.sh bastion)
BX() { docker exec -u $1-ops -e HOME=/home/$1-ops $C-bastion-$1 sh -c "$2" 2>&1; }
# SSHL <whose key> <user@address> <cmd>: ssh from client-lan1's network (the bastion image's ssh client; client-lan1 has none), key only
SSHL() { local o; o=$(docker run --rm --network container:$C-client-lan1 -v /root/scd-secrets/bastion/$1-ops:/k:ro --entrypoint ssh scd/tenant-bastion:1 -i /k \
    -o BatchMode=yes -o PasswordAuthentication=no -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -o LogLevel=ERROR "$2" "$3" 2>&1)
  echo "$o"; echo "$o" | grep -qiE "timed out|refused|no route" && echo "(no SSH answer from ${2#*@}:22: PA-VM SSH publish not committed? ./pa-load.sh)"; }
# HTAGDEL <t> <tag>: delete a tag of apps/mc as Harbor's admin, from bastion-<t>'s root straight to Harbor (the admin password on stdin only)
HTAGDEL() { hpw $1 | docker exec -i $C-bastion-$1 bash -c 'read -r HP; printf "user = \"admin:%s\"\n" "$HP" | curl -s -m 30 --cacert /etc/containers/certs.d/harbor.'$1'.dc.lab/ca.crt -K - -o /dev/null -w %{http_code} -X DELETE https://harbor.'$1'.dc.lab/api/v2.0/projects/apps/repositories/mc/artifacts/'$2'/tags/'$2 2>&1; }
# WAFPUSH <t>: a LAN user with the tenant's robot tries a registry upload through the BIG-IP: token (GET), upload session (POST, Location), then
# the blob (PATCH, 2 KiB): prints "POST Location" and what the WAF answered. The robot's secret goes in by environment and a 600 file only
WAFPUSH() { HP="$(rpw $1)" lan_harbor 'umask 077; printf "user = \"robot\$apps+ops:%s\"\n" "$HP" > /tmp/rk.$$; R=harbor.'$1'.dc.lab
  TK=$(curl -s -m 20 --cacert /tmp/lab-ca.crt -K /tmp/rk.$$ "https://$R/service/token?service=harbor-registry&scope=repository:apps/mc:push,pull" | jq -r .token); rm -f /tmp/rk.$$
  L=$(curl -s -m 20 --cacert /tmp/lab-ca.crt -D- -o /dev/null -X POST -H "Authorization: Bearer $TK" https://$R/v2/apps/mc/blobs/uploads/ | tr -d "\r" | sed -n "s/^[Ll]ocation: //p")
  echo POST ${L:+Location}; [ -n "$L" ] || exit 0
  head -c 2048 /dev/urandom | curl -s -m 20 --cacert /tmp/lab-ca.crt -X PATCH -H "Authorization: Bearer $TK" -H content-type:application/octet-stream --data-binary @- "$L" | grep -oE "Request Rejected|support ID is: [0-9]+"'; }
# MDENY <t>: as <t>-ops, write / list / read the harbor bucket (each: MinIO's refusal, or ALLOWED), then the buckets it sees
MDENY() { BX $1 'r() { if "$@" >/dev/null 2>/tmp/e; then echo ALLOWED; else grep -oE "Insufficient permissions|Access Denied" /tmp/e | head -1; fi; }
  echo x > /tmp/x; r mc cp /tmp/x s3/harbor/check.txt; r mc ls s3/harbor; r mc cat s3/harbor/docker/registry/v2/blobs; rm -f /tmp/x /tmp/e
  mc ls s3 | awk "{print \$NF}" | paste -sd, -'; }
rpw() { OC -n $1-platform get secret harbor-robot-ops -o jsonpath='{.data.secret}' | base64 -d; }
SH() { docker exec $B bash -c "$1" 2>&1; }
SSHC() { ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8 core@"$(mip $1)" "$2" </dev/null 2>&1; }
# a request from client-lan1 with the tenant's API key in its environment (read from the cluster, never printed)
key() { OC -n $T-platform get secret inference-api-key -o jsonpath='{.data.key}' | base64 -d; }
CK() { docker exec -e K="$(key)" $C-client-lan1 sh -c "$1" 2>&1; }
chat() {   # <model> <max_tokens> <prompt>: the answer's text (content), or the error
  CK "curl -s -m 600 --cacert /tmp/lab-ca.crt -H \"apikey: \$K\" -H content-type:application/json https://inference.$T.dc.lab/models/$1/proxy/v1/chat/completions -d '{\"model\":\"$1\",\"max_tokens\":$2,\"messages\":[{\"role\":\"user\",\"content\":\"$3\"}]}'" \
    | jq -r '.choices[0].message.content // .error.message // "no answer"' 2>&1 | tr '\n' ' ' | head -c 300; }
if [ $T = ocp ]; then
  log "== the shared platform of cluster ocp"
  want "Trident: 6 backends Bound (ocp / prod / dev, san + nas)" "OC -n trident get tbc --no-headers | awk '\$4==\"Bound\" && \$5==\"Success\"' | wc -l" "^6$"
  want "6 storage classes, each tied to one SVM's zone (WaitForFirstConsumer)" "OC get sc -o jsonpath='{range .items[*]}{.metadata.name}:{.volumeBindingMode}{\"\\n\"}{end}' | grep -cE '^(ocp|prod|dev)-(san|nas):WaitForFirstConsumer$'" "^6$"
  want "every PVC in the cluster Bound" "OC get pvc -A --no-headers | awk '\$3!=\"Bound\"' | wc -l" "^0$"
  want "the models and the registry on svm-ocp (ocp-nas)" "OC get pvc -n llm models -o jsonpath={.spec.storageClassName}; echo; OC -n openshift-image-registry get pvc image-registry-storage -o jsonpath={.spec.storageClassName}" "ocp-nas.ocp-nas|^ocp-nas"
  want "ONTAP: svm-ocp holds the models and registry volumes" "ONTAP 'volume show -vserver svm-ocp -volume trident_* -fields vserver' | grep -c '^svm-ocp '" "^[2-9]$"
  want "fake-gpu-operator: 8 simulated GPUs on each of 8 GPU workers" "OC get nodes -l scd/gpu=true -o jsonpath='{range .items[*]}{.status.capacity.nvidia\\.com/gpu}{\"\\n\"}{end}' | sort | uniq -c | tr -s ' '" "^ ?8 8$"
  want "NVIDIA Network Operator: NicClusterPolicy ready" "OC get nicclusterpolicy nic-cluster-policy -o jsonpath={.status.state}" "^ready$"
  want "8 MacvlanNetworks net-rail-0..7, one per rail" "OC get macvlannetwork --no-headers | awk '\$1 ~ /^net-rail-[0-7]$/' | wc -l" "^8$"
  want "NFD labels the 8 GPU workers pci-15b3 (the fake ConnectX rule); NicClusterPolicy ready" "{ OC get nodes -l feature.node.kubernetes.io/pci-15b3.present=true --no-headers | wc -l; OC get nicclusterpolicy nic-cluster-policy -o jsonpath={.status.state}; echo; } | paste -sd' '" "^8 ready ?$"
  want "rdma/rdma-shared: 63 on each of the 8 GPU workers (the generic device plugin: /dev/infiniband)" "OC get nodes -l scd/gpu=true -o jsonpath='{range .items[*]}{.status.allocatable.rdma/rdma-shared}{\"\\n\"}{end}' | sort | uniq -c | tr -s ' '" "^ ?8 63$"
  log "== RDMA between pods over a rail (rdma-probe.sh: RoCEv2 on SoftRoCE, rail 1, gpu-worker2 <> gpu-worker3)"
  PR=$(mktemp); RP=$(docker inspect -f '{{.State.Pid}}' $C-rail-leaf1)
  CAP=$RD/rdma-rail-leaf1-eth6.txt   # the captured frames as text, in the result directory
  ( nsenter -t $RP -n timeout 70 tcpdump -n -v -i eth6 -c 5000 "udp port 4791" 2>/dev/null > $CAP; grep -c "UDP" $CAP > $PR.cnt ) &
  ./rdma-probe.sh run 1 > $PR 2>&1; wait; printf '$ ./rdma-probe.sh run 1   (with tcpdump -n -v on rail-leaf1 eth6, udp 4791 -> rdma-rail-leaf1-eth6.txt)\n' >> "$CMDLOG"
  want "the probe pods hold rdma/rdma-shared under SCC scd-rdma-hostnet (no privileged pod) and see the 8 rail devices" "grep -E 'scc |rdma-a sees|^8 ;' $PR | tr '\\n' ' '" "scc scd-rdma-hostnet.*uverbs7 8 ;"
  want "RDMA write over RoCEv2 completed, both sides agree (64 KiB x iterations, link type Ethernet)" "{ grep -c 'Link type       : Ethernet' $PR; grep -E '^ 65536' $PR | awk '{print \$2}' | sort -u | wc -l; grep -E '^ 65536' $PR | awk '\$2 > 100' | wc -l; } | paste -sd' '" "^1 1 2$"
  want "rail-leaf1 carried it: RoCEv2 (UDP 4791) frames on gpu-worker2's rail-1 port" "cat $PR.cnt" "^[0-9]{3,}$"
  want "the RoCEv2 frames carry DSCP 24 (tos 0x60, the rails' lossless TC3): every captured frame" "echo \$(grep -c 'tos 0x60' $CAP) \$(grep -c 'tos 0x' $CAP)" "^([0-9]{3,}) \\1$"
  cp $PR $RD/rdma-probe.txt; rm -f $PR $PR.cnt; ./rdma-probe.sh clean   # the probe output, in the result directory
  known "pods on a rail macvlan cannot receive RoCEv2 on SoftRoCE" "the rxe driver of RHEL 9's 5.14 kernel listens on UDP 4791 only in the host's network namespace: a macvlan pod sets up its queue pair but never receives the data; RDMA pods here use the host network and the node's rail address (SCC scd-rdma-hostnet). With ConnectX HCAs the macvlan path (SCC scd-rdma) is the design"
  want "SoftRoCE: an rxe device per rail on gpu-worker1 (8)" "SSHC ocp-gpu-worker1 'ls /sys/class/infiniband 2>/dev/null' | grep -c rxe" "^8$"
  want "the models fetched and checked (publish-models Complete)" "OC -n llm get job publish-models -o jsonpath={.status.succeeded}" "^1$"
  want "LFM2.5 24B: 2 replicas, each a server and 3 RPC workers, all Ready" "{ OC -n llm get pod -l app=llm-rpc --no-headers | grep -c '1/1 *Running'; OC -n llm get pod -l model=lfm2.5-24b --no-headers | grep -c '1/1 *Running'; } | paste -sd' '" "^6 2$"
  for x in a:3:2:gpu-worker1 b:6:5:gpu-worker5; do IFS=: read -r r rail net srv <<<"$x"
    want "replica $r: llama-server on $srv, its RPC workers reached over rail $rail (net-rail-$net)" "OC -n llm get pod llm-$r -o jsonpath='{.spec.nodeName} {.spec.containers[0].command}' | grep -o '^[a-z0-9-]*\\|172\\.16\\.$rail\\.[0-9]*:50052' | paste -sd' '" "^$srv 172\.16\.$rail\.[0-9]+:50052 172\.16\.$rail\.[0-9]+:50052 172\.16\.$rail\.[0-9]+:50052$"
  done
  want "LFM thinks at most 512 tokens, then answers" "OC -n llm get pod -l model=lfm2.5-24b -o jsonpath='{range .items[*]}{.spec.containers[0].command}{\"\\n\"}{end}' | grep -c '\"--reasoning-budget\",\"512\"'" "^2$"
  want "Qwen2.5-0.5B: 2 servers Ready (gpu-worker1, gpu-worker5)" "OC -n llm get pod -l model=qwen2.5-0.5b -o jsonpath='{range .items[*]}{.spec.nodeName}={.status.containerStatuses[0].ready}{\" \"}{end}'" "gpu-worker1=true gpu-worker5=true|gpu-worker5=true gpu-worker1=true"
  want "the model API endpoints: 2 for LFM, 2 for Qwen" "OC -n llm get endpoints llm-lfm llm-qwen 2>/dev/null -o jsonpath='{range .items[*]}{.metadata.name}={range .subsets[*].addresses[*]}x{end} {end}'" "llm-lfm=xx llm-qwen=xx"
  want "the model API /health answers (the BIG-IP monitor's path)" "docker exec $B curl -sk -m 10 https://llm.apps.ocp.dc.lab/health" "ok"
  want "the model API refuses a request without a tenant key (401)" "docker exec $B curl -sk -m 15 -o /dev/null -w %{http_code} https://llm.apps.ocp.dc.lab/lfm2.5-24b/v1/models" "^401$"
  log "== the training workload: a fresh DDP run (ai-train.sh)"
  TL=$(mktemp -d); ./ai-train.sh run > $TL/run.txt 2>&1; ./ai-train.sh logs $TL
  printf '$ ./ai-train.sh run; ./ai-train.sh logs <dir>\n' >> "$CMDLOG"
  res() { grep -h "RESULT " $TL/rank-$1.log 2>/dev/null | sed 's/.*RESULT //' | tail -1; }
  jf() { res $1 | python3 -c 'import json,sys; t=sys.stdin.read().strip(); print(json.loads(t).get(sys.argv[1], "") if t else "")' $2; }
  want "the Indexed Job completed: 8 of 8 ranks" "OC -n ai-train get job ddp -o jsonpath='{.status.succeeded}/{.spec.completions}'" "^8/8$"
  want "one rank per GPU worker (8 different nodes, gpu-worker1..8)" "OC -n ai-train get pod -l job-name=ddp -o jsonpath='{range .items[*]}{.spec.nodeName}{\"\\n\"}{end}' | grep '^gpu-worker' | sort -u | wc -l" "^8$"
  want "each rank held 4 simulated GPUs beside the model servers" "OC -n ai-train get pod -l job-name=ddp -o jsonpath='{range .items[*]}{.spec.containers[0].resources.requests.nvidia\\.com/gpu}{\"\\n\"}{end}' | sort | uniq -c | tr -s ' '" "^ ?8 4$"
  want "every rank ran all steps in a world of 8" "for i in 0 1 2 3 4 5 6 7; do echo \$(jf \$i steps)/\$(jf \$i world); done | sort | uniq -c | tr -s ' '" "^ ?8 30/8$"
  want "the gradient all-reduce kept the 8 ranks identical (one weight checksum)" "for i in 0 1 2 3 4 5 6 7; do jf \$i weights_sha; done | sort -u | grep -c ." "^1$"
  want "the loss fell on every rank" "for i in 0 1 2 3 4 5 6 7; do awk -v a=\$(jf \$i first_loss) -v b=\$(jf \$i last_loss) 'BEGIN {print (b < a) ? \"down\" : \"up\"}'; done | sort | uniq -c | tr -s ' '" "^ ?8 down$"
  want "gloo ran over net1, each rank's rail-1 address (172.16.1.0/24)" "{ grep -h 'rail addresses' $TL/rank-*.log | grep -oE 'net1 172\\.16\\.1\\.[0-9]+' | wc -l; grep -h 'process group up' $TL/rank-*.log | grep -c 'over net1'; } | paste -sd' '" "^8 8$"
  want "the gradients crossed rail 1: every rank sent and received more than 5 MB on net1" "for i in 0 1 2 3 4 5 6 7; do echo \$(jf \$i rail_tx_mb) \$(jf \$i rail_rx_mb); done | awk '\$1 > 5 && \$2 > 5' | wc -l" "^8$"
  want "every rank read its shard from the shared volume (ocp-nas, svm-ocp)" "{ grep -h 'shard loaded from the shared volume' $TL/rank-*.log | wc -l; OC -n ai-train get pvc train-data -o jsonpath={.spec.storageClassName}; echo; } | paste -sd' '" "^8 ocp-nas ?$"
  want "rank 0 wrote a checkpoint per epoch (3)" "grep -c 'checkpoint written to the shared volume' $TL/rank-0.log" "^3$"
  want "the collective ring on rails 2-8: 56 flows completed (8 ranks x 7 rails)" "grep -h '^RING' $TL/rank-*.log | grep -c receiver" "^56$"
  want "each ring flow stayed on its own rail (rail r: 172.16.r.x > 172.16.r.y)" "grep -h '^RING' $TL/rank-*.log | grep -cE 'rail ([2-8]): rank [0-7] 172\\.16\\.\\1\\.[0-9]+ > rank [0-7] 172\\.16\\.\\1\\.[0-9]+'" "^56$"
  mkdir -p $RD/ai-train; cp $TL/* $RD/ai-train/; rm -rf $TL   # the run's logs, in the result directory
else
  O=$([ $T = prod ] && echo dev || echo prod)
  docker cp $CA $C-client-lan1:/tmp/lab-ca.crt >/dev/null 2>&1
  log "== tenant $T (namespaces $T-apps, $T-platform), from client-lan1 through the PA-VM and the BIG-IP"
  want "every $T PVC Bound on a $T storage class" "OC get pvc -A --no-headers | awk '\$1 ~ /^$T-/ {print \$3, \$7}' | sort | uniq -c | tr -s ' ' | paste -sd' '" "^ ?[0-9]+ Bound $T-(san|nas)( +[0-9]+ Bound $T-(san|nas))*$"
  want "ONTAP: the $T volumes live on svm-$T only (none of $O's)" "{ n=\$(OC get pv -o jsonpath='{range .items[*]}{.spec.claimRef.namespace} {.spec.csi.volumeAttributes.internalName}{\"\\n\"}{end}' | awk '\$1 ~ /^$T-/ {print \$2}'); echo \"\$n\" | wc -l; for v in \$n; do ONTAP \"volume show -volume \$v -fields vserver\" | awk -v v=\$v '\$2==v {print \$1}'; done | sort | uniq -c | tr -s ' '; } | paste -sd' ' | tr -s ' '" "^([0-9]+) \\1 svm-$T$"
  want "whoami.$T.dc.lab answers as tenant $T, certificate from the lab CA" "docker exec $C-client-lan1 curl -s -m 15 --cacert /tmp/lab-ca.crt https://whoami.$T.dc.lab/" "^tenant $T "
  want "whoami's RWX volume holds $T's marker, written on svm-$T" "docker exec $C-client-lan1 curl -s -m 15 --cacert /tmp/lab-ca.crt https://whoami.$T.dc.lab/data/marker.txt" "written by $T on svm-$T"
  want "MinIO console answers (minio.$T.dc.lab)" "docker exec $C-client-lan1 curl -s -m 15 --cacert /tmp/lab-ca.crt -o /dev/null -w %{http_code} https://minio.$T.dc.lab/" "^200$"
  want "MinIO console API answers through the WAF (/api/v1/session: MinIO's own 403 JSON, not a block page)" "docker exec $C-client-lan1 curl -s -m 15 --cacert /tmp/lab-ca.crt -w ' %{http_code}' https://minio.$T.dc.lab/api/v1/session" "invalid session"
  want "MinIO holds Harbor's bucket (mc ls, asked now)" "mls $T" "harbor/"
  want "Harbor answers (harbor.$T.dc.lab /api/v2.0/ping)" "docker exec $C-client-lan1 curl -s -m 15 --cacert /tmp/lab-ca.crt https://harbor.$T.dc.lab/api/v2.0/ping" "^Pong$"
  want "Harbor: every component Ready (5 deployments, 2 statefulsets)" "OC -n $T-platform get deploy,sts -l app=harbor -o jsonpath='{range .items[*]}{.status.readyReplicas}{\" \"}{end}'" "^(1 ){7}$"
  want "Harbor: the components on RWO volumes (jobservice, registry) update by Recreate" "OC -n $T-platform get deploy harbor-jobservice harbor-registry -o jsonpath='{range .items[*]}{.spec.strategy.type}{\" \"}{end}'" "^Recreate Recreate $"
  log "== the tenant's data: an image in its Harbor, its layers in its MinIO, a dataset in its MinIO; the other tenant reads none of it"
  R=harbor.$T.dc.lab; IM=apps/$SEED_IMG; DS=dataset-$T.csv
  HD=$(HAPI $T "https://$R/api/v2.0/projects/apps/repositories/${SEED_IMG%%:*}/artifacts/${SEED_IMG#*:}" | jq -r '.digest // empty')
  want "Harbor lists $T's image $IM (API, $T's admin, through the BIG-IP)" "HAPI $T 'https://$R/api/v2.0/projects/apps/repositories/${SEED_IMG%%:*}/artifacts' | jq -r '.[] | .digest + \" \" + (.tags[]?.name)'" "^sha256:[0-9a-f]{64} ${SEED_IMG#*:}$"
  want "the image pulls on the LAN from $R: manifest and every blob fetched, digests verified (skopeo copy, client-lan1), manifest = Harbor's digest" \
    "HP=\"\$(hpw $T)\" lan_skopeo $R 'skopeo copy -q --authfile /tmp/auth.json --src-cert-dir /certs docker://$R/$IM dir:/tmp/i && echo \$(ls /tmp/i | grep -cvE \"^(manifest.json|version)\$\") blobs sha256:\$(sha256sum /tmp/i/manifest.json | cut -c1-64)'" "^[1-9][0-9]* blobs ${HD:-none}$"
  DG=$(HP="$(hpw $T)" lan_skopeo $R "skopeo inspect --raw --authfile /tmp/auth.json --cert-dir /certs docker://$R/$IM" | jq -r '.config.digest, .layers[].digest' 2>/dev/null)
  want "MinIO's harbor bucket holds that image now: Harbor's manifest, config and every layer under docker/registry/v2/blobs (Harbor > S3 > svm-$T)" \
    "L=\$(mrun $T 'mc ls -r s3/harbor/docker/registry/v2/blobs/sha256/'); n=0; for d in ${HD:-none} $(echo $DG); do echo \"\$L\" | grep -q \"/\${d#sha256:}/data\$\" && n=\$((n+1)); done; echo \"\$n of $(echo ${HD:-none} $DG | wc -w)\"" "^([3-9]|[1-9][0-9]+) of \\1$"
  want "the dataset reads back from $T's MinIO, line for line as seeded (mc cat s3/data/$DS, asked now)" \
    "G=\$(mrun $T 'mc cat s3/data/$DS'); echo \"\$(echo \"\$G\" | paste -sd' ') \$([ \"\$G\" = \"\$(python3 gen-platform.py $T-dataset)\" ] && echo same || echo differs)\"" "^tenant,vrf,udn,svm,bucket $T,.*,svm-$T,data same$"
  want "the dataset downloads on the LAN through $T's MinIO console (login as $T's user, the BIG-IP, the WAF)" "MCON $T $T $DS | paste -sd' '" "^login 204 tenant,vrf,udn,svm,bucket $T,.*,svm-$T,data$"
  want "$O's Harbor admin password is refused by $R (API 401)" "HAPI $O '-o /dev/null -w %{http_code} https://$R/api/v2.0/projects/apps/repositories'" "^401$"
  want "$O's Harbor admin cannot pull $T's image (registry: unauthorized)" "HP=\"\$(hpw $O)\" lan_skopeo $R 'skopeo inspect --authfile /tmp/auth.json --cert-dir /certs docker://$R/$IM' | tail -1" "unauthorized|authentication required"
  want "$T's project is private: no anonymous pull" "lan_skopeo $R 'skopeo inspect --cert-dir /certs docker://$R/$IM' | tail -1" "unauthorized|authentication required|requested access to the resource is denied"
  want "$O's MinIO password is refused by $T's MinIO console (login 401 through the BIG-IP)" "MCON $O $T" "^login 401$"
  want "a $O pod with $O's MinIO credentials cannot reach $T's MinIO (minio.$T-platform.svc:9000, across the UDNs): $DS stays unread" \
    "mrun $O 'export MC_HOST_x=\"http://\$MINIO_ROOT_USER:\$MINIO_ROOT_PASSWORD@minio.$T-platform.svc:9000\"; timeout 25 mc cat x/data/$DS >/tmp/o 2>/tmp/e; echo rc=\$? \$(wc -c </tmp/o) bytes; e=\$(head -c 150 /tmp/e); echo \"\${e//\"\$MINIO_ROOT_PASSWORD\"/<redacted>}\"' | paste -sd' '" "^rc=[1-9][0-9]* 0 bytes"
  log "== loading goes through bastion-$T only (SSH from the LAN through the PA-VM; skopeo with the robot, mc with the ops user)"
  declare -A NET3=([prod]=10.10 [dev]=10.20); PUB=$([ $T = prod ] && echo 192.168.100.142 || echo 192.168.100.143); ON=$([ $O = prod ] && echo 10.10 || echo 10.20); TS=$(date +%s)
  want "LAN > bastion-$T: ssh $T-ops@$PUB with $T's key runs on bastion-$T (PA-VM DNAT $PUB:22 > ${NET3[$T]}.2.11)" "SSHL $T $T-ops@$PUB hostname" "^bastion-$T$"
  want "LAN > bastion-$T refuses $O's key for $T-ops (publickey only)" "SSHL $O $T-ops@$PUB hostname" "Permission denied \(publickey\)"
  want "bastion-$T's sshd: keys only, no root, only $T-ops (sshd -T)" "docker exec $C-bastion-$T sshd -T | grep -E '^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin|allowusers) ' | sort | paste -sd' '" "^allowusers $T-ops kbdinteractiveauthentication no passwordauthentication no permitrootlogin no$"
  want "bastion-$T as $T-ops: skopeo pushes tag check-$TS with the robot (harbor.$T.dc.lab = Harbor in the tenant VRF, its CA); Harbor's API shows it on the image's digest; deleted after" \
    "{ BX $T 'skopeo copy -q docker://harbor.$T.dc.lab/$IM docker://harbor.$T.dc.lab/apps/mc:check-$TS && echo pushed by \$(whoami) as \$(skopeo login --get-login harbor.$T.dc.lab)'; HAPI $T 'https://$R/api/v2.0/projects/apps/repositories/mc/artifacts/check-$TS' | jq -r '.digest // .errors[0].message'; echo deleted \$(HTAGDEL $T check-$TS); } | paste -sd' '" "^pushed by $T-ops as robot\\\$apps\+ops ${HD:-none} deleted 200$"
  want "bastion-$T as $T-ops: mc writes an object into s3/data (MinIO's S3 API in the tenant VRF), reads it back, removes it" \
    "BX $T 'K=check-$TS.txt; echo bastion-$T $TS | mc pipe s3/data/\$K >/dev/null && mc cat s3/data/\$K && mc rm s3/data/\$K >/dev/null && echo removed; mc stat s3/data/\$K >/dev/null 2>&1 || echo gone' | paste -sd' '" "^bastion-$T $TS removed gone$"
  want "$T-ops cannot write, list or read MinIO's harbor bucket, and sees no bucket but data (policy data-rw)" "MDENY $T | paste -sd' '" "^(Insufficient permissions|Access Denied) (Insufficient permissions|Access Denied) (Insufficient permissions|Access Denied) data/$"
  want "bastion-$T cannot reach $O's Harbor ($ON.1.203:443), MinIO ($ON.1.204:9000, :9001) or bastion ($ON.2.11:22): no connection" \
    "docker exec $C-bastion-$T sh -c 'for u in https://$ON.1.203/ http://$ON.1.204:9000/ http://$ON.1.204:9001/ telnet://$ON.2.11:22; do curl -sk -m 6 -o /dev/null -w \"%{http_code}:%{exitcode} \" \$u </dev/null; done'" "^000:(7|28) 000:(7|28) 000:(7|28) 000:(7|28) ?$"
  want "LAN > harbor.$T.dc.lab through the BIG-IP: a registry upload with the robot is refused by the WAF (block page, support ID)" "WAFPUSH $T | paste -sd' '" "^POST Location Request Rejected support ID is: [0-9]+$"
  want "Open WebUI healthy (chat.$T.dc.lab /health)" "docker exec $C-client-lan1 curl -s -m 15 --cacert /tmp/lab-ca.crt -o /dev/null -w %{http_code} https://chat.$T.dc.lab/health" "^200$"
  want "LiteLLM: 2 replicas Ready, the token-floor hook loaded" "OC -n $T-platform get deploy litellm -o jsonpath={.status.readyReplicas}; echo; OC -n $T-platform get cm litellm -o jsonpath='{.data.config\\.yaml}' | grep -o min_tokens.proxy_handler_instance" "^2.min_tokens|2 min_tokens|min_tokens"
  want "the inference API lists both models (APISIX > LiteLLM)" "CK 'curl -s -m 20 --cacert /tmp/lab-ca.crt -H \"apikey: \$K\" https://inference.$T.dc.lab/models/lfm2.5-24b/proxy/v1/models' | jq -r '.data[].id' | sort | paste -sd' '" "lfm2.5-24b qwen2.5-0.5b"
  want "APISIX refuses a request without the key (401)" "docker exec $C-client-lan1 curl -s -m 20 --cacert /tmp/lab-ca.crt -o /dev/null -w %{http_code} https://inference.$T.dc.lab/models/lfm2.5-24b/proxy/v1/models" "^401$"
  want "LFM answers through APISIX > LiteLLM > model.dc.lab (the BIG-IP model VIP) > the GPU workers" "chat lfm2.5-24b 2048 'Reply with the single word: ready'" "[Rr]eady"
  want "LFM still answers when the client asks for 48 tokens (LiteLLM raises it to 1024)" "chat lfm2.5-24b 48 'Reply with the single word: ready'" "[Rr]eady"
  want "Qwen answers through the same path (2 + 3)" "chat qwen2.5-0.5b 32 'What is 2 + 3? Answer with the number only.'" "\\b5\\b|five"
fi
log ""; log "RESULT: $P passed, $F failed, $K known ($RD)"
[ $F = 0 ]
