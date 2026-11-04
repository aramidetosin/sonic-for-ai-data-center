#!/bin/bash
# llm-serve.sh [up|restart|status]: the models on the GPU workers of cluster ocp (namespace llm), served for both tenants through the BIG-IP
# model VIP.
#   LFM2.5 24B, sharded over the rails (llama.cpp RPC):
#     replica A  llama-server on gpu-worker1, ggml-rpc-server on gpu-worker2 3 4, over rail 3 (net-rail-2)
#     replica B  llama-server on gpu-worker5, ggml-rpc-server on gpu-worker6 7 8, over rail 6 (net-rail-5)
#   Qwen2.5-0.5B: one llama-server on gpu-worker1 and one on gpu-worker5 (no sharding: it fits one node)
#   LFM2.5 is a reasoning model: thinking is capped at 512 tokens (--reasoning-budget), then it must answer
#   GPU pool split: an RPC worker requests 4 of its node's 8 simulated GPUs, a server and a Qwen 2 each; the other 4 per node are training's. Services llm-lfm / llm-qwen, routes https://llm.apps.ocp.dc.lab/<model>/
#   (gen-platform.py gpu-serve). The servers accept the tenants' keys only (Secret llm-api-keys, one line per tenant, never printed).
#   up       nothing to do when both LFM replicas serve with the rail addresses their workers hold NOW; otherwise (re)deploy
#   restart  redeploy from scratch
#   status   pods, endpoints, routes
set -u
cd "$(dirname "$0")"; . ./lib.sh
MODE=${1:-up}; NS=llm; B=$C-bastion-ocp; IMG=image-registry.openshift-image-registry.svc:5000/scd-images/llm:2
LFM=lfm2.5-24b-q4_k_m.gguf; QWEN=qwen2.5-0.5b-instruct-q4_k_m.gguf
declare -A SRV=([a]=gpu-worker1 [b]=gpu-worker5) RAIL=([a]=3 [b]=6) RPCN=([a]="gpu-worker2 gpu-worker3 gpu-worker4" [b]="gpu-worker6 gpu-worker7 gpu-worker8")
OC() { docker exec -i $B oc "$@"; }
railip() { OC -n $NS get pod $1 -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}' 2>/dev/null | python3 -c 'import json, sys
try: print(next(n["ips"][0] for n in json.load(sys.stdin) if n.get("interface") == "net1"))
except Exception: pass'; }
rpcs() { local r k=0 ips=""; for n in ${RPCN[$1]}; do k=$((k + 1)); ips+="$(railip rpc-$1$k):50052,"; done; echo "${ips%,}"; }
serving() { OC -n $NS get endpoints llm-lfm -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{"\n"}{end}' 2>/dev/null | grep -c .; }
if [ "$MODE" = status ]; then OC -n $NS get pods -o wide 2>&1 | cut -c1-140; OC -n $NS get endpoints,routes 2>&1 | cut -c1-160; exit 0; fi
if [ "$MODE" = up ] && [ "$(serving)" = 2 ]; then ok=1
  for x in a b; do OC -n $NS get pod llm-$x -o jsonpath='{.spec.containers[0].command}' | grep -q -- "$(rpcs $x)" || ok=0; done
  [ $ok = 1 ] && { say "llm-serve: both LFM replicas serve over rails ${RAIL[a]} and ${RAIL[b]}, nothing to do"; exit 0; }; fi

pod() {   # pod <name> <node> <labels json> <networks json or ""> <command json> <memory request>
  python3 - "$@" <<'EOF'
import json, sys
name, node, labels, nets, cmd, mem = sys.argv[1:7]
GPUS = "4" if name.startswith("rpc-") else "2"   # serving holds half of each GPU worker (4 of 8), training (ai-train.sh) the other half
meta = {"name": name, "namespace": "llm", "labels": json.loads(labels)}
if nets: meta["annotations"] = {"k8s.v1.cni.cncf.io/networks": nets}
c = {"name": "main", "image": "image-registry.openshift-image-registry.svc:5000/scd-images/llm:2", "command": json.loads(cmd),
     # an RPC worker holds its node's 8 GPUs; on gpu-worker1 / gpu-worker5 the LFM server and Qwen share the node, 4 GPUs each
     "resources": {"requests": {"cpu": "2", "memory": mem, "nvidia.com/gpu": GPUS}, "limits": {"nvidia.com/gpu": GPUS}},
     "volumeMounts": [{"name": "models", "mountPath": "/models", "readOnly": True}, {"name": "keys", "mountPath": "/keys", "readOnly": True}]}
if "llama-server" in cmd:   # Ready only once the model is loaded (llama-server answers /health 200 then; /health needs no key)
    c["readinessProbe"] = {"httpGet": {"path": "/health", "port": 8080}, "periodSeconds": 10, "failureThreshold": 3}
spec = {"nodeSelector": {"kubernetes.io/hostname": node}, "containers": [c], "restartPolicy": "Always",
        "volumes": [{"name": "models", "persistentVolumeClaim": {"claimName": "models", "readOnly": True}},
                    {"name": "keys", "secret": {"secretName": "llm-api-keys"}}]}
print(json.dumps({"apiVersion": "v1", "kind": "Pod", "metadata": meta, "spec": spec}))
EOF
}
say "llm-serve: (re)deploying"
OC -n $NS delete pod -l app=llm --wait=true >/dev/null 2>&1; OC -n $NS delete pod -l app=llm-rpc --wait=true >/dev/null 2>&1
# RPC workers request 3 GiB, no limit: 14.5 GB over 3 workers is ~4.8 GiB each, and a 10 GiB GPU worker has ~3.8 GiB unrequested
for x in a b; do k=0; net="[{\"name\":\"net-rail-$((RAIL[$x] - 1))\",\"namespace\":\"default\"}]"
  for n in ${RPCN[$x]}; do k=$((k + 1))
    pod rpc-$x$k $n "{\"app\":\"llm-rpc\",\"replica\":\"$x\"}" "$net" '["/opt/llama/ggml-rpc-server","-H","0.0.0.0","-p","50052"]' 3Gi | OC apply -f - >/dev/null
  done; done
OC -n $NS wait --for=condition=Ready pod -l app=llm-rpc --timeout=600s >/dev/null || { say "llm-serve: RPC workers not ready"; OC -n $NS get pods -o wide; exit 1; }
for x in a b; do r=$(rpcs $x); net="[{\"name\":\"net-rail-$((RAIL[$x] - 1))\",\"namespace\":\"default\"}]"
  case "$r" in *":50052,:"*|":50052"*) say "llm-serve: replica $x has a worker without a rail address ($r)"; exit 1;; esac
  say "llm-serve: replica $x on ${SRV[$x]} > rpc $r (rail ${RAIL[$x]})"
  pod llm-$x ${SRV[$x]} "{\"app\":\"llm\",\"model\":\"lfm2.5-24b\",\"replica\":\"$x\"}" "$net" \
    "[\"/opt/llama/llama-server\",\"-m\",\"/models/$LFM\",\"--rpc\",\"$r\",\"-ngl\",\"99\",\"-c\",\"8192\",\"-np\",\"1\",\"-t\",\"6\",\"--host\",\"0.0.0.0\",\"--port\",\"8080\",\"--alias\",\"lfm2.5-24b\",\"--reasoning-budget\",\"512\",\"--reasoning-budget-message\",\"Time to answer.\",\"--api-key-file\",\"/keys/keys\"]" 2Gi | OC apply -f - >/dev/null
  pod qwen-$x ${SRV[$x]} "{\"app\":\"llm\",\"model\":\"qwen2.5-0.5b\",\"replica\":\"$x\"}" "" \
    "[\"/opt/llama/llama-server\",\"-m\",\"/models/$QWEN\",\"-c\",\"4096\",\"-np\",\"1\",\"-t\",\"2\",\"--host\",\"0.0.0.0\",\"--port\",\"8080\",\"--alias\",\"qwen2.5-0.5b\",\"--api-key-file\",\"/keys/keys\"]" 1Gi | OC apply -f - >/dev/null
done
OC -n $NS wait --for=condition=Ready pod -l app=llm --timeout=1800s >/dev/null; OC -n $NS get pods -o wide --no-headers | awk '{print "   ", $1, $3, $7}'
say "llm-serve: LFM endpoints $(serving)/2"
