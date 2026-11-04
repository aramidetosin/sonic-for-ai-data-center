#!/bin/bash
# PID 1 of an OpenShift node container (with the HOLD_FILE gate): bridge the containerlab interfaces into taps, stand in for the
# server's BMC on the OOB link, and boot the RHCOS guest from the agent-based installer ISO (first boot) or its disk.
#   eth0 (clab mgmt)          -> br0/tap0 : the guest gets the container's management address (static, from the agent config)
#   eth1..ethN (fabric)       -> brN/tapN : the guest bonds them (LACP) to its leaf pair
#   ethN+1 (OOB / BMC link)   -> brN+1    : the container itself answers as the BMC (BMC_IP); the storage guest also gets a
#                                           tap here for the FlashBlade management address (OOB_IP)
#   /iso/agent.x86_64.iso     : agent ISO (all nodes share it); /vm : per-node disk(s) + console log
set -u
log() { echo "[vm-init] $*"; }
: "${NODE_IP:?}" "${NODE_HOSTNAME:?}"; BMC_IP=${BMC_IP:-}   # a GPU worker has no BMC link (BMC_IP empty)
VM_MEM=${VM_MEM:-8192}; VM_CPUS=${VM_CPUS:-4}; VM_DISK=${VM_DISK:-120G}; VM_DATA=${VM_DATA:-}
mkdir -p /vm
N=${FABRIC_NICS:-2}; OOBN=$((N + 1)); NICS="0 $(seq -s " " 1 "$N")${BMC_IP:+ $OOBN}"

log "waiting for links ..."
for i in $(seq 1 240); do ok=1; for n in $NICS; do ip link show "eth$n" >/dev/null 2>&1 || ok=0; done; [ $ok = 1 ] && break; sleep 1; done
MGMT_IP=$(ip -4 -o addr show eth0 | awk '{print $4}' | head -1)
MGMT_GW=$(ip -4 route show default | awk '{print $3}' | head -1)
MAC_BASE=${NODE_MAC:-52:54:00:00:00:00}; MAC_PFX=${MAC_BASE%:*}
mac() { printf '%s:%02x' "$MAC_PFX" "$1"; }
log "guest $NODE_HOSTNAME: mgmt $MGMT_IP via $MGMT_GW, fabric $NODE_IP, bmc $BMC_IP${OOB_IP:+, storage mgmt $OOB_IP}, ${VM_CPUS} vcpu ${VM_MEM} MiB"

ip addr flush dev eth0
for i in $NICS; do
  ip link add "br$i" type bridge 2>/dev/null; ip link set "br$i" up
  if [ "$i" -le "$N" ] || [ -n "${OOB_IP:-}" ]; then ip tuntap add "tap$i" mode tap 2>/dev/null; ip link set "tap$i" master "br$i"; ip link set "tap$i" up; fi
  ip link set "eth$i" master "br$i"
  if [ "$i" -ge 1 ] && [ "$i" -le "$N" ]; then
    for d in "eth$i" "tap$i" "br$i"; do ip link set "$d" mtu "${NODE_MTU:-9000}"; done
    echo 0x4004 > "/sys/class/net/br$i/bridge/group_fwd_mask"   # LACP (0x4) and LLDP (0x4000) frames cross the bridge to the switch
  fi
  ip link set "eth$i" up
done
# BMC stand-in: the container answers on the OOB link with the server's BMC address; replies leave via the OOB gateway (table 100)
if [ -n "$BMC_IP" ]; then
  ip addr add "${BMC_IP}/${OOB_PREFIX:-27}" dev "br$OOBN"
  ip rule add from "$BMC_IP" lookup 100 2>/dev/null; ip route add default via "${OOB_GW:-10.125.31.254}" dev "br$OOBN" table 100 2>/dev/null
  log "BMC stand-in ${BMC_IP} on br$OOBN (eth$OOBN -> OOB switch)"
else log "no BMC link (FABRIC_NICS=$N)"; fi

# sonic-clos-dc hold gate: the guest boots only after up.sh / ocp-install.sh touches $HOLD_FILE (the fabric, the PA-VM, DNS and the
# agent ISO are ready by then); without it the agent ISO would boot into a network that is not there yet
if [ -n "${HOLD_FILE:-}" ]; then log "holding until $HOLD_FILE exists ..."; until [ -e "$HOLD_FILE" ]; do sleep 10; done; log "released"; fi
ISO=$(ls /iso/*.iso 2>/dev/null | head -1); [ -n "$ISO" ] || { log "no agent ISO in /iso (run make-iso.sh)"; sleep infinity; }
[ -f /vm/root.qcow2 ] || qemu-img create -q -f qcow2 /vm/root.qcow2 "$VM_DISK"
[ -z "$VM_DATA" ] || [ -f /vm/data.img ] || qemu-img create -q -f raw /vm/data.img "$VM_DATA"

NETS=""
for k in $(seq 1 "$N"); do NETS="$NETS -netdev tap,id=n$k,ifname=tap$k,script=no,downscript=no -device virtio-net-pci,netdev=n$k,mac=$(mac $((16 + k))),speed=10000,duplex=full"; done
[ -n "${OOB_IP:-}" ] && NETS="$NETS -netdev tap,id=n$OOBN,ifname=tap$OOBN,script=no,downscript=no -device virtio-net-pci,netdev=n$OOBN,mac=$(mac $((16 + OOBN)))"
DATA=""; [ -n "$VM_DATA" ] && DATA="-drive file=/vm/data.img,if=virtio,format=raw,cache=none,aio=threads"
log "booting guest: disk first, agent ISO when the disk is empty (console in /vm/console.log)"
exec qemu-system-x86_64 -enable-kvm -cpu host -machine q35,accel=kvm -smp "$VM_CPUS" -m "$VM_MEM" -nographic -nodefaults \
  -serial file:/vm/console.log -monitor none -boot order=cd,strict=on \
  -drive file=/vm/root.qcow2,if=virtio,format=qcow2,cache=none,aio=threads $DATA \
  -drive file="$ISO",if=none,id=cd0,media=cdrom,readonly=on -device ide-cd,drive=cd0,bus=ide.0 \
  -netdev tap,id=n0,ifname=tap0,script=no,downscript=no -device virtio-net-pci,netdev=n0,mac="$(mac 16)" \
  $NETS
