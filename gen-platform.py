#!/usr/bin/env python3
"""gen-platform.py <cluster> <part>: the platform manifests for one of the three clusters, printed as
one multi-document stream (JSON documents, valid YAML) that platform.sh / tenant-apps.sh pipe into `oc apply -f -` on the cluster's own bastion.
No templating engine. Secrets are created in the cluster by the calling script, never here.
Every cluster (prod, dev, gpu):
  trident            the cluster's TridentBackendConfigs <cl>-san / <cl>-nas on svm-<cl> (management LIF in-VRF) and their StorageClasses
  registry           the internal registry on <cl>-nas (RWX), the scd-images namespace and its pusher
  lldp               LLDP on every node: DaemonSet scd-system/lldpd names the node <host>.<cl>.dc.lab and each physical port
  monitoring         cluster monitoring on the control-plane nodes (the GPU workers keep their memory for the model shards)
Tenant clusters (prod, dev; compact):
  metallb            MetalLB in the tenant VRF: pool 10.0.1.200-.209, eBGP multihop to the rack leaves' loopbacks
  metallb-l2         the layer-2 fallback: the same pool announced by ARP (L2Advertisement) instead of BGP
  isolation          whoami in namespace whoami (the isolation proof): its tenant, cluster, VRF, a marker file on its own SVM
  s3                 MinIO on <t>-san in namespace platform, buckets harbor + data; S3 API on the LB in the tenant VRF only
  dataset            the sample dataset dataset-<t>.csv as text (uploaded from bastion-<t> by tenant-apps.sh seed)
  ops                Job minio-ops: MinIO user <t>-ops (Secret minio-ops), policy data-rw (bucket data only)
  harbor-scc         the SCC Harbor's chart needs (B4), for namespace platform only
  inference          LiteLLM (> https://model.dc.lab with the tenant's key) + APISIX + Open WebUI in namespace platform
The gpu cluster:
  gpu-models         the models on gpu-nas (namespace llm): LFM2.5 24B (pinned GGUF, sha256) and Qwen2.5-0.5B (from the ai-sim image)
  gpu-netop          the network-operator resources: fake pci-15b3 rule, NicClusterPolicy, generic RDMA device plugin, MacvlanNetworks
  gpu-serve          the model API: Services + routes https://llm.apps.gpu.dc.lab/<model>/ (the pods: llm-serve.sh)
"""
import json, sys

CL, PART = sys.argv[1], sys.argv[2]
if CL not in ("prod", "dev", "gpu"):
    sys.exit("cluster must be prod, dev or gpu")

REG = "image-registry.openshift-image-registry.svc:5000/scd-images"
IMG = {"llm": REG + "/llm:2", "ai-sim": REG + "/ai-sim:1", "minio": REG + "/minio:RELEASE.2025-09-07T16-13-09Z", "mc": REG + "/mc:RELEASE.2025-08-13T08-35-41Z",
       "litellm": "ghcr.io/berriai/litellm@sha256:625981c83410a3ea68eb0697590a57ec1d764d634514d54fa5db0591077ee839",   # 1.104.0
       "apisix": "docker.io/apache/apisix@sha256:48ce16399e68a5f31c8b49d802f1e71ec93aea44d8c8ae311dc170e8564d5c4e",     # 3.9.1-debian
       "webui": "ghcr.io/open-webui/open-webui:v0.11.4", "httpd": "registry.access.redhat.com/ubi9/httpd-24:latest"}
MODEL = {"file": "lfm2.5-24b-q4_k_m.gguf", "sha": "d3334405b96228eb9908cdebb5c6194908f2da64282bda852afc3a3910c64e7d", "size": 14526258464,
         "url": "https://registry.ollama.ai/v2/library/lfm2.5/blobs/sha256:d3334405b96228eb9908cdebb5c6194908f2da64282bda852afc3a3910c64e7d"}
QWEN = {"file": "qwen2.5-0.5b-instruct-q4_k_m.gguf", "alias": "qwen2.5-0.5b"}
RAILS = 8
# per cluster: (Trident management LIF, NFS data LIF) of svm-<cl>, reached in the cluster's own VRF over its storage VLAN
SVM = {"prod": ("10.0.3.250", "10.0.3.253"), "dev": ("10.0.3.250", "10.0.3.253"), "gpu": ("10.0.9.250", "10.0.9.253")}
VRF = {"prod": "Vrf-Prod", "dev": "Vrf-Dev", "gpu": "Vrf-Ocp"}
# MetalLB in the tenant VRF: the rack pair's leaf loopbacks (Loopback 11) and ASN; the nodes speak as 65030 in both tenants
LEAF_PEERS = {"prod": (65003, ["10.0.0.15", "10.0.0.16"]), "dev": (65004, ["10.0.0.17", "10.0.0.18"])}
MLB_ASN = 65030
NS_APPS, NS_PLAT = "whoami", "platform"   # the tenant namespaces (the same names in prod and dev: each cluster is the tenant)
docs = []
add = docs.append


def ns(n, **labels):
    add({"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": n, "labels": labels}})


def pvc(n, namespace, size, sc, mode="ReadWriteOnce"):
    add({"apiVersion": "v1", "kind": "PersistentVolumeClaim", "metadata": {"name": n, "namespace": namespace},
         "spec": {"accessModes": [mode], "resources": {"requests": {"storage": size}}, "storageClassName": sc}})


def svc(n, namespace, sel, port, target=None):
    add({"apiVersion": "v1", "kind": "Service", "metadata": {"name": n, "namespace": namespace},
         "spec": {"selector": sel, "ports": [{"name": "p", "port": port, "targetPort": target or port}]}})


def route(n, namespace, host, service):
    add({"apiVersion": "route.openshift.io/v1", "kind": "Route", "metadata": {"name": n, "namespace": namespace},
         "spec": {"host": host, "to": {"kind": "Service", "name": service}, "port": {"targetPort": "p"},
                  "tls": {"termination": "edge", "insecureEdgeTerminationPolicy": "Redirect"}}})


def deploy(n, namespace, pod, replicas=1, strategy="Recreate"):
    # graceful termination; the pod keeps serving 10 s after it is marked for deletion (the endpoint leaves the Service, MetalLB withdraws
    # the node's /32 when no local endpoint is left), then stops; the grace period covers the sleep and the shutdown
    for c in pod.get("containers", []):
        c.setdefault("lifecycle", {}).setdefault("preStop", {"sleep": {"seconds": 10}})
    pod.setdefault("terminationGracePeriodSeconds", 30)
    add({"apiVersion": "apps/v1", "kind": "Deployment", "metadata": {"name": n, "namespace": namespace},
         "spec": {"replicas": replicas, "strategy": {"type": strategy}, "selector": {"matchLabels": {"app": n}},
                  "template": {"metadata": {"labels": dict({"app": n}, **pod.pop("labels", {}))}, "spec": pod}}})


# each tenant app's fixed address in its tenant VRF (MetalLB pool <t> .200-.209); the BIG-IP pool member of that app
APP_IP = {"whoami": 200, "chat": 201, "inference": 202, "harbor": 203, "minio": 204}


MIN_TOKENS_HOOK = 'from litellm.integrations.custom_logger import CustomLogger\n\nMIN = {"lfm2.5-24b": 1024}   # a reasoning model needs room to think (capped at 512 on the server) and then answer\n\n\nclass MinTokens(CustomLogger):\n    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):\n        floor = MIN.get(str(data.get("model", "")))\n        if floor:\n            for k in ("max_tokens", "max_completion_tokens"):\n                if isinstance(data.get(k), int) and data[k] < floor:\n                    data[k] = floor\n        return data\n\n\nproxy_handler_instance = MinTokens()\n'   # LiteLLM pre-call hook, mounted next to config.yaml


def lb(n, namespace, sel, port, t, app, target=None, more=()):   # a LoadBalancer address; announced by every node of the cluster
    ip = "10.0.1.%d" % APP_IP[app]   # the same address in prod and dev, each in its own VRF   # more: (name, port) pairs beside "p" (MinIO's S3 API)
    add({"apiVersion": "v1", "kind": "Service", "metadata": {"name": n, "namespace": namespace, "annotations": {"metallb.io/loadBalancerIPs": ip}},
         "spec": {"type": "LoadBalancer", "externalTrafficPolicy": "Cluster", "selector": sel,   # no announcement moves when a pod goes
                  "ports": [{"name": "p", "port": port, "targetPort": target or port}] + [{"name": m, "port": q, "targetPort": q} for m, q in more]}})


def DATASET(t):   # the sample dataset seeded into s3://data of tenant t (validate-platform.sh reads it back line for line)
    return "tenant,cluster,vrf,svm,bucket\n%s,%s,%s,svm-%s,data\n" % (t, t, VRF[t], t)


def on_tenant(t, pod):   # the cluster IS the tenant (compact, 3 schedulable control-plane nodes): no pinning, no taint
    return pod


def block_yaml(o, ind=0):
    """block-style YAML for APISIX: its tinyyaml parser does not read JSON-style (flow) YAML"""
    pad, out = "  " * ind, []
    if isinstance(o, dict):
        for k, v in o.items():
            k = json.dumps(k) if ":" in k else k
            if isinstance(v, (dict, list)) and v:
                out += ["%s%s:" % (pad, k), block_yaml(v, ind + 1)]
            else:
                out.append("%s%s: %s" % (pad, k, scalar(v)))
    else:
        for v in o:
            if isinstance(v, dict) and v:
                first, *rest = block_yaml(v, ind + 1).split("\n")
                out += ["%s- %s" % (pad, first.lstrip())] + rest
            else:
                out.append("%s- %s" % (pad, scalar(v)))
    return "\n".join(out)


def scalar(v):
    if v == {}:
        return "{}"
    if isinstance(v, bool):
        return "true" if v else "false"
    return str(v) if isinstance(v, int) else json.dumps(v)


if PART == "trident":   # one Trident per cluster, its own SVM, no topology (every node of the cluster may use it)
    mgmt, nfs = SVM[CL]
    for drv in ("san", "nas"):
        n = "%s-%s" % (CL, drv)
        add({"apiVersion": "trident.netapp.io/v1", "kind": "TridentBackendConfig", "metadata": {"name": n, "namespace": "trident"},
             "spec": dict({"version": 1, "storageDriverName": "ontap-" + drv, "backendName": n, "managementLIF": mgmt, "svm": "svm-" + CL,
                           "useREST": True, "credentials": {"name": "ontap-svm"}, "labels": {"svm": "svm-" + CL},
                           "defaults": {"spaceReserve": "none", "snapshotReserve": "0"}},
                          **({"sanType": "iscsi"} if drv == "san" else {"dataLIF": nfs}))})
        add({"apiVersion": "storage.k8s.io/v1", "kind": "StorageClass",
             "metadata": {"name": n, "annotations": {"storageclass.kubernetes.io/is-default-class": "true" if drv == "san" else "false"}},
             "provisioner": "csi.trident.netapp.io", "allowVolumeExpansion": True, "reclaimPolicy": "Delete", "volumeBindingMode": "Immediate",
             "parameters": dict({"backendType": "ontap-" + drv, "selector": "svm=svm-%s" % CL}, **({"fsType": "ext4"} if drv == "san" else {}))})

elif PART == "registry":
    pvc("image-registry-storage", "openshift-image-registry", "60Gi" if CL == "gpu" else "30Gi", "%s-nas" % CL, "ReadWriteMany")
    ns("scd-images")
    add({"apiVersion": "v1", "kind": "ServiceAccount", "metadata": {"name": "pusher", "namespace": "scd-images"}})
    add({"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "RoleBinding", "metadata": {"name": "pusher-editor", "namespace": "scd-images"},
         "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": "registry-editor"},
         "subjects": [{"kind": "ServiceAccount", "name": "pusher", "namespace": "scd-images"}]})
    add({"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "RoleBinding", "metadata": {"name": "pull-all", "namespace": "scd-images"},
         "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": "system:image-puller"},
         "subjects": [{"apiGroup": "rbac.authorization.k8s.io", "kind": "Group", "name": "system:serviceaccounts"}]})

elif PART.startswith("gpu-") and CL != "gpu":
    sys.exit("%s is a part of the gpu cluster" % PART)

elif PART == "gpu-models":   # the models on svm-gpu (gpu-nas, RWX), fetched once and checked
    ns("llm")
    pvc("models", "llm", "40Gi", "gpu-nas", "ReadWriteMany")
    add({"apiVersion": "batch/v1", "kind": "Job", "metadata": {"name": "publish-models", "namespace": "llm"},
         "spec": {"backoffLimit": 2, "template": {"spec": {"restartPolicy": "Never", "nodeSelector": {"scd/gpu": "true"},
              "initContainers": [{"name": "qwen", "image": IMG["ai-sim"], "command": ["sh", "-c",
                  "[ -s /out/%s ] || cp /models/model.gguf /out/%s; ls -la /out/%s" % ((QWEN["file"],) * 3)],   # the image keeps it in /models
                  "volumeMounts": [{"name": "models", "mountPath": "/out"}]}],
              "containers": [{"name": "lfm", "image": IMG["llm"], "command": ["sh", "-c",
                  "cd /models && { [ -f %s ] && echo '%s  %s' | sha256sum -c - >/dev/null 2>&1; } || "
                  "{ curl -fsSL --retry 5 -o %s.part '%s' && echo '%s  %s.part' | sha256sum -c - && mv %s.part %s; } && ls -la /models"
                  % (MODEL["file"], MODEL["sha"], MODEL["file"], MODEL["file"], MODEL["url"], MODEL["sha"], MODEL["file"], MODEL["file"], MODEL["file"])],
                  "volumeMounts": [{"name": "models", "mountPath": "/models"}]}],
              "volumes": [{"name": "models", "persistentVolumeClaim": {"claimName": "models"}}]}}}})

elif PART == "gpu-netop":   # the network-operator resources; rail r = enp0s(5+r) on a GPU worker
    add({"apiVersion": "nfd.k8s-sigs.io/v1alpha1", "kind": "NodeFeatureRule", "metadata": {"name": "scd-fake-pci-15b3", "namespace": "openshift-nfd"},
         "spec": {"rules": [{"name": "sonic-clos-dc: SoftRoCE rail NICs stand in for Mellanox (pci-15b3)",
                             "labels": {"feature.node.kubernetes.io/pci-15b3.present": "true"},
                             "matchFeatures": [{"feature": "kernel.loadedmodule", "matchExpressions": {"rdma_rxe": {"op": "Exists"}}}]}]}})
    add({"apiVersion": "mellanox.com/v1alpha1", "kind": "NicClusterPolicy", "metadata": {"name": "nic-cluster-policy"},
         "spec": {"nodeAffinity": {"requiredDuringSchedulingIgnoredDuringExecution": {"nodeSelectorTerms": [{"matchExpressions": [
                      {"key": "scd/gpu", "operator": "In", "values": ["true"]},
                      {"key": "feature.node.kubernetes.io/pci-15b3.present", "operator": "In", "values": ["true"]}]}]}},
                  # no ofedDriver: no Mellanox hardware; SoftRoCE comes from the in-box rdma_rxe (MachineConfig 99-worker-scd-rxe). No
                  # rdmaSharedDevicePlugin either: it maps an RDMA device through its PCI function and a SoftRoCE device has none (it
                  # advertised 0); the generic device plugin below advertises rdma/rdma-shared
                  "tolerations": [{"operator": "Exists"}]}})
    # rdma/rdma-shared on the GPU workers (the plugin allows no underscore) = /dev/infiniband (the 8 uverbs devices, one per rail, + rdma_cm; a glob would mount only one), shared by up to 63 pods per node (as rdmaHcaMax).
    # The netns mode is shared, and each rail's rxe device holds the GIDs of the macvlans on its rail NIC: a pod with this resource and a
    # net-rail-<r> attachment does RoCEv2 from its own rail address, as with a ConnectX HCA (the same pod spec runs on real hardware).
    dev = {"name": "rdma-shared", "groups": [{"count": 63, "paths": [{"path": "/dev/infiniband/uverbs%d" % i} for i in range(RAILS)] + [{"path": "/dev/infiniband/rdma_cm"}]}]}
    add({"apiVersion": "v1", "kind": "ServiceAccount", "metadata": {"name": "rdma-device-plugin", "namespace": "scd-system"}})
    add({"apiVersion": "apps/v1", "kind": "DaemonSet", "metadata": {"name": "rdma-device-plugin", "namespace": "scd-system"},
         "spec": {"selector": {"matchLabels": {"app": "rdma-device-plugin"}},
                  "template": {"metadata": {"labels": {"app": "rdma-device-plugin"}},
                               "spec": {"serviceAccountName": "rdma-device-plugin", "priorityClassName": "system-node-critical", "nodeSelector": {"scd/gpu": "true"},
                                        "tolerations": [{"operator": "Exists"}],
                                        "containers": [{"name": "plugin", "image": REG + "/generic-device-plugin:8dc84958",   # ghcr.io/squat/generic-device-plugin@sha256:8dc84958...
                                                        "args": ["--domain", "rdma", "--device", json.dumps(dev)],
                                                        "securityContext": {"privileged": True},
                                                        "resources": {"requests": {"cpu": "10m", "memory": "32Mi"}, "limits": {"memory": "64Mi"}},
                                                        "volumeMounts": [{"name": "plugins", "mountPath": "/var/lib/kubelet/device-plugins"}, {"name": "dev", "mountPath": "/dev"}]}],
                                        "volumes": [{"name": "plugins", "hostPath": {"path": "/var/lib/kubelet/device-plugins"}}, {"name": "dev", "hostPath": {"path": "/dev"}}]}}}})
    # the RDMA pods' SCC: restricted plus IPC_LOCK (pinning the memory the NIC reads and writes), no privileged pods for RDMA
    add({"apiVersion": "security.openshift.io/v1", "kind": "SecurityContextConstraints", "metadata": {"name": "scd-rdma"},
         "allowPrivilegedContainer": False, "allowPrivilegeEscalation": False, "allowedCapabilities": ["IPC_LOCK"], "requiredDropCapabilities": ["KILL", "MKNOD"],
         "runAsUser": {"type": "MustRunAsRange"}, "seLinuxContext": {"type": "MustRunAs"}, "fsGroup": {"type": "MustRunAs"}, "supplementalGroups": {"type": "RunAsAny"},
         "seccompProfiles": ["runtime/default"], "readOnlyRootFilesystem": False,
         "volumes": ["configMap", "csi", "downwardAPI", "emptyDir", "ephemeral", "persistentVolumeClaim", "projected", "secret"],
         "allowHostDirVolumePlugin": False, "allowHostIPC": False, "allowHostNetwork": False, "allowHostPID": False, "allowHostPorts": False,
         "users": [], "groups": [], "priority": 5})
    # SoftRoCE receives RoCEv2 (UDP 4791) only in the host's network namespace (rxe on RHEL 9's 5.14 kernel has no netns support): a pod's
    # macvlan address can set up a QP but never receives the data. RDMA pods in this lab therefore use the host network and the node's own rail
    # address; with a ConnectX HCA the same workload runs on its macvlan (scd-rdma). This SCC adds only the host network.
    add({"apiVersion": "security.openshift.io/v1", "kind": "SecurityContextConstraints", "metadata": {"name": "scd-rdma-hostnet"},
         "allowPrivilegedContainer": False, "allowPrivilegeEscalation": False, "allowedCapabilities": ["IPC_LOCK"], "requiredDropCapabilities": ["KILL", "MKNOD"],
         "runAsUser": {"type": "MustRunAsRange"}, "seLinuxContext": {"type": "MustRunAs"}, "fsGroup": {"type": "MustRunAs"}, "supplementalGroups": {"type": "RunAsAny"},
         "seccompProfiles": ["runtime/default"], "readOnlyRootFilesystem": False,
         "volumes": ["configMap", "csi", "downwardAPI", "emptyDir", "ephemeral", "persistentVolumeClaim", "projected", "secret"],
         "allowHostDirVolumePlugin": False, "allowHostIPC": False, "allowHostNetwork": True, "allowHostPID": False, "allowHostPorts": True,
         "users": [], "groups": [], "priority": 5})
    for r in range(1, RAILS + 1):   # net-rail-<r-1> = rail r; no routes: a pod's rail interface reaches only its own rail (production shape)
        net = "172.16.%d" % r
        add({"apiVersion": "mellanox.com/v1alpha1", "kind": "MacvlanNetwork", "metadata": {"name": "net-rail-%d" % (r - 1)},
             "spec": {"networkNamespace": "default", "master": "enp0s%d" % (5 + r), "mode": "bridge", "mtu": 9000,
                      "ipam": json.dumps({"type": "whereabouts", "range": net + ".0/24", "exclude": [net + ".1/32", net + ".0/26"]})}})

elif PART == "gpu-serve":   # the model API of the gpu cluster, one host, a path per model; the BIG-IP model pool (rd-gpu) reaches it on 10.0.8.7
    ns("llm")
    for m, n in (("lfm2.5-24b", "llm-lfm"), (QWEN["alias"], "llm-qwen")):
        add({"apiVersion": "v1", "kind": "Service", "metadata": {"name": n, "namespace": "llm"},
             "spec": {"selector": {"app": "llm", "model": m}, "ports": [{"name": "p", "port": 8080, "targetPort": 8080}]}})
        add({"apiVersion": "route.openshift.io/v1", "kind": "Route", "metadata": {"name": n, "namespace": "llm",
             "annotations": {"haproxy.router.openshift.io/rewrite-target": "/", "haproxy.router.openshift.io/timeout": "900s", "haproxy.router.openshift.io/balance": "roundrobin", "haproxy.router.openshift.io/disable_cookies": "true"}},
             "spec": {"host": "llm.apps.gpu.dc.lab", "path": "/%s/" % m, "to": {"kind": "Service", "name": n}, "port": {"targetPort": "p"},
                      "tls": {"termination": "edge", "insecureEdgeTerminationPolicy": "Redirect"}}})
    add({"apiVersion": "route.openshift.io/v1", "kind": "Route", "metadata": {"name": "llm-health", "namespace": "llm"},   # the BIG-IP monitor
         "spec": {"host": "llm.apps.gpu.dc.lab", "path": "/health", "to": {"kind": "Service", "name": "llm-lfm"}, "port": {"targetPort": "p"},
                  "tls": {"termination": "edge", "insecureEdgeTerminationPolicy": "Redirect"}}})

elif PART == "lldp":   # RHCOS ships no lldpd and NetworkManager only listens; the switches should name every node and NIC on their ports
    # (the legs of bond0 / bond1, the 8 rail NICs of a GPU worker: every enp*). The node name is the pod's (host network), the port id its ifname.
    # the system name is the node's FQDN <host>.<cluster>.dc.lab (an A record); the description its role and owner; each port its link
    owner = {"prod": "tenant prod only", "dev": "tenant dev only", "gpu": "GPU platform shared by tenants prod and dev"}[CL]
    run = r"""case "$NODE" in
  master*) R="control plane of OpenShift cluster $CL ($OWNER)";; gpu-worker*) R="GPU worker of OpenShift cluster $CL (8 GPUs, 8 rails; $OWNER)";;
  *-cp*) R="control plane + workloads of compact OpenShift cluster $CL ($OWNER)";; *) R="node of OpenShift cluster $CL";; esac
lldpd -d -I "enp*" & sleep 4
lldpcli configure system hostname "$NODE.$CL.dc.lab"; lldpcli configure lldp portidsubtype ifname
lldpcli configure system description "RHCOS $NODE: $R"
for d in /sys/class/net/enp*; do i=${d##*/}; m=$(basename "$(readlink $d/master 2>/dev/null)" 2>/dev/null)
  case "$m" in bond0) t="bond0 data ($VRF)";; bond1) t="bond1 storage (svm-$CL)";;
    *) n=${i#enp0s}; t="rail $((n - 5)) (RoCE)";; esac
  lldpcli configure ports $i lldp portdescription "$t"; done
wait"""
    add({"apiVersion": "v1", "kind": "ServiceAccount", "metadata": {"name": "lldpd", "namespace": "scd-system"}})
    add({"apiVersion": "apps/v1", "kind": "DaemonSet", "metadata": {"name": "lldpd", "namespace": "scd-system"},
         "spec": {"selector": {"matchLabels": {"app": "lldpd"}}, "updateStrategy": {"type": "RollingUpdate", "rollingUpdate": {"maxUnavailable": 3}},
                  "template": {"metadata": {"labels": {"app": "lldpd"}},
                               "spec": {"serviceAccountName": "lldpd", "hostNetwork": True, "priorityClassName": "system-node-critical",
                                        "tolerations": [{"operator": "Exists"}],
                                        "containers": [{"name": "lldpd", "image": REG + "/lldpd:1", "command": ["sh", "-c", run],
                                                        "env": [{"name": "NODE", "valueFrom": {"fieldRef": {"fieldPath": "spec.nodeName"}}},
                                                                {"name": "CL", "value": CL}, {"name": "VRF", "value": VRF[CL]}, {"name": "OWNER", "value": owner}],
                                                        "securityContext": {"privileged": True},
                                                        "resources": {"requests": {"cpu": "5m", "memory": "16Mi"}, "limits": {"memory": "64Mi"}}}]}}}})
elif PART == "monitoring":   # Prometheus, Alertmanager and the other monitoring pods on the control-plane nodes
    sel = {"nodeSelector": {"node-role.kubernetes.io/master": ""},
           "tolerations": [{"key": "node-role.kubernetes.io/master", "operator": "Exists", "effect": "NoSchedule"}]}
    comps = ("prometheusOperator", "prometheusK8s", "alertmanagerMain", "kubeStateMetrics", "monitoringPlugin", "openshiftStateMetrics",
             "telemeterClient", "thanosQuerier", "metricsServer")
    add({"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "cluster-monitoring-config", "namespace": "openshift-monitoring"},
         "data": {"config.yaml": json.dumps({c: sel for c in comps})}})

elif PART in ("metallb", "metallb-l2"):   # the tenant's LoadBalancer addresses, announced inside its VRF
    if CL not in LEAF_PEERS:
        sys.exit("metallb is a part of the tenant clusters")
    asn, peers = LEAF_PEERS[CL]
    add({"apiVersion": "metallb.io/v1beta1", "kind": "MetalLB", "metadata": {"name": "metallb", "namespace": "metallb-system"}, "spec": {}})
    add({"apiVersion": "metallb.io/v1beta1", "kind": "IPAddressPool", "metadata": {"name": "apps", "namespace": "metallb-system"},
         "spec": {"addresses": ["10.0.1.200-10.0.1.209"], "autoAssign": False}})   # every app names its address (APP_IP)
    if PART == "metallb":
        for i, p in enumerate(peers):   # leaf a / leaf b of the rack pair: eBGP multihop from the node to the leaf's /32 in the tenant VRF
            add({"apiVersion": "metallb.io/v1beta2", "kind": "BGPPeer", "metadata": {"name": "leaf-%s" % "ab"[i], "namespace": "metallb-system"},
                 "spec": {"myASN": MLB_ASN, "peerASN": asn, "peerAddress": p, "ebgpMultiHop": True, "holdTime": "9s", "keepaliveTime": "3s"}})
        add({"apiVersion": "metallb.io/v1beta1", "kind": "BGPAdvertisement", "metadata": {"name": "apps", "namespace": "metallb-system"},
             "spec": {"ipAddressPools": ["apps"], "aggregationLength": 32}})
    else:   # the fallback: ARP from the node that runs the endpoint; the leaves learn the /32 as an EVPN type-2 route
        add({"apiVersion": "metallb.io/v1beta1", "kind": "L2Advertisement", "metadata": {"name": "apps", "namespace": "metallb-system"},
             "spec": {"ipAddressPools": ["apps"]}})

elif PART in ("isolation", "s3", "dataset", "ops", "harbor-scc", "inference"):   # the tenant platform, in the tenant's own cluster
    if CL not in ("prod", "dev"):
        sys.exit("%s is a part of the tenant clusters" % PART)
    t, what = CL, PART
    APPS, PLAT, DOM = NS_APPS, NS_PLAT, "%s.dc.lab" % t
    if what not in ("dataset", "harbor-scc"):
        ns(APPS if what == "isolation" else PLAT)
    if what == "isolation":   # the same app in both tenants; the page names the tenant, its cluster and VRF, the file proves its SVM
        pvc("marker", APPS, "1Gi", "%s-nas" % t, "ReadWriteMany")
        add({"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "page", "namespace": APPS},
             "data": {"index.html": "tenant %s (cluster %s, %s, apps *.%s)\n" % (t, t, VRF[t], DOM)}})
        deploy("whoami", APPS, on_tenant(t, {"initContainers": [{"name": "marker", "image": IMG["httpd"], "command": ["sh", "-c",
                "echo 'written by %s on svm-%s' > /data/marker.txt" % (t, t)], "volumeMounts": [{"name": "data", "mountPath": "/data"}]}],
                "containers": [{"name": "httpd", "image": IMG["httpd"], "ports": [{"containerPort": 8080}],
                                "volumeMounts": [{"name": "page", "mountPath": "/var/www/html/index.html", "subPath": "index.html"},
                                                 {"name": "data", "mountPath": "/var/www/html/data"}]}],
                "volumes": [{"name": "page", "configMap": {"name": "page"}}, {"name": "data", "persistentVolumeClaim": {"claimName": "marker"}}]}),
               replicas=2, strategy="RollingUpdate")
        svc("whoami", APPS, {"app": "whoami"}, 8080)
        lb("whoami-lb", APPS, {"app": "whoami"}, 8080, t, "whoami")   # the BIG-IP's pool member, an address in the tenant VRF
    elif what == "s3":   # MinIO on the tenant's SAN: Harbor's blob store, the tenant's own object storage
        pvc("minio-data", PLAT, "30Gi", "%s-san" % t)
        deploy("minio", PLAT, on_tenant(t, {"containers": [{"name": "minio", "image": IMG["minio"], "args": ["server", "/data", "--console-address", ":9001"],
                "envFrom": [{"secretRef": {"name": "minio-root"}}], "ports": [{"containerPort": 9000}, {"containerPort": 9001}],
                "readinessProbe": {"httpGet": {"path": "/minio/health/ready", "port": 9000}},
                "resources": {"requests": {"cpu": "250m", "memory": "512Mi"}}, "volumeMounts": [{"name": "data", "mountPath": "/data"}]}],
                "volumes": [{"name": "data", "persistentVolumeClaim": {"claimName": "minio-data"}}]}))
        svc("minio", PLAT, {"app": "minio"}, 9000)
        add({"apiVersion": "v1", "kind": "Service", "metadata": {"name": "minio-console", "namespace": PLAT},
             "spec": {"selector": {"app": "minio"}, "ports": [{"name": "p", "port": 9001, "targetPort": 9001}]}})
        # the console (9001) is what the BIG-IP publishes; the S3 API (9000) only answers inside the tenant VRF, for bastion-<t>
        lb("minio-lb", PLAT, {"app": "minio"}, 9001, t, "minio", more=(("s3", 9000),))
        add({"apiVersion": "batch/v1", "kind": "Job", "metadata": {"name": "minio-buckets", "namespace": PLAT},
             "spec": {"backoffLimit": 20, "template": {"spec": on_tenant(t, {"restartPolicy": "OnFailure", "containers": [{"name": "mc", "image": IMG["mc"],
                  "command": ["sh", "-c", "export HOME=/tmp; mc alias set s3 http://minio:9000 \"$MINIO_ROOT_USER\" \"$MINIO_ROOT_PASSWORD\" >/dev/null && "
                              "mc mb -p s3/harbor s3/data && mc ls s3"],
                  "envFrom": [{"secretRef": {"name": "minio-root"}}]}]})}}})
    elif what == "dataset":   # the sample dataset, as text: tenant-apps.sh seed uploads it from bastion-<t>, validate-platform compares it
        sys.stdout.write(DATASET(t)); sys.exit(0)
    elif what == "ops":   # the MinIO user of bastion-<t> (<t>-ops, Secret minio-ops): read-write on bucket data, nothing else (no harbor, no bucket list)
        pol = {"Version": "2012-10-17", "Statement": [
            {"Effect": "Allow", "Action": ["s3:GetBucketLocation", "s3:ListBucket", "s3:ListBucketMultipartUploads"], "Resource": ["arn:aws:s3:::data"]},
            {"Effect": "Allow", "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"],
             "Resource": ["arn:aws:s3:::data/*"]}]}
        add({"apiVersion": "batch/v1", "kind": "Job", "metadata": {"name": "minio-ops", "namespace": PLAT},
             "spec": {"backoffLimit": 20, "template": {"spec": on_tenant(t, {"restartPolicy": "OnFailure", "containers": [{"name": "mc", "image": IMG["mc"],
                  "command": ["sh", "-c", "export HOME=/tmp; mc alias set s3 http://minio:9000 \"$MINIO_ROOT_USER\" \"$MINIO_ROOT_PASSWORD\" >/dev/null && "
                              "printf '%s' \"$POLICY\" > /tmp/p.json && mc admin policy create s3 data-rw /tmp/p.json >/dev/null && "
                              "mc admin user add s3 \"$OPS_USER\" \"$OPS_PASSWORD\" >/dev/null && "
                              "{ mc admin policy attach s3 data-rw --user \"$OPS_USER\" >/dev/null 2>&1 || true; } && "
                              "mc admin user info s3 \"$OPS_USER\""],   # AccessKey, Status, PolicyName: no secret
                  "env": [{"name": "POLICY", "value": json.dumps(pol)},
                          {"name": "OPS_USER", "valueFrom": {"secretKeyRef": {"name": "minio-ops", "key": "user"}}},
                          {"name": "OPS_PASSWORD", "valueFrom": {"secretKeyRef": {"name": "minio-ops", "key": "password"}}}],
                  "envFrom": [{"secretRef": {"name": "minio-root"}}]}]})}}})
    elif what == "harbor-scc":   # Harbor's chart runs as 10000/10000 with seccomp runtime/default
        add({"apiVersion": "security.openshift.io/v1", "kind": "SecurityContextConstraints", "metadata": {"name": "scd-harbor"},
             "allowPrivilegedContainer": False, "allowPrivilegeEscalation": False, "requiredDropCapabilities": ["MKNOD"],
             "runAsUser": {"type": "RunAsAny"}, "seLinuxContext": {"type": "MustRunAs"}, "fsGroup": {"type": "RunAsAny"},
             "supplementalGroups": {"type": "RunAsAny"}, "seccompProfiles": ["runtime/default"], "readOnlyRootFilesystem": False,
             "volumes": ["configMap", "csi", "downwardAPI", "emptyDir", "ephemeral", "persistentVolumeClaim", "projected", "secret"],
             "allowHostDirVolumePlugin": False, "allowHostIPC": False, "allowHostNetwork": False, "allowHostPID": False, "allowHostPorts": False,
             "users": [], "groups": ["system:serviceaccounts:" + PLAT], "priority": 10})
    elif what == "inference":   # LiteLLM calls the models on the GPU workers through this tenant's BIG-IP model VIP, with its own key
        models = ("lfm2.5-24b", QWEN["alias"])
        cfg = {"model_list": [{"model_name": m, "litellm_params": {"model": "openai/" + m, "api_base": "https://model.dc.lab/%s/v1" % m,
                                                                   "api_key": "os.environ/GPU_MODEL_KEY", "max_tokens": 8192, "timeout": 900}} for m in models],
               "router_settings": {"routing_strategy": "simple-shuffle", "num_retries": 2, "disable_cooldowns": True},   # one deployment per model (the BIG-IP VIP, which health-checks the servers): no cooldown
               "litellm_settings": {"request_timeout": 900, "drop_params": True, "ssl_verify": "/ca/ca.crt",
                                    "callbacks": "min_tokens.proxy_handler_instance"},   # the reasoning model's token floor
               "general_settings": {"master_key": "os.environ/LITELLM_MASTER_KEY"}}
        add({"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "litellm", "namespace": PLAT}, "data": {"config.yaml": json.dumps(cfg, indent=1), "min_tokens.py": MIN_TOKENS_HOOK}})
        deploy("litellm", PLAT, on_tenant(t, {"containers": [{"name": "litellm", "image": IMG["litellm"], "args": ["--config", "/cfg/config.yaml", "--port", "4000"],
                "env": [{"name": "LITELLM_MASTER_KEY", "valueFrom": {"secretKeyRef": {"name": "litellm", "key": "master-key"}}},
                        {"name": "GPU_MODEL_KEY", "valueFrom": {"secretKeyRef": {"name": "gpu-model-key", "key": "key"}}},
                        {"name": "SSL_CERT_FILE", "value": "/ca/ca.crt"},
                        # the model cost map bundled in the image: no fetch from GitHub at start (it failed: only the lab CA is trusted here)
                        {"name": "LITELLM_LOCAL_MODEL_COST_MAP", "value": "True"}],
                "ports": [{"containerPort": 4000}], "readinessProbe": {"httpGet": {"path": "/health/liveliness", "port": 4000}},
                "volumeMounts": [{"name": "cfg", "mountPath": "/cfg"}, {"name": "ca", "mountPath": "/ca"}]}],
                "volumes": [{"name": "cfg", "configMap": {"name": "litellm"}}, {"name": "ca", "configMap": {"name": "lab-ca"}}]}),
               replicas=2, strategy="RollingUpdate")
        svc("litellm", PLAT, {"app": "litellm"}, 4000)
        apisix_cfg = {"routes": [{"id": i, "uri": "/models/%s/proxy/*" % m, "upstream": {"type": "roundrobin", "nodes": {"litellm:4000": 1}},
                                  "plugins": {"key-auth": {}, "proxy-rewrite": {"regex_uri": ["^/models/%s/proxy/(.*)" % m, "/$1"],
                                                                               "headers": {"set": {"Authorization": "Bearer ${{LITELLM_MASTER_KEY}}"}}}}}
                                 for i, m in (("lfm", models[0]), ("qwen", models[1]))]
                                + [{"id": "healthz", "uri": "/healthz", "plugins": {"mocking": {"response_status": 200, "response_example": "ok"}}}],
                      "consumers": [{"username": "users", "plugins": {"key-auth": {"key": "${{APISIX_USER_KEY}}"}}}]}
        add({"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "apisix", "namespace": PLAT},
             "data": {"config.yaml": block_yaml({"deployment": {"role": "data_plane", "role_data_plane": {"config_provider": "yaml"}},
                                                 "apisix": {"node_listen": 9080, "enable_admin": False}}) + "\n",
                      "apisix.yaml": block_yaml(apisix_cfg) + "\n#END\n"}})
        deploy("apisix", PLAT, on_tenant(t, {"serviceAccountName": "anyuid", "containers": [{"name": "apisix", "image": IMG["apisix"], "ports": [{"containerPort": 9080}],
                "readinessProbe": {"httpGet": {"path": "/healthz", "port": 9080}, "initialDelaySeconds": 2, "periodSeconds": 2, "failureThreshold": 2},   # Ready = routes loaded
                "env": [{"name": "LITELLM_MASTER_KEY", "valueFrom": {"secretKeyRef": {"name": "litellm", "key": "master-key"}}},
                        {"name": "APISIX_USER_KEY", "valueFrom": {"secretKeyRef": {"name": "inference-api-key", "key": "key"}}}],
                "volumeMounts": [{"name": "cfg", "mountPath": "/usr/local/apisix/conf/config.yaml", "subPath": "config.yaml"},
                                 {"name": "cfg", "mountPath": "/usr/local/apisix/conf/apisix.yaml", "subPath": "apisix.yaml"}]}],
                "volumes": [{"name": "cfg", "configMap": {"name": "apisix"}}]}), replicas=2, strategy="RollingUpdate")
        svc("apisix", PLAT, {"app": "apisix"}, 80, 9080)
        lb("inference-lb", PLAT, {"app": "apisix"}, 80, t, "inference", 9080)
        pvc("webui-data", PLAT, "5Gi", "%s-san" % t)
        deploy("open-webui", PLAT, on_tenant(t, {"serviceAccountName": "anyuid", "containers": [{"name": "webui", "image": IMG["webui"], "ports": [{"containerPort": 8080}],
                "env": [{"name": "OPENAI_API_BASE_URL", "value": "http://litellm:4000/v1"}, {"name": "ENABLE_OLLAMA_API", "value": "false"},
                        {"name": "OPENAI_API_KEY", "valueFrom": {"secretKeyRef": {"name": "litellm", "key": "master-key"}}},
                        {"name": "WEBUI_URL", "value": "https://chat." + DOM}],
                "readinessProbe": {"httpGet": {"path": "/health", "port": 8080}, "periodSeconds": 15},
                "volumeMounts": [{"name": "data", "mountPath": "/app/backend/data"}]}],
                "volumes": [{"name": "data", "persistentVolumeClaim": {"claimName": "webui-data"}}]}))
        svc("open-webui", PLAT, {"app": "open-webui"}, 8080)
        lb("chat-lb", PLAT, {"app": "open-webui"}, 8080, t, "chat")

else:
    sys.exit("unknown part " + PART)

print("\n---\n".join(json.dumps(d) for d in docs))
