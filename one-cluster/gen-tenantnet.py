#!/usr/bin/env python3
"""gen-tenantnet.py <part>: the tenant network layer of cluster ocp, printed as one multi-document YAML stream for
`oc apply -f -` through bastion-ocp (tenant-net.sh). JSON documents (valid YAML).
Parts:
  udn          per tenant: its namespaces (prod-apps, prod-platform ...) labelled for a primary UDN, and a ClusterUserDefinedNetwork (layer 3)
  frr          per tenant: an FRRConfiguration on its 3 workers: eBGP from the Linux VRF vrf-<tenant> (bond0.<lb vlan>) to the rack leaves
  attach       per tenant worker: bond0.<lb vlan> enslaved to OVN-K's VRF tenant-<tenant> (after udn)
  vrf-join     (once) DaemonSet tenant-vrf-join: keeps bond0.111 in tenant-prod and bond0.211 in tenant-dev on every node
  ra           per tenant: RouteAdvertisements of its UDN pod network, targetVRF auto = tenant-<tenant> (VRF-lite)
  metallb      MetalLB on the network operator's FRR-K8s: per tenant a pool .200-.209 and peers in tenant-<t> per rack
  shards       per tenant: an IngressController on its workers' host network, domain <tenant>.dc.lab
  tuned        tcp_l3mdev_accept=1 on the tenant workers
The tenant workers carry the taint scd/tenant=<tenant>:NoSchedule (post-install.sh roles); everything here tolerates it where it must run there.
"""
import json, sys

PART = sys.argv[1]
OCP_ASN = 65030
T = {   # tenant: (UDN subnet, LB VLAN /24 prefix, leaf ASN, leaf a, leaf b, shard VIP, worker host octets)
    "prod": ("10.10.64.0/18", "10.10.1", 65003, "10.10.1.2", "10.10.1.3", "10.10.1.200", (21, 22, 23)),
    "dev": ("10.20.64.0/18", "10.20.1", 65004, "10.20.1.2", "10.20.1.3", "10.20.1.200", (31, 32, 33)),
}
NS = ("apps", "platform")
IMG_AISIM = "image-registry.openshift-image-registry.svc:5000/scd-images/ai-sim:1"   # has iproute2
# every node's host octet (gen.py NODES) and its rack's two leaf addresses in the tenant VLANs (gen.py LB_LEAF_OCTET)
NODE_OCTET = dict([("master%d" % i, 10 + i) for i in (1, 2, 3)] + [("prod-worker%d" % i, 20 + i) for i in (1, 2, 3)] +
                  [("dev-worker%d" % i, 30 + i) for i in (1, 2, 3)] + [("gpu-worker%d" % i, 40 + i) for i in range(1, 9)])
RACK_LEAVES = {"rack1": (4, 5), "rack2": (6, 7), "rack3": (2, 3), "rack4": (8, 9)}
RACK_ASN = {"rack1": 65001, "rack2": 65002, "rack3": 65003, "rack4": 65004}    # the tenant's namespaces: <tenant>-apps (whoami, chat), <tenant>-platform (MinIO, Harbor, LiteLLM, APISIX)
docs = []
add = docs.append
TOL = lambda t: [{"key": "scd/tenant", "operator": "Equal", "value": t, "effect": "NoSchedule"}]
ON = lambda t: {"scd/tenant": t}

for t, (udn, lb, lasn, la, lb_b, vip, octs) in T.items():
    if PART == "udn":   # the label must be on the namespace when it is created (OVN-K only binds a primary UDN at creation)
        for n in NS:
            add({"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": "%s-%s" % (t, n),
                 "labels": {"k8s.ovn.org/primary-user-defined-network": "", "scd/tenant": t}}})
        # OVN-K names the node VRF of a UDN after it: never "dev" (iproute2 keyword), so tenant-<t>
        add({"apiVersion": "k8s.ovn.org/v1", "kind": "ClusterUserDefinedNetwork", "metadata": {"name": "tenant-" + t, "labels": {"scd/tenant": t}},
             "spec": {"namespaceSelector": {"matchLabels": {"scd/tenant": t}},
                      "network": {"topology": "Layer3", "layer3": {"role": "Primary", "subnets": [{"cidr": udn, "hostSubnet": 24}]}}}})
    elif PART == "frr":   # every node peers in tenant-prod AND tenant-dev with its rack's two leaves (nodes labelled scd/rack, platform.sh zones)
        if t == "prod":
            for rack, (a, b) in RACK_LEAVES.items():
                routers = [{"asn": OCP_ASN, "vrf": "tenant-" + tt, "neighbors": [
                               {"address": "%s.1.%d" % (pp, x), "asn": RACK_ASN[rack], "holdTime": "9s", "keepaliveTime": "3s",
                                "toReceive": {"allowed": {"mode": "filtered", "prefixes": [{"prefix": "0.0.0.0/0"}]}}} for x in (a, b)]}
                           for tt, pp in (("prod", "10.10"), ("dev", "10.20"))]
                add({"apiVersion": "frrk8s.metallb.io/v1beta1", "kind": "FRRConfiguration",
                     "metadata": {"name": "tenant-vrfs-%s" % rack, "namespace": "openshift-frr-k8s", "labels": {"scd/tenant-routing": "all"}},
                     "spec": {"nodeSelector": {"matchLabels": {"scd/rack": rack}}, "bgp": {"routers": routers}}})
    elif PART == "attach":   # not used: NMState does not manage bond0.111 / bond0.211, tenant-vrf-join creates them (vrf-join)
        sys.exit("attach: not used (tenant-vrf-join owns the tenant VLANs)")
    elif PART == "vrf-join":   # OVN-K owns tenant-<t>; this DaemonSet owns bond0.<vlan> and keeps it in its VRF on every node
        if t == "prod":
            # it also keeps the tenant subnet's connected route inside the VRF: NetworkManager owns the address and drops "its" prefix route when
            # the VLAN is moved into a VRF it does not manage; and IPv4 forwarding on the VLAN: OVN-K's
            # restricted forwarding mode enables it per interface, and a VLAN can come up with 0, so the leaves' traffic to
            # the UDN pods and LoadBalancer addresses dies on the node (IpInAddrErrors)
            # it is the single owner of the two VLANs: it creates bond0.111 / bond0.211 (MTU 9000) once OVN-K's VRF exists, puts each in its
            # VRF, gives it the node's host octet (the octet of the node's br-ex address in 10.0.1.0/24), and keeps forwarding and the connected
            # route; NMState does not manage them (nmstate verified a VLAN outside its VRF while this loop put it back, NNCPs Degraded)
            script = ("while true; do h=$(ip -4 -o addr show br-ex | awk '{print $4}' | grep '^10[.]0[.]1[.]' | head -1 | cut -d/ -f1 | cut -d. -f4); "
                      "[ -n \"$h\" ] || { sleep 15; continue; }; "
                      "for p in 111:tenant-prod:10.10.1.0/24 211:tenant-dev:10.20.1.0/24; do id=${p%%:*}; v=bond0.$id; r=${p#*:}; f=${r%%:*}; n=${r#*:}; "
                      "ip link show $f >/dev/null 2>&1 || continue; "
                      "ip link show $v >/dev/null 2>&1 || { ip link add link bond0 name $v mtu 9000 type vlan id $id && echo \"$(date -u +%FT%TZ) $v created\"; }; "
                      "ip link set $v mtu 9000 up; "
                      "ip -o link show $v | grep -q \" master $f \" || { ip link set $v master $f && echo \"$(date -u +%FT%TZ) $v -> $f\"; }; "
                      "a=${n%.0/24}.$h; ip -4 -o addr show $v | grep -q \" $a/24 \" || { ip addr replace $a/24 dev $v && echo \"$(date -u +%FT%TZ) $v $a/24\"; }; "
                      "w=/proc/sys/net/ipv4/conf/$v/forwarding; [ \"$(cat $w)\" = 1 ] || { echo 1 > $w && echo \"$(date -u +%FT%TZ) $v forwarding on\"; }; "
                      "ip route show vrf $f | grep -q \"^$n dev $v \" || { ip route replace $n dev $v vrf $f proto kernel scope link src $a && echo \"$(date -u +%FT%TZ) $n dev $v in $f\"; }; "
                      "done; sleep 15; done")
            add({"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": "scd-system"}})
            add({"apiVersion": "v1", "kind": "ServiceAccount", "metadata": {"name": "tenant-vrf-join", "namespace": "scd-system"}})
            add({"apiVersion": "apps/v1", "kind": "DaemonSet", "metadata": {"name": "tenant-vrf-join", "namespace": "scd-system"},
                 "spec": {"selector": {"matchLabels": {"app": "tenant-vrf-join"}},
                          "template": {"metadata": {"labels": {"app": "tenant-vrf-join"}},
                                       "spec": {"serviceAccountName": "tenant-vrf-join", "hostNetwork": True, "priorityClassName": "system-node-critical",
                                                "tolerations": [{"operator": "Exists"}],
                                                "containers": [{"name": "join", "image": IMG_AISIM, "command": ["sh", "-c", script],
                                                                "securityContext": {"privileged": True},
                                                                "resources": {"requests": {"cpu": "5m", "memory": "16Mi"}}}]}}}})
    elif PART == "ra":
        add({"apiVersion": "k8s.ovn.org/v1", "kind": "RouteAdvertisements", "metadata": {"name": "udn-%s" % t},
             "spec": {"targetVRF": "auto", "advertisements": ["PodNetwork"], "nodeSelector": {},   # PodNetwork must be advertised on every node (API rule)
                      "frrConfigurationSelector": {"matchLabels": {"scd/tenant-routing": "all"}},
                      "networkSelectors": [{"networkSelectionType": "ClusterUserDefinedNetworks",
                                            "clusterUserDefinedNetworkSelector": {"networkSelector": {"matchLabels": {"scd/tenant": t}}}}]}})
    elif PART == "metallb":   # a LoadBalancer address per tenant app, inside the tenant VRF: MetalLB (on the network operator's FRR-K8s)
        # announces it from tenant-<t> to each node's rack leaves; the same neighbours and timers as the per-rack FRR configs, so FRR-K8s
        # merges them without a conflict (a conflicting duplicate makes the sessions flap)
        p, lbv = {"prod": ("10.10", 111), "dev": ("10.20", 211)}[t]
        add({"apiVersion": "metallb.io/v1beta1", "kind": "IPAddressPool", "metadata": {"name": t, "namespace": "metallb-system"},
             "spec": {"addresses": ["%s.1.200-%s.1.209" % (p, p)], "autoAssign": True,
                      "serviceAllocation": {"namespaceSelectors": [{"matchLabels": {"scd/tenant": t}}]}}})
        peers = []
        for rack, (a, b) in RACK_LEAVES.items():
            for side, x in (("a", a), ("b", b)):
                n = "%s-%s-leaf%s" % (t, rack, side); peers.append(n)
                add({"apiVersion": "metallb.io/v1beta2", "kind": "BGPPeer", "metadata": {"name": n, "namespace": "metallb-system"},
                     "spec": {"myASN": OCP_ASN, "peerASN": RACK_ASN[rack], "peerAddress": "%s.1.%d" % (p, x), "vrf": "tenant-" + t,
                              "holdTime": "9s", "keepaliveTime": "3s", "nodeSelectors": [{"matchLabels": {"scd/rack": rack}}]}})
        add({"apiVersion": "metallb.io/v1beta1", "kind": "BGPAdvertisement", "metadata": {"name": t, "namespace": "metallb-system"},
             "spec": {"ipAddressPools": [t], "peers": peers}})
        if t == "prod":
            docs.insert(0, {"apiVersion": "metallb.io/v1beta1", "kind": "MetalLB", "metadata": {"name": "metallb", "namespace": "metallb-system"},
                            "spec": {"bgpBackend": "frr-k8s-external", "speakerTolerations": [{"operator": "Exists"}]}})
    elif PART == "shards":   # the tenant's router on its 3 workers' host network: a connection arriving through vrf-<t> (bond0.<lb vlan>)
        # is accepted by HAProxy in the default VRF (Tuned scd-tenant-vrf: tcp_l3mdev_accept=1) and answered back through vrf-<t>; the BIG-IP
        # rd-<t> pool lists the workers' tenant addresses. A MetalLB address cannot work here: the VRF has no route to the cluster network
        add({"apiVersion": "operator.openshift.io/v1", "kind": "IngressController", "metadata": {"name": t, "namespace": "openshift-ingress-operator"},
             "spec": {"domain": "%s.dc.lab" % t, "replicas": 3,
                      "namespaceSelector": {"matchLabels": {"scd/tenant": t}},
                      "nodePlacement": {"nodeSelector": {"matchLabels": ON(t)}, "tolerations": TOL(t)},
                      "endpointPublishingStrategy": {"type": "HostNetwork", "hostNetwork": {"httpPort": 80, "httpsPort": 443, "statsPort": 1936}}}})
    elif PART == "tuned":   # the sysctl the host-network shard needs, live on the tenant workers only (no reboot)
        if t == "prod":
            add({"apiVersion": "tuned.openshift.io/v1", "kind": "Tuned", "metadata": {"name": "scd-tenant-vrf", "namespace": "openshift-cluster-node-tuning-operator"},
                 "spec": {"profile": [{"name": "scd-tenant-vrf", "data": "[main]\nsummary=sockets in the default VRF answer connections that arrive through the tenant VRF\ninclude=openshift-node\n[sysctl]\nnet.ipv4.tcp_l3mdev_accept=1\nnet.ipv4.udp_l3mdev_accept=1\n"}],
                          "recommend": [{"match": [{"label": "scd/tenant"}], "priority": 20, "profile": "scd-tenant-vrf"}]}})
    else:
        sys.exit("unknown part " + PART)

if PART == "metallb":
    # FRR-K8s belongs to the network operator once additionalRoutingCapabilities has FRR (routing step): MetalLB must use that instance
    docs.insert(0, {"apiVersion": "metallb.io/v1beta1", "kind": "MetalLB", "metadata": {"name": "metallb", "namespace": "metallb-system"},
                    "spec": {"bgpBackend": "frr-k8s-external", "speakerTolerations": [{"key": "scd/tenant", "operator": "Exists", "effect": "NoSchedule"}]}})
print("\n---\n".join(json.dumps(d) for d in docs))
