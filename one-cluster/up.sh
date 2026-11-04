#!/bin/bash
# up.sh [--check]: preflight, then the deploy of sonic-clos-dc: fabric, rails, firewall, load balancer, storage array, hosts.
#   preflight: images (build the scd/* ones if missing), VM-disk home on $VMHOME, outside addresses free, the management masquerade,
#              RAM / disk report, gen.py render. --check stops there.
#   licences:  the BIG-IP env files (one licence key per unit) are written by f5.sh secrets before the deploy; a deploy never re-creates a
#              licensed BIG-IP (--reconfigure would bind its key to a dead VM): revoke first (./f5.sh revoke) or bring the lab down with down.sh.
#   deploy:    containerlab deploy --reconfigure (a plain deploy keeps old startup-configs), then sonic-apply.sh, then
#              rail-roce.sh (Dell's RoCE profile on the 12 rail switches, one reboot each).
#              The OpenShift guests stay held (HOLD_FILE) until ocp-install.sh releases them.
cd "$(dirname "$0")"; . ./lib.sh; FAIL=0
VMHOME=${VMHOME:-/opt/unetlab}   # where the VM disks live: a filesystem with room (>= 200 GB free), outside the repository
bad() { say "PREFLIGHT FAIL: $*"; FAIL=1; }
say "images"
for i in vrnetlab/dell_sonic:4.6.0 vrnetlab/paloalto_pa-vm:12.1.2 vrnetlab/netapp_ontap:9.17.1 vrnetlab/f5_bigip-ve:17.5.1.11-0.0.12 scd/bastion:1 scd/rhcos-node:1; do
  docker image inspect $i >/dev/null 2>&1 || bad "image $i missing"; done
docker image inspect scd/host:1 >/dev/null 2>&1 || docker build --network host -q -t scd/host:1 ../images/host >/dev/null   # built from the shared images/
for i in bastion rhcos-node; do docker image inspect scd/$i:1 >/dev/null 2>&1 || docker build --network host -q -t scd/$i:1 images/$i >/dev/null || bad "build scd/$i:1"; done
[ -x /root/ocp-bin/openshift-install ] && [ -f /root/pull-secret.json ] || bad "openshift-install or pull secret missing"
say "VM disks on $VMHOME"
mkdir -p $VMHOME/$LAB/nodes; [ -L nodes ] || ln -sfn $VMHOME/$LAB/nodes nodes
python3 gen.py || bad "gen.py"
for d in $(sed -n 's|.*- \(nodes/[^:]*\):.*|\1|p' $TOPO | sort -u); do mkdir -p $d; done
say "external-LAN addresses of the lab (PA outside .141-.145, LAN clients .146/.147) must not answer ARP, unless the lab is already up"
if ! docker ps --format '{{.Names}}' | grep -qx $C-fw-pa; then
  for ip in $(awk '{print $1}' outside.txt); do
    ping -c1 -W1 $ip >/dev/null 2>&1; st=$(ip neigh show $ip dev pnet0 | awk '{print $NF}')
    case "$st" in REACHABLE|STALE|DELAY|PERMANENT) bad "$ip is in use on the external LAN ($st)";; *) echo "  $ip free";; esac
  done
fi
say "management masquerade 172.21.30.0/24 (nft table clab_nat, not persistent)"
nft list chain ip clab_nat postrouting 2>/dev/null | grep -q "172.21.30.0/24" || nft add rule ip clab_nat postrouting ip saddr 172.21.30.0/24 oifname "pnet0" masquerade || bad "nft rule"
say "resources: $(free -g | awk '/Mem:/{print $7" GiB available"}'), $(df -h $VMHOME | awk 'NR==2{print $4" free on $VMHOME"}'), $(df -h / | awk 'NR==2{print $4" free on /"}')"
say "F5 licences: env files, ledger, no licensed BIG-IP may be re-created"
./f5.sh secrets || bad "f5.sh secrets"
for u in lb-f5a lb-f5b; do docker inspect $C-$u >/dev/null 2>&1 && [ "${1:-}" != --check ] && bad "$u is deployed: revoke (./f5.sh revoke) or ./down.sh first, never re-create a licensed BIG-IP"; done
# memory: 3 x 16 (masters) + 6 x 12 (tenant workers) + 8 x 10 GiB (GPU workers) = 200 GiB of nodes, ~115 GiB of switches (rails 12 x 4 GiB,
# ~2.4 resident), BIG-IPs, ONTAP and PA-VM, + 16 GiB kept free (NEED_GIB)
a=$(free -g | awk '/Mem:/{print $7}'); [ "$a" -ge ${NEED_GIB:-354} ] || bad "only $a GiB available, the lab needs about ${NEED_GIB:-354} GiB (16 of it kept free; the 12 leaves at 6 GiB)"
[ $FAIL = 0 ] || { say "preflight failed"; exit 1; }
[ "${1:-}" = --check ] && { say "preflight OK (--check: not deploying)"; exit 0; }
rm -f shared/release-ocp   # the OpenShift guests must hold until ocp-install.sh releases them with the NEW ISO
say "deploy (--reconfigure)"
containerlab deploy -t $TOPO --reconfigure > logs-deploy.txt 2>&1 || { tail -20 logs-deploy.txt; exit 1; }
say "switch configs"; ./sonic-apply.sh | tee logs-apply.txt
say "tenant bastions (macvlan on each probe's bond0, after the switch configs)"; ./tenant-bastion.sh up
say "rail switches: Dell RoCE profile"; ./rail-roce.sh | tee logs-roce.txt
say "PA-VM config by replace (the startup-config MERGES with the factory VR 'default': 4 VRs > the PA-VM's limit of 3)"
for i in $(seq 1 60); do [ -n "$(pakey)" ] && break; sleep 20; done; ./pa-load.sh | tail -2
say "F5 licences (auto-license at boot through the management NAT)"; ./f5.sh licence
say "deployed; next: ./validate-fabric.sh"
