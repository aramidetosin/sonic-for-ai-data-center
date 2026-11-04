#!/bin/bash
# ocp-install.sh [ocp]: the install of one cluster: release the hold gate (the RHCOS wrappers boot the agent ISO), then follow the install
# from the cluster's own bastion (in its tenant VRF): bootstrap-complete, install-complete. Log: logs/install-<cluster>.txt
cd "$(dirname "$0")"; . ./lib.sh; CL=${1:-ocp}; mkdir -p logs
[ -f agent-$CL/iso/agent.x86_64.iso ] || { say "no ISO: ./make-iso.sh $CL"; exit 1; }
say "$CL: releasing the guests"; touch shared/release-$CL
B=$C-bastion-$CL
docker exec $B openshift-install agent wait-for bootstrap-complete --dir /w/agent/build --log-level info > logs/install-$CL.txt 2>&1 &&
docker exec $B openshift-install agent wait-for install-complete --dir /w/agent/build --log-level info >> logs/install-$CL.txt 2>&1
rc=$?; grep -v -i password logs/install-$CL.txt | tail -3; say "$CL install rc=$rc"; exit $rc
