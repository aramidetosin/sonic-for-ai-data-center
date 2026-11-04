#!/bin/bash
# rdma-probe.sh [run|clean] [rail]: RDMA between two pods of the gpu cluster over a rail (RoCEv2 on SoftRoCE): pods rdma-a (gpu-worker2) and rdma-b (gpu-worker3) in
# namespace rdma-probe, each with rdma/rdma-shared: 1 (the generic device plugin: /dev/infiniband) and IPC_LOCK, on the host network (SCC
# scd-rdma-hostnet, no privileged pod): SoftRoCE receives RoCEv2 only in the host's namespace, so the pods use their node's rail address
# 172.16.<r>.<10+n> (with a ConnectX HCA: a macvlan, SCC scd-rdma). rdma-a serves ib_write_bw on the GID of its rail address (rdma_cm hangs in the container); rdma-b writes to it for 5 s. Both mark the traffic class
#   96 (--tclass): DSCP 24, the lossless TC3 of the rails' roce profile (a workload sets it the same way, e.g. NCCL_IB_TC=96).
# Prints the device, the GIDs and the bandwidth line; the caller captures the rail leaf (RoCEv2 = UDP 4791).
set -u
cd "$(dirname "$0")"; . ./lib.sh
MODE=${1:-run}; R=${2:-1}; NS=rdma-probe; B=$(BAST gpu); IMG=image-registry.openshift-image-registry.svc:5000/scd-images/rdma-tools:1
OC() { OCL gpu "$@"; }
if [ "$MODE" = clean ]; then OC delete ns $NS --wait=true --timeout=300s >/dev/null 2>&1; exit 0; fi
pod() {   # pod <name> <node>
  cat <<EOF
{"apiVersion": "v1", "kind": "Pod", "metadata": {"name": "$1", "namespace": "$NS", "labels": {"app": "rdma-probe"},
  "annotations": {}},
 "spec": {"serviceAccountName": "rdma-probe", "hostNetwork": true, "nodeSelector": {"kubernetes.io/hostname": "$2"}, "terminationGracePeriodSeconds": 2,
  "containers": [{"name": "rdma", "image": "$IMG", "command": ["sleep", "3600"],
   "securityContext": {"allowPrivilegeEscalation": false, "capabilities": {"add": ["IPC_LOCK"], "drop": ["KILL", "MKNOD"]}},
   "resources": {"requests": {"rdma/rdma-shared": "1", "cpu": "200m", "memory": "128Mi"}, "limits": {"rdma/rdma-shared": "1", "memory": "512Mi"}}}]}}
EOF
}
OC create ns $NS --dry-run=client -o yaml | OC apply -f - >/dev/null
OC -n $NS create sa rdma-probe --dry-run=client -o yaml | OC apply -f - >/dev/null
OC adm policy add-scc-to-user scd-rdma-hostnet -z rdma-probe -n $NS >/dev/null
OC -n $NS delete pod -l app=rdma-probe --wait=true >/dev/null 2>&1
{ pod rdma-a gpu-worker2; pod rdma-b gpu-worker3; } | OC apply -f - >/dev/null
OC -n $NS wait --for=condition=Ready pod -l app=rdma-probe --timeout=300s >/dev/null || { echo "pods not ready"; OC -n $NS get pod -o wide; exit 1; }
ip() { OC -n $NS exec $1 -- sh -c "ip -4 -o addr show enp0s$((5 + R)) | awk '{print \$4}' | cut -d/ -f1"; }   # the node's rail-R address
A=$(ip rdma-a); Bb=$(ip rdma-b); DEV=rxe_rail$R
echo "rdma-a gpu-worker2 rail $R $A, rdma-b gpu-worker3 rail $R $Bb, device $DEV, scc $(OC -n $NS get pod rdma-a -o jsonpath='{.metadata.annotations.openshift\.io/scc}')"
echo "rdma-a sees: $(OC -n $NS exec rdma-a -- sh -c 'ls /dev/infiniband | xargs; ibv_devices | grep -c rxe_rail') ; memlock $(OC -n $NS exec rdma-a -- sh -c 'ulimit -l')"
# the GID index that holds the node's rail address (::ffff:a.b.c.d): RoCEv2 over IPv4 on that rail; perftest's own TCP exchange sets up the QPs
gid() { OC -n $NS exec $1 -- sh -c "for g in /sys/class/infiniband/$DEV/ports/1/gids/*; do [ \"\$(cat \$g)\" = \"$2\" ] && basename \$g; done | head -1"; }
hexip() { printf '0000:0000:0000:0000:0000:ffff:%02x%02x:%02x%02x' $(echo $1 | tr . ' '); }
GA=$(gid rdma-a $(hexip $A)); GB=$(gid rdma-b $(hexip $Bb)); echo "GID index: rdma-a $GA, rdma-b $GB"
OC -n $NS exec rdma-a -- sh -c "timeout 40 ib_write_bw -d $DEV -x $GA --tclass=96 -D 5 --report_gbits -F > /tmp/srv.txt 2>&1 &"; sleep 3
OC -n $NS exec rdma-b -- timeout 40 ib_write_bw -d $DEV -x $GB --tclass=96 -D 5 --report_gbits -F $A 2>&1 | grep -E "GID:|Transport|Link type|Mtu|#bytes|^ 65536" | head -10
sleep 2; echo "-- server side"; OC -n $NS exec rdma-a -- sh -c "grep -E 'GID:|^ 65536' /tmp/srv.txt | head -3"
