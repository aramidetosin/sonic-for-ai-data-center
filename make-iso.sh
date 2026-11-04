#!/bin/bash
# make-iso.sh <prod|dev|gpu>: the cluster's agent-based installer ISO: gen.py's install-config + agent-config + manifests/ (day-1
# MachineConfigs of every cluster: iSCSI/multipath for Trident on masters and workers, chrony from the lab NTP only) + manifests-<cluster>/
# (gpu: SoftRoCE per rail) -> agent-<cluster>/iso/agent.x86_64.iso. The installer state and auth/ stay in agent-<cluster>/build, which the
# cluster's bastion mounts as /w/agent (bastion-prod / bastion-dev / bastion-gpu run the wait-for and oc).
# A previous build directory is moved aside (agent-<cluster>/build.<time>), never deleted: it holds the kubeconfig of an earlier install.
cd "$(dirname "$0")"; . ./lib.sh; CL=${1:?prod|dev|gpu}; D=agent-$CL
case " $CLUSTERS " in *" $CL "*) ;; *) echo "unknown cluster $CL ($CLUSTERS)"; exit 2;; esac
python3 gen.py >/dev/null || exit 1
[ -s $D/install-config.yaml ] || { say "$D/install-config.yaml missing (gen.py writes it only when /root/pull-secret.json exists)"; exit 1; }
[ -d $D/build ] && mv $D/build $D/build.$(date +%Y%m%d%H%M%S)
umask 077   # the install-config carries the pull secret; auth/ will hold the kubeconfig and kubeadmin password
mkdir -p $D/build/openshift $D/iso; cp $D/install-config.yaml $D/agent-config.yaml $D/build/; cp manifests/*.yaml $D/build/openshift/
[ -d manifests-$CL ] && cp manifests-$CL/*.yaml $D/build/openshift/
HOME=/root /root/ocp-bin/openshift-install agent create image --dir $D/build --log-level warn || exit 1
mv -f $D/build/agent.x86_64.iso $D/iso/agent.x86_64.iso && chmod 644 $D/iso/agent.x86_64.iso && ls -la $D/iso/agent.x86_64.iso | awk '{print "'$CL' ISO", $5, "bytes"}'
