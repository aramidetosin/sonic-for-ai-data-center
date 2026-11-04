#!/usr/bin/env python3
"""gen.py: sonic-clos-dc, the single source of the lab. Run on the lab host in the lab directory. A name says what it is.
THREE OpenShift clusters on the same fabric and the same 17 node VMs: prod (prod-cp1..3, compact, rack 3,
Vrf-Prod) and dev (dev-cp1..3, compact, rack 4, Vrf-Dev) on the SAME addresses, and gpu (master1..3 racks 1/2 + gpu-worker1..8 racks
3/4, Vrf-Ocp) which serves the models to both tenants through the BIG-IP. No UDN, no VRF-lite on the nodes: a tenant cluster's
node network IS its tenant VRF. The one-cluster build is one-cluster/ in this repository.

Writes:
  sonic-clos-dc.clab.yml            the whole topology
  nodes.json                        every node's containerlab spec as data (node-recreate.sh re-creates one node on a running lab from it)
  configs/<switch>.cli              one sonic-cli command per line (sonic-apply.sh; rail-roce.sh adds the RoCE profile on the rails)
  bootstrap/fw.xml                  the PA-VM configuration (pa-load.sh / startup-config)
  shared/dc.lab.zone                BIND zone for dns-ntp1 (primary) / dns-ntp2 (secondary)
  f5.env                            the BIG-IP pair's addressing for f5.sh
  agent-<cluster>/{install-config,agent-config}.yaml   OpenShift agent-based install per cluster (JSON = valid YAML)
  ontap.env                         parameters for ontap-setup.sh (SVM per cluster)
  mgmt-hosts.txt                    containerlab management addresses; node lines: <ip> <container> <cluster> <hostname>
  manifests-day2-rails.yaml         the GPU workers' rail NMState policies
"""
import json, os

LAB = "sonic-clos-dc"
MGMT = "172.21.30"
LAN_GW = "192.168.100.1"
SECRETS = "/root/scd-secrets"   # root-only env files (mode 600); only their paths appear here

# ---------------------------------------------------------------- fabric (the same switches, cabling, ASNs, VRF names and VNIs as one-cluster/)
SPINES = ["spine1", "spine2", "spine3", "spine4"]
SPINE_ASN, FW_ASN = 65000, 65500
# pair: (leaves, ASN, pair id for system-MAC / ESI); a leaf's name carries its pair number and its role
PAIRS = {
    "rack1": (["leaf1a-control", "leaf1b-control"], 65001, 1), "rack2": (["leaf2a-control", "leaf2b-control"], 65002, 2),
    "rack3": (["leaf3a-compute", "leaf3b-compute"], 65003, 3), "rack4": (["leaf4a-compute", "leaf4b-compute"], 65004, 4),
    "storage": (["leaf5a-storage", "leaf5b-storage"], 65005, 5), "border": (["leaf6a-border", "leaf6b-border"], 65010, 9),
}
LEAVES = [l for p in PAIRS.values() for l in p[0]]   # spine ethN order: eth1 = leaf1a-control ... eth12 = leaf6b-border
BORDERS = PAIRS["border"][0]
SWITCH_MGMT = dict(zip(SPINES, (11, 12, 13, 14)))
SWITCH_MGMT.update(zip(LEAVES, range(21, 33)))
LOOP_OCTET = dict(zip(SPINES, (1, 2, 3, 4)))
LOOP_OCTET.update(zip(LEAVES, (11, 12, 13, 14, 15, 16, 17, 18, 21, 22, 31, 32)))
LOOP = {n: "10.255.255.%d" % o for n, o in LOOP_OCTET.items()}            # Loopback0 = router-id = VTEP
INBAND = {n: "172.16.255.%d" % LOOP_OCTET[n] for n in LEAVES}             # Loopback10 in Vrf-Mgmt (switch in-band management)
ANYMAC = "00:00:5e:00:01:01"

VRFS = {"Vrf-Prod": (50001, 1501), "Vrf-Dev": (50002, 1502), "Vrf-Mgmt": (50003, 1503), "Vrf-Svc": (50004, 1504),
        "Vrf-Ocp": (50005, 1505)}   # L3VNI, its VLAN; Vrf-Ocp keeps its name and VNI and now holds the gpu cluster

# ---------------------------------------------------------------- the three clusters
# cluster: VRF, node VLAN, node /24, storage VLAN, storage /24, SVM, probe/bastion VLAN (tenants), API VIP, ingress VIP, pair of its rack leaves
CLUSTERS = {
    "prod": {"vrf": "Vrf-Prod", "vlan": 101, "net": "10.0.1", "svlan": 103, "snet": "10.0.3", "svm": "svm-prod", "ipspace": "prod", "hvlan": 102,
             "api": "10.0.1.5", "ingress": "10.0.1.7", "tenant": True},
    "dev":  {"vrf": "Vrf-Dev", "vlan": 201, "net": "10.0.1", "svlan": 203, "snet": "10.0.3", "svm": "svm-dev", "ipspace": "dev", "hvlan": 202,
             "api": "10.0.1.5", "ingress": "10.0.1.7", "tenant": True},
    "gpu":  {"vrf": "Vrf-Ocp", "vlan": 108, "net": "10.0.8", "svlan": 109, "snet": "10.0.9", "svm": "svm-gpu", "ipspace": "gpu", "hvlan": None,
             "api": "10.0.8.5", "ingress": "10.0.8.7", "tenant": False},
}
TENANTS = [c for c, v in CLUSTERS.items() if v["tenant"]]
SVM_LIF = {"mgmt": 250, "iscsi": (251, 252), "nfs": (253, 254)}   # the SVM's host octets in its storage /24 (the nodes use their own octet)
VLANS = {   # VLAN: (VRF, anycast gateway); L2VNI = 10000 + VLAN
    101: ("Vrf-Prod", "10.0.1.1/24"), 102: ("Vrf-Prod", "10.0.2.1/24"), 103: ("Vrf-Prod", "10.0.3.1/24"),   # prod
    201: ("Vrf-Dev", "10.0.1.1/24"), 202: ("Vrf-Dev", "10.0.2.1/24"), 203: ("Vrf-Dev", "10.0.3.1/24"),      # dev, the SAME subnets
    108: ("Vrf-Ocp", "10.0.8.1/24"), 109: ("Vrf-Ocp", "10.0.9.1/24"),                                         # gpu nodes, svm-gpu
    301: ("Vrf-Mgmt", "172.16.0.1/24"),
    401: ("Vrf-Svc", "10.250.0.1/24"),
}
PAIR_VLANS = {   # racks 1/2 carry only the gpu masters and bastion-gpu; prod lives on rack 3, dev on rack 4; the GPU workers on both
    "rack1": [108, 301], "rack2": [108, 301],
    "rack3": [101, 102, 108, 301], "rack4": [201, 202, 108, 301],
    "storage": [103, 203, 109, 301], "border": [401],
}
RETIRED_VLANS = [100, 104, 106, 107, 111, 112, 113, 211, 212, 213]   # the one-cluster build's VLANs (migrate-fabric.sh removes them live)
# MetalLB (FRR-K8s) on each tenant cluster's nodes peers eBGP multihop with its rack leaves' loopback in the tenant VRF (Dell SONiC 4.6.0
# drops `ip anycast-address` beside `ip address`, so the node VLAN cannot carry per-leaf session addresses). Loopback 11 = 10.0.0.<loop octet>.
MLB_ASN = 65030
MLB_LOOP = {"Vrf-Prod": "rack3", "Vrf-Dev": "rack4"}   # the tenant VRF and the pair that holds its cluster
MLB_LOOP_ADDR = {l: "10.0.0.%d" % LOOP_OCTET[l] for p in MLB_LOOP.values() for l in PAIRS[p][0]}
APP_IP = {"whoami": 200, "chat": 201, "inference": 202, "harbor": 203, "minio": 204}   # MetalLB pool .200-.209 in 10.0.1.0/24
# border <-> PA-VM transits (/29: leaf6a-border .1, leaf6b-border .2, fw-pa .3), eBGP per transit:
#   (VLAN, net, border VRF, PA virtual router, PA zone, prefixes the PA accepts, PA sends 0/0)
# PAN-OS routes a reply in the virtual router it arrives in, so no tenant flow may cross virtual routers: Vrf-Svc gets one
# transit into each tenant VR (3014/3024). The tenant VRs accept the tenant's 10.0.0.0/16 (the BIG-IP VIPs 10.0.5.x included).
TRANSITS = [
    (3001, "10.254.1", "Vrf-Prod", "vr-prod", "prod", ["10.0.0.0/16"], True),
    (3002, "10.254.2", "Vrf-Dev", "vr-dev", "dev", ["10.0.0.0/16"], True),
    (3003, "10.254.3", "Vrf-Mgmt", "vr-shared", "mgmt", ["172.16.0.0/16"], True),
    (3004, "10.254.4", "Vrf-Svc", "vr-shared", "svc", ["10.250.0.0/16"], True),
    (3014, "10.254.14", "Vrf-Svc", "vr-prod", "svc", ["10.250.0.0/24"], False),
    (3024, "10.254.24", "Vrf-Svc", "vr-dev", "svc", ["10.250.0.0/24"], False),
    (3009, "10.254.9", "Vrf-Ocp", "vr-shared", "gpu", ["10.0.8.0/24"], True),   # the gpu cluster in vr-shared, zone gpu, no 4th VR
]
# PA outside, one external-LAN address per virtual router, and each tenant cluster's console / OAuth address
#   VR: (interface, address, fw-pa ethN wired to pnet0, console + OAuth address or None)
OUTSIDE = {"vr-shared": ("ethernet1/3", "192.168.100.141", "eth3", None), "vr-prod": ("ethernet1/4", "192.168.100.142", "eth4", "192.168.100.144"),
           "vr-dev": ("ethernet1/5", "192.168.100.143", "eth5", "192.168.100.145")}
TENANT_VR = {"prod": "vr-prod", "dev": "vr-dev"}
F5_VIP = "10.0.5.10"       # the apps: DNAT 443 on .142 / .143 > the BIG-IP VIP in the tenant's route domain
# a description on every VLAN interface
VLAN_DESC = {101: "prod-nodes", 102: "prod-probe-bastion", 103: "prod-storage", 201: "dev-nodes", 202: "dev-probe-bastion", 203: "dev-storage",
             108: "gpu-nodes", 109: "gpu-storage", 301: "mgmt-oob", 401: "svc-dns-ntp",
             1501: "l3vni-prod", 1502: "l3vni-dev", 1503: "l3vni-mgmt", 1504: "l3vni-svc", 1505: "l3vni-ocp",
             3001: "fw-transit-prod", 3002: "fw-transit-dev", 3003: "fw-transit-mgmt", 3004: "fw-transit-svc",
             3014: "fw-transit-svc-prod", 3024: "fw-transit-svc-dev", 3009: "fw-transit-gpu",
             3005: "lb-transit-prod", 3006: "lb-transit-dev", 3007: "lb-transit-prod", 3008: "lb-transit-dev",
             3010: "lb-transit-gpu", 3011: "lb-transit-gpu"}

# ---------------------------------------------------------------- GPU backend: rail-optimised, Dell Enterprise SONiC 4.6.0 (unchanged)
RAILS = 8
RAIL_SPINES = ["rail-spine%d" % s for s in range(1, 5)]
RAIL_LEAVES = ["rail-leaf%d" % r for r in range(1, RAILS + 1)]   # rail r = rail-leaf r = VLAN r x 10 = 172.16.r.0/24, gateway .1
RAIL_SPINE_ASN, RAIL_LEAF_ASN = 65100, 65100                     # rail leaf r = 65100 + r; the spines share 65100
RAIL_MGMT = dict(zip(RAIL_SPINES, (61, 62, 63, 64)))
RAIL_MGMT.update(zip(RAIL_LEAVES, range(71, 79)))
RAIL_LOOP = {n: "10.255.254.%d" % o for n, o in zip(RAIL_SPINES + RAIL_LEAVES, list(range(1, 5)) + list(range(11, 19)))}

# ---------------------------------------------------------------- F5 BIG-IP pair
F5_ASN = 65020
# unit: (port on BOTH border leaves, last octet of its self IPs, management octet)
F5 = {"lb-f5a": ("eth8", 3, 43), "lb-f5b": ("eth9", 4, 44)}
# per border leaf: its transit /29 and the tagged VLAN per route domain (local to that leaf, not stretched); border .1, units .3 / .4, floating .5
F5_TRANSIT = {"leaf6a-border": ("10.254.5", {"Vrf-Prod": 3005, "Vrf-Dev": 3006, "Vrf-Ocp": 3010}),
              "leaf6b-border": ("10.254.7", {"Vrf-Prod": 3007, "Vrf-Dev": 3008, "Vrf-Ocp": 3011})}
# route domain name, id, the VRF it extends. rd-gpu (id 3) is the parent of rd-prod and rd-dev and holds the model pool 10.0.8.7%3
F5_RD = {"prod": ("rd-prod", 1, "Vrf-Prod"), "dev": ("rd-dev", 2, "Vrf-Dev"), "gpu": ("rd-gpu", 3, "Vrf-Ocp")}
F5_MODEL_VIP = "10.0.5.11"   # the model API (model.dc.lab) in rd-prod and rd-dev
F5_IMAGE = "vrnetlab/f5_bigip-ve:17.5.1.11-0.0.12"

# ---------------------------------------------------------------- users on the external LAN
LAN_CLIENTS = {"client-lan1": ("192.168.100.146", 137), "client-lan2": ("192.168.100.147", 138)}   # address, management octet

# ---------------------------------------------------------------- the 17 node VMs (same VMs, ports, management addresses, MACs)
# hostname: cluster, role (master | worker; a compact node is a master that also runs workloads), host octet in the cluster's node /24 (and
# storage /24), rack, data port on the rack pair, data PortChannel, BMC leaf, BMC port (None: no BMC on a GPU worker), MiB. Every node:
# 8 vCPU. The order is the VMs' order of the one-cluster build: management .111-.127, MACs and storage ports (eth11.., Po61..) follow it.
NODES = {"master1": ("gpu", "master", 11, "rack1", "eth5", 11, "leaf1a-control", "eth10", 16384),
         "master2": ("gpu", "master", 12, "rack1", "eth6", 12, "leaf1b-control", "eth10", 16384),
         "master3": ("gpu", "master", 13, "rack2", "eth5", 21, "leaf2a-control", "eth10", 16384)}
for _t, _rack, _po, _leaves in (("prod", "rack3", 31, ("leaf3a-compute", "leaf3b-compute", "leaf3a-compute")),
                                ("dev", "rack4", 41, ("leaf4a-compute", "leaf4b-compute", "leaf4a-compute"))):
    for _i in range(3):   # the VMs of the one-cluster <t>-worker1..3, here compact control-plane nodes at 16 GiB
        NODES["%s-cp%d" % (_t, _i + 1)] = (_t, "master", 21 + _i, _rack, "eth%d" % (5 + _i), _po + _i, _leaves[_i], ("eth9", "eth9", "eth10")[_i], 16384)
for _n in range(1, 9):   # GPU workers 1-4 on the rack3 pair, 5-8 on rack4, ports eth12-eth15; 10.0.8.21-.28
    NODES["gpu-worker%d" % _n] = ("gpu", "worker", 20 + _n, "rack3" if _n <= 4 else "rack4", "eth%d" % (12 + (_n - 1) % 4),
                                  (35 if _n <= 4 else 45) + (_n - 1) % 4, None, None, 10240)
GPU_WORKERS = [n for n, v in NODES.items() if n.startswith("gpu-worker")]
STOR_PORT = {n: ("eth%d" % (11 + i), 61 + i) for i, n in enumerate(NODES)}   # storage bond on leaf5a/b, same ports as before
RENDEZVOUS = {"prod": "prod-cp1", "dev": "dev-cp1", "gpu": "master1"}
MGMT_BASE = 111                                       # node container management addresses .111-.127 in NODES order
BMC = {n: "172.16.0.%d" % (101 + i) for i, n in enumerate(n for n, v in NODES.items() if v[6])}   # Vrf-Mgmt BMC stand-ins .101-.109
# bastion-gpu (was bastion-ocp): data port on the rack-1 pair, PortChannel, Vrf-Mgmt leaf, port, Vrf-Mgmt IP, management octet
BASTION_GPU = ("eth8", 14, "leaf1a-control", "eth12", "172.16.0.10", 131, "10.0.8.10")
PROBES = {"prod": ("rack3", "eth8", 34, 133), "dev": ("rack4", "eth8", 44, 134)}   # probe-<t>: 10.0.2.10 in each tenant
TENANT_BASTION = {t: "10.0.2.11" for t in TENANTS}        # bastion-<t> on its cable to probe-<t>:eth3 (bridged onto the probe's bond)
TENANT_BASTION_MGMT = {"prod": 139, "dev": 140}
DNS_NTP = {"dns-ntp1": ("eth5", 91, "10.250.0.11", 135, "primary"), "dns-ntp2": ("eth6", 92, "10.250.0.12", 136, "secondary")}
FW, FW_PORT, FW_PO = "fw-pa", "eth7", 93
NETAPP = {"netapp-01": ("eth5", "eth6", 51, "leaf5a-storage", 41, "172.16.0.41"), "netapp-02": ("eth7", "eth8", 52, "leaf5b-storage", 42, "172.16.0.42")}
ONTAP_CLUSTER, ONTAP_CMGMT = "dc-ontap", "172.16.0.40"


def cname(n):   # a node's container is named after its role: prod-cp1, dev-cp2, gpu-master1, gpu-worker3
    cl = NODES[n][0]
    return n if n.startswith(cl + "-") else "%s-%s" % (cl, n)


def nics(n):    # eth1-2 data bond, eth3-4 storage bond, (GPU) eth5-12 rails 1-8; the BMC link (if any) is the next one
    return 4 + (RAILS if n in GPU_WORKERS else 0)


def eth_to_sonic(port):   # clab ethN -> EthernetN-1 (Dell SONiC native naming)
    return "Ethernet%d" % (int(port[3:]) - 1)


def pair_of(sw):
    for p, (leaves, asn, pid) in PAIRS.items():
        if sw in leaves:
            return p, asn, pid
    raise KeyError(sw)


def esi_ports():
    """pair -> [(member ports, PortChannel, untagged VLAN or None, tagged VLANs, host name, its NIC pair)]; '<host>-lag' / '<host>-lag-member'"""
    E = {p: [] for p in PAIRS}
    for n, (cl, role, o, rack, port, po, *_r) in NODES.items():
        E[rack].append(([port], po, CLUSTERS[cl]["vlan"], [], cname(n), ("eth1", "eth2")))      # the node VLAN untagged, nothing tagged
        sport, spo = STOR_PORT[n]
        E["storage"].append(([sport], spo, CLUSTERS[cl]["svlan"], [], "%s-stor" % cname(n), ("eth3", "eth4")))   # its own SVM's VLAN only
    E["rack1"].append(([BASTION_GPU[0]], BASTION_GPU[1], CLUSTERS["gpu"]["vlan"], [], "bastion-gpu", ("eth1", "eth2")))
    for t, (rack, port, po, _m) in PROBES.items():
        E[rack].append(([port], po, CLUSTERS[t]["hvlan"], [], "probe-%s" % t, ("eth1", "eth2")))
    for n, (p1, p2, po, *_r) in NETAPP.items():
        E["storage"].append(([p1, p2], po, None, [v["svlan"] for v in CLUSTERS.values()], n, None))   # a0a-103 / a0a-203 / a0a-109
    for n, (port, po, *_r) in DNS_NTP.items():
        E["border"].append(([port], po, 401, [], n, ("eth1", "eth2")))
    E["border"].append(([FW_PORT], FW_PO, None, [t[0] for t in TRANSITS], FW, ("eth1", "eth2")))
    return E


def single_ports():
    """[(leaf, port, VLAN 301, description, peer endpoint)]: single-homed Vrf-Mgmt links"""
    S = []
    for n, (cl, role, o, rack, port, po, bleaf, bport, *_r) in NODES.items():
        if bleaf:   # a GPU worker has no BMC link
            S.append((bleaf, bport, 301, "%s-bmc" % cname(n), "%s:eth%d" % (cname(n), nics(n) + 1)))
    S.append((BASTION_GPU[2], BASTION_GPU[3], 301, "bastion-gpu-mgmt-nic", "bastion-gpu:eth3"))
    for n, (_a, _b, _po, leaf, *_r) in NETAPP.items():
        S.append((leaf, "eth10", 301, "%s-e0h-mgmt" % n, "%s:eth7" % n))
    return S


def sonic_cli(sw):
    c = ["configure terminal", "interface Loopback 0", "ip address %s/32" % LOOP[sw], "exit"]
    uplinks = ["Ethernet%d" % i for i in range(len(LEAVES))] if sw in SPINES else ["Ethernet%d" % i for i in range(len(SPINES))]
    peers = LEAVES if sw in SPINES else SPINES
    for p, peer in zip(uplinks, peers):
        c += ["interface %s" % p, "description %s-%s" % ("downlink" if sw in SPINES else "uplink", peer),
              "no shutdown", "mtu 9100", "ipv6 enable", "no ipv6 nd suppress-ra", "ipv6 nd ra-interval 5", "exit"]
    if sw in SPINES:
        asn = SPINE_ASN
    else:
        pair, asn, pid = pair_of(sw)
        border = pair == "border"
        vlans = PAIR_VLANS[pair] + ([t[0] for t in TRANSITS] if border else [])
        vrfs = sorted({VLANS[v][0] for v in PAIR_VLANS[pair]} | ({t[2] for t in TRANSITS} if border else set()) | {"Vrf-Mgmt"})
        c += ["ip anycast-mac-address %s" % ANYMAC] + ["ip vrf %s" % v for v in vrfs]
        # a returning ESI-LAG member is advertised (and carries traffic) only after LACP had time to bring it to distributing
        c += ["evpn esi-multihoming", "es-activation-delay %d" % ES_ACTIVATION_MS, "exit"]
        for v in vrfs:
            c += ["interface Vlan%d" % VRFS[v][1], "description %s" % VLAN_DESC[VRFS[v][1]], "ip vrf forwarding %s" % v, "exit"]
        c += ["interface Loopback 10", "description inband-mgmt", "ip vrf forwarding Vrf-Mgmt", "ip address %s/32" % INBAND[sw], "exit"]
        mlb_vrf = next((v for v, p in MLB_LOOP.items() if p == pair), None)
        if mlb_vrf:   # this leaf's own address in the tenant VRF, the source of its MetalLB sessions (advertised by redistribute connected)
            c += ["interface Loopback 11", "description metallb-peering-%s" % mlb_vrf.lower(), "ip vrf forwarding %s" % mlb_vrf,
                  "ip address %s/32" % MLB_LOOP_ADDR[sw], "exit"]
        for v in PAIR_VLANS[pair]:
            vrf, gw = VLANS[v]
            c += ["interface Vlan%d" % v, "description %s" % VLAN_DESC[v], "ip vrf forwarding %s" % vrf, "mtu 9100",
                  "ip anycast-address %s" % gw, "exit"]
        if border:
            idx = BORDERS.index(sw) + 1
            for tv, net, vrf, *_ in TRANSITS:
                c += ["interface Vlan%d" % tv, "description %s" % VLAN_DESC[tv], "ip vrf forwarding %s" % vrf, "ip address %s.%d/29" % (net, idx), "exit"]
            # this leaf's own transit to the BIG-IP pair, one tagged VLAN per route domain, the same /29 in every one, not stretched
            fnet, fvl = F5_TRANSIT[sw]
            for vrf, tv in fvl.items():
                c += ["interface Vlan%d" % tv, "description %s" % VLAN_DESC[tv], "ip vrf forwarding %s" % vrf, "ip address %s.1/29" % fnet, "exit"]
            for unit, (port, _o, _m) in F5.items():
                c += ["interface %s" % eth_to_sonic(port), "description %s-trunk" % unit, "mtu 9100",
                      "switchport trunk allowed Vlan %s" % ",".join(str(v) for v in fvl.values()), "no shutdown", "exit"]
        for ports, po, untagged, tagged, desc, _nic in esi_ports()[pair]:
            # every ESI-LAG runs fast LACP on both ends (the switch asks its partner for a LACPDU every second: a dead member that keeps
            # its link is out within 3 s; the nodes, hosts and the PA-VM already ask for fast)
            c += ["interface PortChannel%d fast_rate" % po, "description %s-lag" % desc, "mtu 9100"]
            c += ["switchport access Vlan %d" % untagged] if untagged else []
            c += ["switchport trunk allowed Vlan %s" % ",".join(map(str, tagged))] if tagged else []
            # "evpn ethernet-segment" opens its own sub-mode: everything else first, then one exit for the ES and one for the PortChannel
            c += ["system-mac 02:00:00:%02x:00:%02x" % (pid, po), "no shutdown",
                  "evpn ethernet-segment 00:00:00:00:00:00:00:00:%02x:%02x" % (pid, po), "exit", "exit"]
            for p in ports:
                c += ["interface %s" % eth_to_sonic(p), "description %s-lag-member" % desc, "mtu 9100", "channel-group %d" % po, "no shutdown", "exit"]
        for leaf, port, vlan, desc, _peer in single_ports():
            if leaf == sw:
                c += ["interface %s" % eth_to_sonic(port), "description %s" % desc, "no shutdown", "switchport access Vlan %d" % vlan, "exit"]
        c += ["interface vxlan vtep1", "source-ip %s" % LOOP[sw], "qos-mode pipe dscp 0"]
        c += ["map vni %d vlan %d" % (10000 + v, v) for v in vlans]   # the border transits are L2VNIs between the two borders too
        for v in vrfs:
            c += ["map vni %d vlan %d" % VRFS[v], "map vni %d vrf %s" % (VRFS[v][0], v)]
        c += ["exit"]
    c += ["router bgp %d" % asn, "router-id %s" % LOOP[sw], "log-neighbor-changes", "timers 3 9",
          "address-family ipv4 unicast", "maximum-paths 8", "network %s/32" % LOOP[sw], "exit", "address-family l2vpn evpn"]
    c += [] if sw in SPINES else ["advertise-all-vni"]
    c += ["exit"]
    for p in uplinks:
        c += ["neighbor interface %s" % p, "v6only", "remote-as external", "capability extended-nexthop", "address-family ipv4 unicast", "activate"]
        c += [] if sw in SPINES else ["allowas-in 1"]   # the pair shares one ASN: accept the partner's loopback and ES routes
        c += ["exit", "address-family l2vpn evpn", "activate"] + ([] if sw in SPINES else ["allowas-in 1"]) + ["exit", "exit"]
    c += ["exit"]
    if sw not in SPINES:
        for v in vrfs:
            c += ["router bgp %d vrf %s" % (asn, v), "router-id %s" % LOOP[sw], "log-neighbor-changes",
                  "address-family ipv4 unicast", "redistribute connected", "maximum-paths 8", "exit",
                  "address-family l2vpn evpn", "advertise ipv4 unicast", "exit"]
            if MLB_LOOP.get(v) == pair:   # MetalLB on the tenant cluster's 3 nodes, multihop from Loopback 11
                for n, k in NODES.items():
                    if k[0] in CLUSTERS and CLUSTERS[k[0]]["vrf"] == v:
                        c += ["neighbor %s.%d" % (CLUSTERS[k[0]]["net"], k[2]), "remote-as %d" % MLB_ASN, "timers 3 9", "ebgp-multihop 3",
                              "update-source interface Loopback11", "address-family ipv4 unicast", "activate", "exit", "exit"]
            if pair == "border":
                for tv, net, vrf, *_ in TRANSITS:
                    if vrf == v:
                        c += ["neighbor %s.3" % net, "remote-as %d" % FW_ASN, "timers 3 9", "address-family ipv4 unicast", "activate", "exit", "exit"]
                fnet, fvl = F5_TRANSIT[sw]
                if v in fvl:   # each BIG-IP unit peers from its own (non-floating) self IP; only the active one advertises the VIP /32
                    for unit, (_p, o, _m) in F5.items():
                        c += ["neighbor %s.%d" % (fnet, o), "remote-as %d" % F5_ASN, "timers 3 9", "address-family ipv4 unicast", "activate", "exit", "exit"]
            c += ["exit"]
    return c + ["end", "write memory"]


def rail_cli(sw):
    """a rail switch. Rail leaf r: Ethernet0-3 to rail-spine1-4, Ethernet4-11 to the NIC r of
    gpu-worker1-8 (access, VLAN r x 10), SVI 172.16.r.1/24. Pure L3 to the spines (eBGP unnumbered), the rail /24 and the loopback advertised.
    The RoCE profile is not here: `roce enable` asks to confirm and reboots, rail-roce.sh types it."""
    leaf = sw in RAIL_LEAVES
    c = ["configure terminal", "interface Loopback 0", "ip address %s/32" % RAIL_LOOP[sw], "exit"]
    peers = RAIL_SPINES if leaf else RAIL_LEAVES
    uplinks = ["Ethernet%d" % i for i in range(len(peers))]
    for p, peer in zip(uplinks, peers):
        c += ["interface %s" % p, "description %s-%s" % ("uplink" if leaf else "downlink", peer),
              "no shutdown", "mtu 9100", "ipv6 enable", "no ipv6 nd suppress-ra", "ipv6 nd ra-interval 5", "exit"]
    asn = RAIL_SPINE_ASN
    if leaf:
        r = RAIL_LEAVES.index(sw) + 1
        asn = RAIL_LEAF_ASN + r
        c += ["interface Vlan%d" % (r * 10), "description rail-%d" % r, "mtu 9100", "ip address 172.16.%d.1/24" % r, "exit"]
        for k, g in enumerate(GPU_WORKERS):
            c += ["interface Ethernet%d" % (len(RAIL_SPINES) + k), "description %s-nic%d" % (g, r), "mtu 9100",
                  "switchport access Vlan %d" % (r * 10), "no shutdown", "exit"]
    c += ["router bgp %d" % asn, "router-id %s" % RAIL_LOOP[sw], "log-neighbor-changes", "timers 3 9", "bestpath as-path multipath-relax",
          "address-family ipv4 unicast", "maximum-paths 8", "network %s/32" % RAIL_LOOP[sw]]
    c += ["network 172.16.%d.0/24" % r] if leaf else []
    c += ["exit"]
    for p in uplinks:
        c += ["neighbor interface %s" % p, "v6only", "remote-as external", "capability extended-nexthop",
              "address-family ipv4 unicast", "activate", "exit", "exit"]
    return c + ["exit", "end", "write memory"]


def links():
    L = []
    for s, sp in enumerate(RAIL_SPINES):   # every rail leaf to every rail spine
        for l, lf in enumerate(RAIL_LEAVES):
            L.append(("%s:eth%d" % (sp, l + 1), "%s:eth%d" % (lf, s + 1)))
    for k, g in enumerate(GPU_WORKERS):    # NIC r of every GPU worker (guest eth4+r) on rail-leaf r
        for r, lf in enumerate(RAIL_LEAVES, 1):
            L.append(("%s:eth%d" % (lf, len(RAIL_SPINES) + k + 1), "%s:eth%d" % (cname(g), 4 + r)))
    for i, sp in enumerate(SPINES):
        for j, lf in enumerate(LEAVES):
            L.append(("%s:eth%d" % (sp, j + 1), "%s:eth%d" % (lf, i + 1)))
    for pair, entries in esi_ports().items():
        a, b = PAIRS[pair][0]
        for ports, po, untagged, tagged, desc, nic in entries:
            if desc in NETAPP:   # e0d/e0e to leaf a, e0f/e0g to leaf b (container eth3-eth6)
                L += [("%s:%s" % (a, ports[0]), "%s:eth3" % desc), ("%s:%s" % (a, ports[1]), "%s:eth4" % desc),
                      ("%s:%s" % (b, ports[0]), "%s:eth5" % desc), ("%s:%s" % (b, ports[1]), "%s:eth6" % desc)]
            else:
                host = desc[:-5] if desc.endswith("-stor") else desc
                L += [("%s:%s" % (a, ports[0]), "%s:%s" % (host, nic[0])), ("%s:%s" % (b, ports[0]), "%s:%s" % (host, nic[1]))]
    for leaf, port, vlan, desc, peer in single_ports():
        L.append(("%s:%s" % (leaf, port), peer))
    L += [("netapp-01:eth1", "netapp-02:eth1"), ("netapp-01:eth2", "netapp-02:eth2")]   # cluster interconnect e0a/e0b (also F5)
    for unit, (port, _o, _m) in F5.items():   # 1.1 > leaf6a-border, 1.2 > leaf6b-border, 1.3 <> 1.3 HA
        L += [("%s:%s" % (BORDERS[0], port), "%s:eth1" % unit), ("%s:%s" % (BORDERS[1], port), "%s:eth2" % unit)]
    L += [("lb-f5a:eth3", "lb-f5b:eth3")]
    L += [("probe-%s:eth3" % t, "bastion-%s:eth1" % t) for t in PROBES]   # the bastion's cable, bridged by the probe host
    for vr, (ifn, ip, port, _c) in OUTSIDE.items():
        L.append(("%s:%s" % (FW, port), "pnet0:scd-fw-%s" % port))
    for n in LAN_CLIENTS:   # the users sit on the external LAN, beyond the PA-VM
        L.append(("%s:eth1" % n, "pnet0:scd-%s" % n))
    return L


LEAF_MEM = 6144   # MiB per front-end leaf VM
ES_ACTIVATION_MS = 3000   # EVPN-MH es-activation-delay, the time LACP needs to bring a returning member to distributing


def linux_nodes():
    """every linux-kind node as data {name: {image, mgmt, group, binds, env, exec}}: the clab yml is written from it, and node-recreate.sh
    re-creates one node of a running lab from it (nodes.json)"""
    N = {}
    for n, (ip, octet) in LAN_CLIENTS.items():
        N[n] = {"image": "scd/host:1", "mgmt": octet, "group": "lan-clients", "binds": ["shared:/shared:ro", "%s/host.env:/run/scd/host.env:ro" % SECRETS],
                "env": {"IP": "%s/24" % ip, "GW": LAN_GW}, "exec": ["bash /shared/lan-client-up.sh"]}
    for n, (port, po, ip, octet, role) in DNS_NTP.items():
        N[n] = {"image": "scd/host:1", "mgmt": octet, "group": "services", "binds": ["shared:/shared:ro", "%s/host.env:/run/scd/host.env:ro" % SECRETS],
                "env": {"IP": "%s/24" % ip, "GW": "10.250.0.1", "BOND": "1", "ROLE": role}, "exec": ["bash /shared/host-up.sh", "bash /shared/svc-up.sh"]}
    for t, (rack, port, po, octet) in PROBES.items():   # 10.0.2.10 in both tenants
        N["probe-%s" % t] = {"image": "scd/host:1", "mgmt": octet, "group": "probes",
                             "binds": ["shared:/shared:ro", "%s/host.env:/run/scd/host.env:ro" % SECRETS],
                             "env": {"IP": "10.0.2.10/24", "GW": "10.0.2.1", "BOND": "1", "BRIDGE": "eth3"},   # br0 = bond0 + eth3 (bastion cable)
                             "exec": ["bash /shared/host-up.sh"]}
    for t in PROBES:   # the tenant bastion installs and runs its cluster, and is the only loading path for Harbor / MinIO
        N["bastion-%s" % t] = {"image": "scd/tenant-bastion:2", "mgmt": TENANT_BASTION_MGMT[t], "group": "bastions",
                               "binds": ["%s/bastion/%s-ops.pub:/etc/scd/authorized_keys:ro" % (SECRETS, t), "agent-%s:/w/agent" % t,
                                         "/root/ocp-bin/openshift-install:/usr/local/bin/openshift-install:ro"],
                               "env": {"TENANT": t, "IP": "%s/24" % TENANT_BASTION[t], "GW": "10.0.2.1", "HARBOR_IP": "10.0.1.%d" % APP_IP["harbor"],
                                       "DNS": "10.250.0.11 10.250.0.12", "SEARCH": "%s.dc.lab dc.lab" % t,
                                       "KUBECONFIG": "/w/agent/build/auth/kubeconfig"}, "exec": []}
    N["bastion-gpu"] = {"image": "scd/bastion:1", "mgmt": BASTION_GPU[5], "group": "bastions",   # bastion-ocp in one-cluster/
                        "binds": ["agent-gpu:/w/agent", "/root/ocp-bin/openshift-install:/usr/local/bin/openshift-install:ro"],
                        "env": {"TENANT_IP": BASTION_GPU[6], "TENANT_GW": "10.0.8.1", "C_IP": BASTION_GPU[4], "DNS": "10.250.0.11 10.250.0.12",
                                "SEARCH": "gpu.dc.lab dc.lab", "KUBECONFIG": "/w/agent/build/auth/kubeconfig"}, "exec": []}
    for i, (n, (cl, role, o, rack, port, po, bleaf, bport, mem)) in enumerate(NODES.items()):
        octet = MGMT_BASE + i
        env = {"NODE_HOSTNAME": n, "NODE_IP": "%s.%d" % (CLUSTERS[cl]["net"], o), "FABRIC_NICS": str(nics(n)),
               "NODE_MAC": "50:00:30:%02x:00:00" % octet, "NODE_MTU": "9000"}
        env.update({"BMC_IP": BMC[n], "OOB_PREFIX": "24", "OOB_GW": "172.16.0.1"} if bleaf else {"BMC_IP": ""})
        env.update({"VM_MEM": str(mem), "VM_CPUS": "8", "VM_DISK": "120G", "HOLD_FILE": "/shared/release-%s" % cl})
        N[cname(n)] = {"image": "scd/rhcos-node:1", "mgmt": octet, "group": "%s-%s" % (cl, role), "cluster": cl, "hostname": n,
                       "binds": ["nodes/%s/vm:/vm" % cname(n), "agent-%s/iso:/iso:ro" % cl, "shared:/shared:ro"], "env": env, "exec": []}
    return N


def topology():
    y = ["# sonic-clos-dc (generated by gen.py, do not edit)", "name: %s" % LAB, "mgmt:", "  network: clab-%s" % LAB, "  ipv4-subnet: %s.0/24" % MGMT,
         "topology:", "  kinds:",
         # the storage pair carries 17 storage bonds + ONTAP + uplinks: 32 ports on every Dell SONiC VM
         "    dell_sonic:", "      image: vrnetlab/dell_sonic:4.6.0", "      env:", "        NUM_NICS: 32",
         "    paloalto_panos:", "      image: vrnetlab/paloalto_pa-vm:12.1.2", "      env:", "        QEMU_CPU: host", "        QEMU_MEMORY: 8192",
         "  nodes:"]
    for sw in SPINES:
        y += ["    %s: {kind: dell_sonic, mgmt-ipv4: %s.%d, group: fabric}" % (sw, MGMT, SWITCH_MGMT[sw])]
    for sw in LEAVES:   # 6 GiB (the image's default 4 GiB ran out on the leaves: SONiC panics on OOM and reboots)
        y += ['    %s: {kind: dell_sonic, mgmt-ipv4: %s.%d, group: fabric, env: {QEMU_MEMORY: "%d"}}' % (sw, MGMT, SWITCH_MGMT[sw], LEAF_MEM)]
    for sw in RAIL_SPINES + RAIL_LEAVES:   # the GPU backend
        y += ["    %s: {kind: dell_sonic, mgmt-ipv4: %s.%d, group: rails}" % (sw, MGMT, RAIL_MGMT[sw])]
    y += ["    %s: {kind: paloalto_panos, mgmt-ipv4: %s.40, group: firewall, startup-config: bootstrap/fw.xml}" % (FW, MGMT)]
    y += ["    pnet0: {kind: bridge}"]
    for unit, (_p, _o, octet) in F5.items():   # licence key and passwords only in the env file (mode 600), never in this file
        y += ["    %s:" % unit, "      kind: f5_bigip-ve", "      image: %s" % F5_IMAGE, "      mgmt-ipv4: %s.%d" % (MGMT, octet), "      group: load-balancers",
              "      env-files:", "        - %s/%s.env" % (SECRETS, unit), "      env:", '        QEMU_MEMORY: "16384"', '        QEMU_SMP: "4"']
    for n, (_a, _b, _po, _leaf, octet, nmgmt) in NETAPP.items():
        idx = list(NETAPP).index(n)   # USERNAME / PASSWORD of the ONTAP launcher in the env file, as the BIG-IP's
        y += ["    %s:" % n, "      kind: generic_vm", "      image: vrnetlab/netapp_ontap:9.17.1", "      mgmt-ipv4: %s.%d" % (MGMT, octet), "      group: storage",
              "      binds:", "        - nodes/%s/vm:/persist" % n, "      env-files:", "        - %s/netapp.env" % SECRETS, "      env:",
              '        ONTAP_CLUSTER_NAME: "%s"' % ONTAP_CLUSTER, '        ONTAP_LAG_PORTS: "e0d,e0e,e0f,e0g"', '        QEMU_MEMORY: "8192"', '        QEMU_SMP: "2"',
              '        ONTAP_CLUSTER_LIFS: "169.254.%d.1,169.254.%d.2"' % (idx + 1, idx + 1)]
        y += ['        ONTAP_ADD_NODES: "169.254.2.1"'] if idx == 0 else \
             ['        ONTAP_NODE_INDEX: "1"', '        ONTAP_SYSID: "4034389062"', '        ONTAP_SERIAL: "4034389-06-2"']   # the node-2 serial the ONTAP licence codes are for
    for n, s in linux_nodes().items():
        y += ["    %s:" % n, "      kind: linux", "      image: %s" % s["image"], "      mgmt-ipv4: %s.%d" % (MGMT, s["mgmt"]), "      group: %s" % s["group"]]
        y += ["      binds:"] + ["        - %s" % b for b in s["binds"]] if s["binds"] else []
        y += ["      env:"] + ['        %s: "%s"' % kv for kv in s["env"].items()]
        y += ["      exec:"] + ["        - %s" % e for e in s["exec"]] if s["exec"] else []
    y += ["  links:"] + ['    - endpoints: ["%s", "%s"]' % l for l in links()]
    return "\n".join(y) + "\n"


def fw_xml():
    E = lambda n, body="": "<entry name=\"%s\">%s</entry>" % (n, body)
    M = lambda *xs: "".join("<member>%s</member>" % x for x in xs)
    allow, deny = "<action><allow/></action><enable>yes</enable>", "<action><deny/></action><enable>yes</enable>"
    units = "".join(E("ae1.%d" % tv, "<tag>%d</tag><ip>%s</ip><interface-management-profile>allow-ping</interface-management-profile>" % (tv, E("%s.3/29" % net)))
                    for tv, net, *_ in TRANSITS)
    eths = E("ethernet1/1", "<aggregate-group>ae1</aggregate-group>") + E("ethernet1/2", "<aggregate-group>ae1</aggregate-group>")
    # TCP MSS clamp on the outside (1500): the fabric and the clusters run MTU 9000, and a jumbo-MTU external host (the lab host's outside bridge is 9216)
    # advertises an MSS the outside cannot carry; without the clamp its TLS handshakes to the published ingress stall
    eths += "".join(E(ifn, "<layer3><ip>%s</ip><interface-management-profile>allow-ping</interface-management-profile>"
                           "<adjust-tcp-mss><enable>yes</enable><ipv4-mss-adjustment>40</ipv4-mss-adjustment></adjust-tcp-mss></layer3>"
                           % E("%s/24" % ip))   # the console / OAuth address is NOT on the interface (PAN-OS: no second address in the subnet):
                    for ifn, ip, _p, con in OUTSIDE.values())   # the PA answers ARP for a NAT address inside the interface's subnet (proxy ARP)
    ifs = "<ethernet>%s</ethernet><aggregate-ethernet>%s</aggregate-ethernet>" % (
        eths, E("ae1", "<layer3><lacp><enable>yes</enable><mode>active</mode><transmission-rate>fast</transmission-rate></lacp><units>%s</units></layer3>" % units))
    vrs = ""
    for vr, (oif, oip, _p, _con) in OUTSIDE.items():
        tr = [t for t in TRANSITS if t[3] == vr]
        groups = imp = exp = ""
        for tv, net, vrf, _, zone, prefixes, send_default in tr:
            g = "%s-%s" % (vr[3:], vrf.lower())   # e.g. prod-vrf-prod = this VR's peering with that fabric VRF (PAN-OS: policy rule names <= 31)
            peers = "".join(E("%s-%s" % (g, b.split("-")[0]), "<peer-as>65010</peer-as><enable>yes</enable><local-address><interface>ae1.%d</interface>"
                              "<ip>%s.3/29</ip></local-address><peer-address><ip>%s.%d</ip></peer-address>" % (tv, net, net, i))
                            for i, b in enumerate(BORDERS, 1))
            groups += E(g, "<type><ebgp><remove-private-as>no</remove-private-as><import-nexthop>original</import-nexthop><export-nexthop>resolve</export-nexthop></ebgp></type>"
                        "<enable>yes</enable><peer>%s</peer>" % peers)
            imp += "".join(E("%s-import" % g + ("-%d" % k if k else ""), "<used-by>%s</used-by><match><address-prefix>%s</address-prefix></match>%s"
                             % (M(g), E(p, "<exact>%s</exact>" % ("yes" if p.endswith("/32") else "no")), allow)) for k, p in enumerate(prefixes))
            imp += E("%s-import-deny" % g, "<used-by>%s</used-by>%s" % (M(g), deny))
            if send_default:
                exp += E("%s-export-default" % g, "<used-by>%s</used-by><match><address-prefix>%s</address-prefix></match>%s" % (M(g), E("0.0.0.0/0", "<exact>yes</exact>"), allow))
            exp += E("%s-export-deny" % g, "<used-by>%s</used-by>%s" % (M(g), deny))
        bgp = ("<protocol><redist-profile>%s</redist-profile><bgp><enable>yes</enable><router-id>%s.3</router-id><local-as>%d</local-as>"
               "<install-route>yes</install-route><allow-redist-default-route>yes</allow-redist-default-route><redist-rules>%s</redist-rules>"
               "<policy><import><rules>%s</rules></import><export><rules>%s</rules></export></policy><peer-group>%s</peer-group></bgp></protocol>") % (
            E("default-route", "<priority>1</priority><action><redist/></action><filter><type>%s</type><destination>%s</destination></filter>" % (M("static"), M("0.0.0.0/0"))),
            tr[0][1], FW_ASN, E("default-route", "<address-family-identifier>ipv4</address-family-identifier><enable>yes</enable>"), imp, exp, groups)
        sr = E("default-to-lan-gateway", "<destination>0.0.0.0/0</destination><interface>%s</interface><nexthop><ip-address>%s</ip-address></nexthop><metric>10</metric>" % (oif, LAN_GW))
        vrs += E(vr, "<interface>%s</interface><routing-table><ip><static-route>%s</static-route></ip></routing-table>%s" % (
            M(*(["ae1.%d" % t[0] for t in tr] + [oif])), sr, bgp))
    zones = {}
    for tv, net, vrf, vr, zone, *_ in TRANSITS:
        zones.setdefault(zone, []).append("ae1.%d" % tv)
    zones["outside"] = [o[0] for o in OUTSIDE.values()]
    svc = E("dns-ntp-udp", "<protocol><udp><port>53,123</port></udp></protocol>") + E("dns-tcp", "<protocol><tcp><port>53</port></tcp></protocol>") + \
        E("tcp-443", "<protocol><tcp><port>443</port></tcp></protocol>") + E("egress", "<protocol><tcp><port>53,80,443</port></tcp></protocol>") + \
        E("egress-udp", "<protocol><udp><port>53,123</port></udp></protocol>") + \
        E("tcp-22", "<protocol><tcp><port>22</port></tcp></protocol>")
    # egress goes to the Internet only: the private and lab ranges are never an egress destination (a tenant packet to another VRF's
    # address must die at its own VR, not leave through the outside NAT toward the outside gateway)
    addrs = E("rfc1918-10", "<ip-netmask>10.0.0.0/8</ip-netmask>") + E("rfc1918-172", "<ip-netmask>172.16.0.0/12</ip-netmask>") + \
        E("rfc1918-192", "<ip-netmask>192.168.0.0/16</ip-netmask>")
    groups = E("private-ranges", "<static>%s</static>" % M("rfc1918-10", "rfc1918-172", "rfc1918-192"))

    def rule(name, fz, tz, src, dst, svcs, action="allow", extra="", negate_dst=False):
        return E(name, "<from>%s</from><to>%s</to><source>%s</source><destination>%s</destination>%s<application>%s</application><service>%s</service>"
                 "<action>%s</action>%s<log-end>yes</log-end>" % (M(*fz), M(*tz), M(*src), M(*dst), "<negate-destination>yes</negate-destination>" if negate_dst else "",
                                                                  M("any"), M(*svcs), action, extra))
    dns, tenant_net = [v[2] for v in DNS_NTP.values()], ["10.0.0.0/16"]
    gpu_net = ["%s.0/24" % CLUSTERS["gpu"]["net"]]
    sec = rule("prod-dev-to-dns-ntp", ["prod", "dev"], ["svc"], tenant_net, dns, ["dns-ntp-udp", "dns-tcp"])
    sec += rule("mgmt-to-dns-ntp", ["mgmt"], ["svc"], ["172.16.0.0/16"], dns, ["dns-ntp-udp", "dns-tcp"])
    sec += rule("gpu-to-dns-ntp", ["gpu"], ["svc"], gpu_net, dns, ["dns-ntp-udp", "dns-tcp"])   # the gpu cluster in vr-shared
    # each tenant cluster pulls its images (quay.io, registry.redhat.io), charts and updates through its OWN VR (SNAT .142 / .143)
    sec += rule("prod-dev-to-internet", ["prod", "dev"], ["outside"], tenant_net, ["private-ranges"], ["egress", "egress-udp"], negate_dst=True)
    sec += rule("dns-ntp-to-internet", ["svc"], ["outside"], ["10.250.0.0/24"], ["private-ranges"], ["egress", "egress-udp"], negate_dst=True)
    sec += rule("gpu-to-internet", ["gpu"], ["outside"], gpu_net, ["private-ranges"], ["egress", "egress-udp"], negate_dst=True)
    # the external LAN > each tenant on its VR's addresses: the apps (BIG-IP) and its cluster's console / OAuth; matched on the
    # pre-NAT address and the post-NAT zone
    for t, vr in TENANT_VR.items():
        sec += rule("lan-to-%s-https" % t, ["outside"], [t], ["any"], [OUTSIDE[vr][1]], ["tcp-443"])
        sec += rule("lan-to-%s-console" % t, ["outside"], [t], ["any"], [OUTSIDE[vr][3]], ["tcp-443"])
    for t, vr in TENANT_VR.items():   # SSH to the tenant's bastion (the only load path into its Harbor and MinIO), nothing else on port 22
        sec += rule("lan-to-%s-bastion-ssh" % t, ["outside"], [t], ["any"], [OUTSIDE[vr][1]], ["tcp-22"])
    sec += rule("deny-prod-dev", ["prod"], ["dev"], ["any"], ["any"], ["any"], "deny", "<rule-type>interzone</rule-type>")
    sec += rule("deny-dev-prod", ["dev"], ["prod"], ["any"], ["any"], ["any"], "deny", "<rule-type>interzone</rule-type>")
    sec += rule("allow-intrazone", ["any"], ["any"], ["any"], ["any"], ["any"], extra="<rule-type>intrazone</rule-type>")
    sec += rule("deny-all-log", ["any"], ["any"], ["any"], ["any"], ["any"], "deny", "<rule-type>interzone</rule-type>")

    def snat(name, fz, tz, iface, ip):   # source NAT to the egress interface's own address, pinned to that interface
        return E(name, "<from>%s</from><to>%s</to><to-interface>%s</to-interface><source>%s</source><destination>%s</destination><service>any</service>"
                 "<source-translation><dynamic-ip-and-port><interface-address><interface>%s</interface><ip>%s</ip></interface-address>"
                 "</dynamic-ip-and-port></source-translation>" % (M(*fz), M(tz), iface, M("any"), M("any"), iface, ip))

    def dnat(name, oif, pub, inside, port=443):
        return E(name, "<from>%s</from><to>%s</to><to-interface>%s</to-interface><source>%s</source><destination>%s</destination><service>tcp-%d</service>"
                 "<destination-translation><translated-address>%s</translated-address><translated-port>%d</translated-port></destination-translation>"
                 % (M("outside"), M("outside"), oif, M("any"), M(pub), port, inside, port))
    nats = ""
    for t, vr in TENANT_VR.items():
        nats += dnat("lan-to-%s-apps" % t, OUTSIDE[vr][0], OUTSIDE[vr][1], F5_VIP)                         # .142 / .143 > the BIG-IP VIP
        nats += dnat("lan-to-%s-bastion" % t, OUTSIDE[vr][0], OUTSIDE[vr][1], TENANT_BASTION[t], 22)        # .142 / .143:22 > bastion-<t>
        nats += dnat("lan-to-%s-console" % t, OUTSIDE[vr][0], OUTSIDE[vr][3], CLUSTERS[t]["ingress"])       # .144 / .145 > its router
    for tv, net, vrf, vr, zone, *_ in TRANSITS:
        if vr != "vr-shared":   # inside a tenant VR: to the shared Vrf-Svc (prod-to-dns-ntp)
            t = vr[3:]
            nats += snat("%s-to-dns-ntp" % t if zone == "svc" else "%s-to-%s-snat" % (t, zone), [t], zone, "ae1.%d" % tv, "%s.3/29" % net)
    for vr, (oif, oip, _p, _c) in OUTSIDE.items():
        nats += snat("%s-snat-internet" % vr[3:], ["svc", "mgmt", "gpu"] if vr == "vr-shared" else [vr[3:]], "outside", oif, "%s/24" % oip)
    allif = ["ae1.%d" % t[0] for t in TRANSITS] + [o[0] for o in OUTSIDE.values()]
    return ("<config version=\"12.1.0\" urldb=\"paloaltonetworks\" detail-version=\"12.1.2\"><devices><entry name=\"localhost.localdomain\"><network>"
            "<profiles><interface-management-profile>%s</interface-management-profile></profiles><interface>%s</interface>"
            "<virtual-router>%s</virtual-router></network>"
            "<deviceconfig><system><hostname>%s</hostname><timezone>UTC</timezone></system></deviceconfig>"
            "<vsys><entry name=\"vsys1\"><import><network><interface>%s</interface></network></import><zone>%s</zone><service>%s</service>"
            "<address>%s</address><address-group>%s</address-group>"
            "<rulebase><security><rules>%s</rules></security><nat><rules>%s</rules></nat></rulebase></entry></vsys>"
            "</entry></devices></config>\n") % (
        E("allow-ping", "<ping>yes</ping>"), ifs, vrs, FW, M(*allif),
        "".join(E(z, "<network><layer3>%s</layer3></network>" % M(*i)) for z, i in zones.items()), svc, addrs, groups, sec, nats)


# GPU worker n's NIC on rail r = 172.16.r.(10 + n)
RAIL_ADDR = {"%s-rail%d" % (g, r): "172.16.%d.%d" % (r, 10 + int(g[10:])) for g in GPU_WORKERS for r in range(1, RAILS + 1)}


def zone():
    """one dc.lab zone for every VRF. prod and dev answer the SAME addresses under different names: each tenant resolves its own
    names; a tenant asking for the other's gets an address that in its own VRF is its own service, never the other's."""
    ns = list(DNS_NTP)
    r = ["$TTL 60", "@ IN SOA %s.dc.lab. admin.dc.lab. ( SERIAL 300 60 86400 60 )" % ns[0]] + ["@ IN NS %s.dc.lab." % n for n in ns]
    r += ["%s IN A %s" % (n, v[2]) for n, v in DNS_NTP.items()]
    for cl, v in CLUSTERS.items():
        r += ["api.%s IN A %s" % (cl, v["api"]), "api-int.%s IN A %s" % (cl, v["api"]), "*.apps.%s IN A %s" % (cl, v["ingress"])]
        # the node's FQDN = the name it advertises over LLDP
        r += ["%s.%s IN A %s.%d" % (n, cl, v["net"], k[2]) for n, k in NODES.items() if k[0] == cl]
        r += ["%s.storage.%s IN A %s.%d" % (n, cl, v["snet"], k[2]) for n, k in NODES.items() if k[0] == cl]
        r += ["%s.storage.%s IN A %s.%d" % (v["svm"], cl, v["snet"], SVM_LIF["mgmt"])]
    r += ["bastion.gpu IN A %s" % BASTION_GPU[6]]
    for t in TENANTS:   # the tenant's apps on the BIG-IP VIP (the same address in each tenant VRF: rd-prod / rd-dev)
        # one record per published app, never *.<t>: <t>.dc.lab is also the tenant cluster's domain, and the agent installer refuses
        # a wildcard there (validation dns-wildcard-not-configured); it would also answer for names the cluster owns
        r += ["%s.%s IN A %s" % (a, t, F5_VIP) for a in APP_IP]
        r += ["probe.%s IN A 10.0.2.10" % t, "bastion.%s IN A %s" % (t, TENANT_BASTION[t])]
    r += ["%s-bmc.mgmt IN A %s" % (cname(n), a) for n, a in BMC.items()] + ["bastion-gpu.mgmt IN A %s" % BASTION_GPU[4]]
    r += ["%s.mgmt IN A %s" % (ONTAP_CLUSTER, ONTAP_CMGMT)] + ["%s.mgmt IN A %s" % (n, v[5]) for n, v in NETAPP.items()]
    r += ["%s.mgmt IN A %s" % (sw, INBAND[sw]) for sw in LEAVES]
    r += ["%s.rails IN A %s" % (n, ip) for n, ip in RAIL_ADDR.items()]   # gpu-worker<n>-rail<r>.rails, the GPU NICs by rail
    r += ["model IN A %s" % F5_MODEL_VIP]   # the model API, the same VIP in rd-prod and rd-dev
    return "\n".join(r) + "\n"


def agent(cl):
    """the agent-based install of one cluster (compact for prod / dev: 3 schedulable control-plane nodes, 0 workers). The pull secret and
    the SSH key are read from root's files at run time and written only into agent-<cl>/ (mode 600 by make-iso.sh), never printed."""
    v = CLUSTERS[cl]
    pull = open("/root/pull-secret.json").read().strip()
    key = open(os.path.expanduser("~/.ssh/id_ed25519.pub")).read().strip()
    mine = [(i, n, k) for i, (n, k) in enumerate(NODES.items()) if k[0] == cl]
    install = {"apiVersion": "v1", "baseDomain": "dc.lab", "metadata": {"name": cl},
               "compute": [{"name": "worker", "replicas": sum(1 for _i, _n, k in mine if k[1] == "worker")}],
               "controlPlane": {"name": "master", "replicas": sum(1 for _i, _n, k in mine if k[1] == "master")},
               "networking": {"networkType": "OVNKubernetes", "clusterNetwork": [{"cidr": "10.128.0.0/14", "hostPrefix": 23}],
                              "serviceNetwork": ["172.30.0.0/16"], "machineNetwork": [{"cidr": "%s.0/24" % v["net"]}]},   # one only
               "platform": {"baremetal": {"apiVIPs": [v["api"]], "ingressVIPs": [v["ingress"]]}},
               "pullSecret": pull, "sshKey": key}
    hosts = []
    for i, n, (_cl, role, o, *_r) in mine:
        octet = MGMT_BASE + i
        mac = lambda k: "50:00:30:%02x:00:%02x" % (octet, 0x10 + k)   # the wrapper's guest NIC k = :10+k (k=0 management)
        mgmt = "%s.%d" % (MGMT, octet)
        ip4 = lambda a: {"enabled": True, "dhcp": False, "address": [{"ip": a, "prefix-length": 24}]}
        nm = [{"name": "eth0", "type": "ethernet", "state": "up", "ipv4": ip4(mgmt), "ipv6": {"enabled": False}}]
        nm += [{"name": "eth%d" % k, "type": "ethernet", "state": "up", "mtu": 9000} for k in (1, 2, 3, 4)]
        lacp = lambda ports: {"mode": "802.3ad", "port": ports, "options": {"miimon": "100", "lacp_rate": "fast", "xmit_hash_policy": "layer3+4"}}
        # bond0 = the node network (the cluster's own VLAN, untagged on the rack pair), bond1 = its SVM's storage VLAN (untagged)
        nm += [{"name": "bond0", "type": "bond", "state": "up", "mtu": 9000, "link-aggregation": lacp(["eth1", "eth2"]),
                "ipv4": ip4("%s.%d" % (v["net"], o)), "ipv6": {"enabled": False}},
               {"name": "bond1", "type": "bond", "state": "up", "mtu": 9000, "link-aggregation": lacp(["eth3", "eth4"]),
                "ipv4": ip4("%s.%d" % (v["snet"], o)), "ipv6": {"enabled": False}}]
        routes = [{"destination": "0.0.0.0/0", "next-hop-address": "%s.1" % v["net"], "next-hop-interface": "bond0", "table-id": 254},
                  {"destination": "0.0.0.0/0", "next-hop-address": "%s.1" % MGMT, "next-hop-interface": "eth0", "table-id": 200},
                  {"destination": "%s.0/24" % MGMT, "next-hop-interface": "eth0", "table-id": 200}]
        rules = [{"ip-from": "%s/32" % mgmt, "route-table": 200}]
        if n in GPU_WORKERS:   # the rails come up WITHOUT addresses at install; rail_nncp() addresses them on day 2
            for r in range(1, RAILS + 1):
                nm += [{"name": "eth%d" % (4 + r), "type": "ethernet", "state": "up", "mtu": 9000, "ipv4": {"enabled": False}, "ipv6": {"enabled": False}}]
        hosts.append({"hostname": n, "role": role,
                      "interfaces": [{"name": "eth%d" % k, "macAddress": mac(k)} for k in range(nics(n) + 1)],
                      "networkConfig": {"interfaces": nm, "routes": {"config": routes}, "route-rules": {"config": rules},
                                        "dns-resolver": {"config": {"server": ["10.250.0.11", "10.250.0.12"], "search": ["%s.dc.lab" % cl, "dc.lab"]}}},
                      "rootDeviceHints": {"deviceName": "/dev/vda"}})
    return install, {"apiVersion": "v1beta1", "kind": "AgentConfig", "metadata": {"name": cl},
                     "rendezvousIP": "%s.%d" % (v["net"], NODES[RENDEZVOUS[cl]][2]),
                     "additionalNTPSources": ["10.250.0.11", "10.250.0.12"], "hosts": hosts}


def rail_nncp():
    """one NodeNetworkConfigurationPolicy per GPU worker of cluster gpu: rail r on guest eth(4+r) = 172.16.r.(10+n)/24, the other rails
    through that rail's gateway in table 100+r, chosen by source address (production shape: no rail route in the main table)"""
    docs = []
    for g in GPU_WORKERS:
        n = int(g[10:]); ifs, routes, rules = [], [], []
        for r in range(1, RAILS + 1):   # the installed node keeps the kernel names: guest NIC k = enp0s(k+1), so rail r = enp0s(5+r)
            a, dev = "172.16.%d.%d" % (r, 10 + n), "enp0s%d" % (5 + r)
            ifs.append({"name": dev, "type": "ethernet", "state": "up", "mtu": 9000,
                        "ipv4": {"enabled": True, "dhcp": False, "address": [{"ip": a, "prefix-length": 24}]}, "ipv6": {"enabled": False}})
            routes += [{"destination": "172.16.0.0/16", "next-hop-address": "172.16.%d.1" % r, "next-hop-interface": dev, "table-id": 100 + r},
                       {"destination": "172.16.%d.0/24" % r, "next-hop-interface": dev, "table-id": 100 + r}]
            rules.append({"ip-from": "%s/32" % a, "route-table": 100 + r})
        docs.append({"apiVersion": "nmstate.io/v1", "kind": "NodeNetworkConfigurationPolicy", "metadata": {"name": "rails-%s" % g},
                     "spec": {"nodeSelector": {"kubernetes.io/hostname": g},
                              "desiredState": {"interfaces": ifs, "routes": {"config": routes}, "route-rules": {"config": rules}}}})
    return "\n---\n".join(json.dumps(d) for d in docs) + "\n"


def f5_env():   # what f5.sh needs, as shell variables (no secret here)
    g = CLUSTERS["gpu"]
    r = ["# f5.sh parameters (gen.py)", 'UNITS="%s"' % " ".join(F5), "F5_ASN=%d" % F5_ASN, "BORDER_ASN=%d" % PAIRS["border"][1], "VIP=%s" % F5_VIP,
         "MODEL_VIP=%s" % F5_MODEL_VIP, "MODEL_POOL=%s" % g["ingress"], "MODEL_HOST=llm.apps.gpu.dc.lab",
         'TENANTS="%s"' % " ".join(TENANTS), "PARENT=gpu"]
    # each tenant's app addresses, the SAME in rd-prod and rd-dev (10.0.1.200-.204): <app>:<octet>:<port>
    r += ["APP_NET_%s=%s" % (t, CLUSTERS[t]["net"]) for t in TENANTS]
    r += ['APPS="whoami:%d:8080 chat:%d:8080 inference:%d:80 harbor:%d:443 minio:%d:9001"' % tuple(APP_IP[a] for a in ("whoami", "chat", "inference", "harbor", "minio"))]
    r += ['MGMT_%s=%s.%d' % (u.replace("-", "_"), MGMT, v[2]) for u, v in F5.items()]
    r += ['OCTET_%s=%d' % (u.replace("-", "_"), v[1]) for u, v in F5.items()]
    for i, b in enumerate(BORDERS, 1):   # link 1.<i> goes to border i
        net, vl = F5_TRANSIT[b]
        r += ["NET_%d=%s" % (i, net), 'BORDER_%d=%s' % (i, b)] + ["TAG_%d_%s=%d" % (i, cl, vl[F5_RD[cl][2]]) for cl in F5_RD]
    r += ["RD_%s=%d" % (cl, v[1]) for cl, v in F5_RD.items()] + ['RDNAME_%s=%s' % (cl, v[0]) for cl, v in F5_RD.items()]
    return "\n".join(r) + "\n"


def ontap_env():   # ontap-setup.sh parameters; per SVM: IPspace, VLAN, storage /24, the cluster's node addresses (NFS clients)
    r = ["# ontap-setup.sh parameters (gen.py)", "ONTAP_MGMT=%s.%d" % (MGMT, NETAPP["netapp-01"][4]), "CLUSTER=%s" % ONTAP_CLUSTER, "CMGMT=%s" % ONTAP_CMGMT,
         'NODE_MGMT="%s"' % " ".join(v[5] for v in NETAPP.values()), 'SVMS="%s"' % " ".join(CLUSTERS)]
    for cl, v in CLUSTERS.items():
        r += ['SVM_%s="%s %s %d %s %d %d %d %d %d %s.0/24"' % (cl, v["svm"], v["ipspace"], v["svlan"], v["snet"], SVM_LIF["mgmt"], SVM_LIF["iscsi"][0],
                                                            SVM_LIF["iscsi"][1], SVM_LIF["nfs"][0], SVM_LIF["nfs"][1], v["snet"])]
    return "\n".join(r) + "\n"


def mgmt_hosts():
    r = ["# %s containerlab management addresses (gen.py); node lines: <ip> <container> <cluster> <hostname>" % LAB]
    r += ["%s.%d %s" % (MGMT, SWITCH_MGMT[s], s) for s in SPINES + LEAVES]
    r += ["%s.40 %s" % (MGMT, FW)] + ["%s.%d %s" % (MGMT, v[4], n) for n, v in NETAPP.items()] + ["%s.%d %s" % (MGMT, v[3], n) for n, v in DNS_NTP.items()]
    r += ["%s.%d probe-%s" % (MGMT, v[3], t) for t, v in PROBES.items()] + ["%s.%d bastion-gpu" % (MGMT, BASTION_GPU[5])]
    r += ["%s.%d bastion-%s" % (MGMT, TENANT_BASTION_MGMT[t], t) for t in PROBES]
    r += ["%s.%d %s" % (MGMT, v[2], u) for u, v in F5.items()] + ["%s.%d %s" % (MGMT, v[1], n) for n, v in LAN_CLIENTS.items()]
    r += ["%s.%d %s %s %s" % (MGMT, MGMT_BASE + i, cname(n), NODES[n][0], n) for i, n in enumerate(NODES)]
    r += ["%s.%d %s" % (MGMT, RAIL_MGMT[s], s) for s in RAIL_SPINES + RAIL_LEAVES]
    return "\n".join(r) + "\n"


if __name__ == "__main__":
    os.chdir(os.path.dirname(os.path.abspath(__file__)))
    for d in ("configs", "bootstrap", "shared") + tuple("agent-%s/iso" % cl for cl in CLUSTERS):
        os.makedirs(d, exist_ok=True)
    open("%s.clab.yml" % LAB, "w").write(topology())
    open("nodes.json", "w").write(json.dumps({"mgmt": MGMT, "nodes": linux_nodes()}, indent=1) + "\n")
    for sw in SPINES + LEAVES:
        open("configs/%s.cli" % sw, "w").write("\n".join(sonic_cli(sw)) + "\n")
    for sw in RAIL_SPINES + RAIL_LEAVES:
        open("configs/%s.cli" % sw, "w").write("\n".join(rail_cli(sw)) + "\n")
    open("bootstrap/fw.xml", "w").write(fw_xml())
    open("shared/dc.lab.zone", "w").write(zone())
    open("mgmt-hosts.txt", "w").write(mgmt_hosts())
    own = [(v[1], vr) for vr, v in OUTSIDE.items()] + [(v[3], vr + "-console") for vr, v in OUTSIDE.items() if v[3]] + [(v[0], n) for n, v in LAN_CLIENTS.items()]
    open("outside.txt", "w").write("".join("%s %s\n" % o for o in own))   # every external-LAN address the lab owns (up.sh: must be free)
    open("ontap.env", "w").write(ontap_env())
    open("f5.env", "w").write(f5_env())
    open("manifests-day2-rails.yaml", "w").write(rail_nncp())   # platform.sh gpu nmstate applies it
    if os.path.exists("/root/pull-secret.json"):
        for cl in CLUSTERS:
            ic, ac = agent(cl)
            old = os.umask(0o077)   # the install-config carries the pull secret: root only
            open("agent-%s/install-config.yaml" % cl, "w").write(json.dumps(ic, indent=1) + "\n")
            open("agent-%s/agent-config.yaml" % cl, "w").write(json.dumps(ac, indent=1) + "\n")
            os.umask(old)
    print("gen.py: %d switches (%d rail), %d nodes in %d clusters (%s), %d links, fw.xml, zone, agent configs" % (
        len(SPINES + LEAVES + RAIL_SPINES + RAIL_LEAVES), len(RAIL_SPINES + RAIL_LEAVES), len(NODES), len(CLUSTERS),
        " ".join("%s %d" % (c, sum(1 for k in NODES.values() if k[0] == c)) for c in CLUSTERS), len(links())))
