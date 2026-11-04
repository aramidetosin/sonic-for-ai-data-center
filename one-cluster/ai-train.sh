#!/bin/bash
# ai-train.sh [run|status|logs <dir>]: the multi-node training workload of cluster ocp: PyTorch DistributedDataParallel, one rank per GPU
# worker (8 ranks), as a Kubernetes Indexed Job in namespace ai-train (images/ai-sim/train.py).
#   T1 dataset     rank 0 stages one shard per rank on a ReadWriteMany volume (ocp-nas: svm-ocp over the storage bonds); every rank reads its own
#   T2 gradients   every optimiser step ends with a gloo all-reduce of the gradients between the 8 ranks over RAIL 1 (GLOO_SOCKET_IFNAME=net1, the
#                  pod's macvlan on enp0s6); the rendezvous (rank 0's TCP store) uses the pod network: ddp-0.ddp, a headless Service
#   T3 checkpoint  rank 0 writes a checkpoint per epoch to the shared volume
#   T4 collective  the 8-GPU-node pattern: GPU r of a node talks to GPU r of the next node over rail r; a ring rank i > rank i+1 on rails 2-8 at
#                  once (iperf3, rate-limited: the rail leaves are VMs); the ranks find each other's rail addresses on the shared volume
# Each rank requests nvidia.com/gpu: 4 (the other 4 of the node serve the models). run: replaces the previous job, waits
# for it (each run in its own directory run-<ts> on the volume), prints each rank's RESULT and ring lines. logs <dir>: every rank's log into <dir> (validate-platform.sh uses them).
set -u
cd "$(dirname "$0")"; . ./lib.sh
MODE=${1:-run}; NS=ai-train; B=$C-bastion-ocp; IMG=image-registry.openshift-image-registry.svc:5000/scd-images/ai-sim:1
WORLD=8; EPOCHS=${EPOCHS:-3}; STEPS=${STEPS:-10}; HIDDEN=${HIDDEN:-768}
OC() { docker exec -i $B oc "$@"; }
if [ "$MODE" = status ]; then OC -n $NS get job,pod -o wide 2>&1 | cut -c1-150; exit 0; fi
if [ "$MODE" = logs ]; then d=${2:?dir}; mkdir -p "$d"
  for i in $(seq 0 $((WORLD - 1))); do p=$(OC -n $NS get pod -l job-name=ddp,batch.kubernetes.io/job-completion-index=$i -o name 2>/dev/null | tail -1)
    [ -n "$p" ] && OC -n $NS logs $p > "$d/rank-$i.log" 2>&1; done; exit 0; fi
RUN=$(date -u +%Y%m%d%H%M%S)
python3 - "$NS" "$IMG" "$WORLD" "$EPOCHS" "$STEPS" "$HIDDEN" "$RUN" > /tmp/ai-train.json <<'EOF'
import json, sys
ns, img, world, epochs, steps, hidden, run = sys.argv[1:]
rank_sh = r'''set -eu
export RANK=$JOB_COMPLETION_INDEX; D=/data/run-$RUN; mkdir -p $D/rails
# retention: rank 0 keeps the newest 3 runs on the volume (this one included), so the volume never fills (a full volume fails a run with an I/O error)
[ "$RANK" = 0 ] && ls -1d /data/run-[0-9]* 2>/dev/null | sort | head -n -3 | while read -r o; do rm -rf -- "$o" && echo "[rank 0] pruned $o"; done; [ "$RANK" = 0 ] && for i in $(seq 1 36); do u=$(df -P /data | awk "NR==2 {sub(/%/, \"\", \$5); print \$5}"); [ "$u" -lt 80 ] && break; sleep 5; done; df -h /data | tail -1 | awk '{print "[rank " ENVIRON["RANK"] "] volume " $5 " used"}'
ip -4 -o addr show | awk '$2 ~ /^net[1-8]$/ {split($4, a, "/"); print $2, a[1]}' > $D/rails/rank-$RANK.tmp && mv $D/rails/rank-$RANK.tmp $D/rails/rank-$RANK
echo "[rank $RANK] node $NODE, rail addresses: $(tr '\n' ' ' < $D/rails/rank-$RANK)"
DATA_DIR=$D python3 /opt/ai/train.py 2>&1 | grep -vE 'UserWarning|_conversion_method|warnings.warn'
# T4: the ring on rails 2-8 (servers first, then every rank waits for all servers before its clients start)
me() { awk -v i=net$1 '$1 == i {print $2}' $D/rails/rank-$2; }
for r in 2 3 4 5 6 7 8; do iperf3 -s -D -B $(me $r $RANK) -p 520$r >/dev/null 2>&1; done
touch $D/rails/up-$RANK; for i in $(seq 1 120); do [ $(ls $D/rails | grep -c '^up-') -ge $WORLD_SIZE ] && break; sleep 1; done
n=$(( (RANK + 1) % WORLD_SIZE ))
for r in 2 3 4 5 6 7 8; do ( o=$(iperf3 -c $(me $r $n) -B $(me $r $RANK) -p 520$r -t 6 -b 5M 2>&1 | grep receiver | tail -1)
  echo "RING rail $r: rank $RANK $(me $r $RANK) > rank $n $(me $r $n): ${o:-failed}" ) & done; wait
touch $D/rails/done-$RANK; for i in $(seq 1 120); do [ $(ls $D/rails | grep -c '^done-') -ge $WORLD_SIZE ] && break; sleep 1; done
[ $RANK = 0 ] && echo "[rank 0] on the shared volume: $(ls $D/checkpoints | tr '\n' ' ')"; exit 0
'''
rails = ",".join("default/net-rail-%d" % r for r in range(8))
env = [{"name": k, "value": v} for k, v in (("WORLD_SIZE", world), ("MASTER_ADDR", "ddp-0.ddp"), ("MASTER_PORT", "29500"), ("GLOO_SOCKET_IFNAME", "net1"),
                                            ("EPOCHS", epochs), ("STEPS", steps), ("HIDDEN", hidden), ("RUN", run))]
env.append({"name": "NODE", "valueFrom": {"fieldRef": {"fieldPath": "spec.nodeName"}}})
docs = [
    {"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": ns}},
    {"apiVersion": "v1", "kind": "PersistentVolumeClaim", "metadata": {"name": "train-data", "namespace": ns},
     "spec": {"accessModes": ["ReadWriteMany"], "storageClassName": "ocp-nas", "resources": {"requests": {"storage": "5Gi"}}}},
    {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "rank", "namespace": ns}, "data": {"rank.sh": rank_sh}},
    {"apiVersion": "v1", "kind": "Service", "metadata": {"name": "ddp", "namespace": ns},   # the rendezvous: ddp-<index>.ddp
     "spec": {"clusterIP": "None", "publishNotReadyAddresses": True, "selector": {"job-name": "ddp"}, "ports": [{"name": "store", "port": 29500}]}},
    {"apiVersion": "batch/v1", "kind": "Job", "metadata": {"name": "ddp", "namespace": ns, "labels": {"run": run}},
     "spec": {"completions": int(world), "parallelism": int(world), "completionMode": "Indexed", "backoffLimit": 0, "activeDeadlineSeconds": 1800,
              "template": {"metadata": {"labels": {"app": "ai-train", "run": run}, "annotations": {"k8s.v1.cni.cncf.io/networks": rails}},
                           "spec": {"subdomain": "ddp", "restartPolicy": "Never", "terminationGracePeriodSeconds": 5,
                                    "nodeSelector": {"scd/gpu": "true"},
                                    "affinity": {"podAntiAffinity": {"requiredDuringSchedulingIgnoredDuringExecution": [
                                        {"labelSelector": {"matchLabels": {"job-name": "ddp"}}, "topologyKey": "kubernetes.io/hostname"}]}},
                                    "containers": [{"name": "rank", "image": img, "command": ["sh", "/cfg/rank.sh"], "env": env,
                                                    "resources": {"requests": {"cpu": "1", "memory": "512Mi", "nvidia.com/gpu": "4"},   # a rank uses ~0.6 GiB;
                                                                  "limits": {"memory": "1536Mi", "nvidia.com/gpu": "4"}},   # a 10 GiB GPU worker has ~0.8 GiB unrequested
                                                    "volumeMounts": [{"name": "data", "mountPath": "/data"}, {"name": "cfg", "mountPath": "/cfg"}]}],
                                    "volumes": [{"name": "data", "persistentVolumeClaim": {"claimName": "train-data"}},
                                                {"name": "cfg", "configMap": {"name": "rank"}}]}}}}]
print(json.dumps({"apiVersion": "v1", "kind": "List", "items": docs}))
EOF
say "ai-train: run $RUN, $WORLD ranks x 4 GPUs, $EPOCHS epochs x $STEPS steps"
OC -n $NS delete job ddp --wait=true >/dev/null 2>&1
OC apply -f - < /tmp/ai-train.json | sed 's/^/   /'; rm -f /tmp/ai-train.json
docker exec $B bash -c "for i in \$(seq 1 180); do s=\$(oc -n $NS get job ddp -o jsonpath='{.status.succeeded}/{.status.failed}'); case \$s in $WORLD/*) break;; */[1-9]*) break;; esac; sleep 10; done
  oc -n $NS get job ddp --no-headers; oc -n $NS get pod -l job-name=ddp -o wide --no-headers | awk '{print \"   \", \$1, \$3, \$7}'"
for i in $(seq 0 $((WORLD - 1))); do p=$(OC -n $NS get pod -l job-name=ddp,batch.kubernetes.io/job-completion-index=$i -o name | tail -1)
  OC -n $NS logs $p 2>&1 | grep -E "RESULT|RING|process group|on the shared volume" | sed "s/^/   /" | cut -c1-200; done
[ "$(OC -n $NS get job ddp -o jsonpath='{.status.succeeded}')" = "$WORLD" ]
