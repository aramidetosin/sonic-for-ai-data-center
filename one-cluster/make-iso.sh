#!/bin/bash
# make-iso.sh [ocp]: the cluster's agent-based installer ISO: gen.py's install-config + agent-config + manifests/ (day-1
# MachineConfigs: iSCSI for Trident, chrony from the lab NTP only) + manifests-<cluster>/*.yaml -> agent-<cluster>/iso/agent.x86_64.iso; the installer state and auth/ stay in agent-<cluster>/build (bastion: /w/agent/build).
cd "$(dirname "$0")"; . ./lib.sh; CL=${1:-ocp}; D=agent-$CL
python3 gen.py >/dev/null
rm -rf $D/build; mkdir -p $D/build/openshift $D/iso; cp $D/install-config.yaml $D/agent-config.yaml $D/build/; cp manifests/*.yaml $D/build/openshift/; [ -d manifests-$CL ] && cp manifests-$CL/*.yaml $D/build/openshift/   # per-cluster day-1 MachineConfigs (gpu: SoftRoCE per rail)
HOME=/root /root/ocp-bin/openshift-install agent create image --dir $D/build --log-level warn || exit 1
mv -f $D/build/agent.x86_64.iso $D/iso/agent.x86_64.iso && ls -la $D/iso/agent.x86_64.iso | awk '{print "'$CL' ISO", $5, "bytes"}'
