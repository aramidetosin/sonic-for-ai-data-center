#!/bin/bash
# down.sh: power sonic-clos-dc off and keep every disk (OpenShift guests, ONTAP, the agent state in agent-*/build). Order: the BIG-IP licences
# are revoked FIRST (containerlab destroy deletes the BIG-IP VMs; a key still bound to a deleted VM is lost) and the script stops if
# one is not confirmed free; then the OpenShift nodes shut down from inside (workers, then masters), the ONTAP nodes halt cleanly, then
# containerlab removes the containers.
# Power on again: ./up.sh (the fabric, the firewall and the storage come back from configs and disks, the BIG-IPs boot fresh and license again: run ./f5.sh base and the app
# steps); the clusters come back with their disks: touch shared/release-<cluster>.
cd "$(dirname "$0")"; . ./lib.sh
VMHOME=${VMHOME:-/opt/unetlab}   # where the VM disks live: a filesystem with room (>= 200 GB free), outside the repository
./f5.sh revoke || { say "refusing to power off: a BIG-IP licence is not confirmed free (see ./f5.sh status)"; exit 1; }
SSHC() { ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8 core@"$(mip $1)" "$2" 2>/dev/null; }
for role in worker master; do   # every OpenShift node by its container name <cluster>-<node> (mgmt-hosts.txt, gen.py)
  for n in $(awk -v r=$role '$2 ~ "^ocp-" && $2 ~ r {print $2}' mgmt-hosts.txt); do SSHC $n "sudo systemctl poweroff" & done; wait
  say "OpenShift $role: poweroff sent"; sleep 60
done
ONTAP "set -privilege advanced -confirmations off; system node halt -node * -inhibit-takeover true -ignore-quorum-warnings true" | tail -1; sleep 90
rm -f shared/release-ocp   # the guests stay held at the next up.sh until the clusters are released on purpose
./tenant-bastion.sh down   # containerlab nodes (destroy removes them too); up.sh / tenant-bastion.sh up re-create them and their cables
containerlab destroy -t $TOPO > logs-down.txt 2>&1; say "lab removed; disks kept under $VMHOME/$LAB/nodes"
