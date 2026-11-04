# SONiC for the AI Data Center: the labs

The companion lab repository for the book *SONiC for the AI Data Center: A Network Engineer's Guide to
Multi-Tenant Front-End and GPU Backend Fabrics*. It holds what builds the book's data center: the generator,
the topology, every switch configuration, the image builds, the Kubernetes manifests and the scripts that
deploy, operate and validate it. The topology, the switch and firewall configurations and the scripts' parameters
are generated from `gen.py`.

The data center comes in two designs, and this repository holds both:

| Directory | Design |
|---|---|
| [one-cluster/](one-cluster/) | One OpenShift cluster for two tenants (soft tenancy) |
| top level | A cluster per tenant and a shared GPU cluster (hard tenancy) |

## What's here

| Path | What it is |
|---|---|
| `gen.py` | The generator: addresses, VLANs, VNIs, ASNs, ports, the containerlab topology and every switch configuration |
| `gen-platform.py` | The OpenShift objects of the platform and the tenants (`gen-tenantnet.py` in one-cluster/) |
| `sonic-clos-dc.clab.yml`, `nodes.json`, `mgmt-hosts.txt` | The topology and the node definitions that `gen.py` writes |
| `configs/` | The Dell Enterprise SONiC configuration of every switch, as `gen.py` writes it |
| `bootstrap/` | The PA-VM bootstrap configuration |
| `images/` | Dockerfiles and init scripts of the lab's own images (bastions, hosts, RHCOS node wrapper, LLDP, RDMA tools, AI simulator) |
| `shared/`, `manifests*/` | Host start-up scripts, DNS zone, and the manifests applied to the clusters |
| `up.sh`, `down.sh`, `sonic-apply.sh`, `rail-roce.sh`, `pa-load.sh`, `f5.sh`, `ontap-setup.sh` | Deploy the fabric, the rails, the firewall, the load balancer and the storage array |
| `make-iso.sh`, `ocp-install.sh`, `platform.sh`, `tenant-apps.sh`, `tenant-bastion.sh`, `llm-serve.sh`, `ai-train.sh` | Install the clusters, the platform, each tenant's applications, model serving and training |
| `validate-fabric.sh`, `validate-rails.sh`, `validate-storage.sh`, `validate-ocp.sh`, `validate-platform.sh`, `validate-isolation.sh`, `validate-f5.sh`, `drills.sh`, `validate-all.sh` | The checks and the failure drills; `validate-all.sh` runs them all (see Validating) |
| `rdma-probe.sh`, `chat-e2e.sh` | Probes: RDMA between two pods over a rail, a chat completion through each tenant's inference API |
| `node-recreate.sh`, `relink.sh`, `node-roll.sh`, `leaves-resize.sh`, `rmac-refresh.sh`, `hosts-refresh.sh`, `prune-installers.sh` | Day-2 operations |
| `migrate-fabric.sh`, `migrate-verify.sh`, `ontap-migrate.sh`, `f5.sh migrate` | The migration of a running one-cluster lab to the three-cluster design |

## Requirements

- A Linux host with KVM, Docker and containerlab (0.82.0 or later). The guests' configured memory adds up
  to about 392 GiB in the one-cluster design and 416 GiB in the hard-tenancy design; a guest uses only the
  memory it touches. Keep at least 200 GB free where the node disks live.
- vrnetlab images, built from your own licensed copies:
  `vrnetlab/dell_sonic:4.6.0` (Dell Enterprise SONiC), `vrnetlab/paloalto_pa-vm:12.1.2`,
  `vrnetlab/f5_bigip-ve:17.5.1.11-0.0.12` (with one BIG-IP VE registration key per unit),
  `vrnetlab/netapp_ontap:9.17.1` (the ONTAP simulator and its licences).
- An OpenShift 4.22.12 pull secret from Red Hat, and an SSH public key for the nodes.
- The lab's own images: see Images below.

## Images

| Image | Source |
|---|---|
| `vrnetlab/dell_sonic:4.6.0`, `vrnetlab/paloalto_pa-vm:12.1.2`, `vrnetlab/f5_bigip-ve:17.5.1.11-0.0.12`, `vrnetlab/netapp_ontap:9.17.1` | Built with vrnetlab from your own licensed images |
| `scd/rhcos-node:1`, `scd/host:1` | Built by `up.sh` from `images/rhcos-node` and `images/host` |
| `scd/bastion:1` | Built from `images/bastion` (Ubuntu 24.04 with `oc` and `kubectl` 4.22.12, `helm` 3.21.4, `jq`, `dig`, `ethtool` and sshd) |
| `scd/tenant-bastion:2` | Built by `tenant-bastion.sh` from `images/tenant-bastion` (on `scd/bastion:1` and `c2/mc`) |
| `c2/ai-sim:1`, `c2/lldpd:1`, `c2/rdma-tools:1` | Built from `images/ai-sim` (after `images/fetch-dl.sh`), `images/lldpd` and `images/rdma-tools` |
| `c2/minio:RELEASE.2025-09-07T16-13-09Z`, `c2/mc:RELEASE.2025-08-13T08-35-41Z` | The MinIO server and client releases of those names, pulled and tagged `c2/...` |
| `c2/generic-device-plugin:8dc84958` | `ghcr.io/squat/generic-device-plugin` at the digest beginning 8dc84958, pulled and tagged |
| `c2/llm:2` | Built from `images/llm` (llama.cpp release b11382) after `images/fetch-dl.sh`, which also fetches the model for `c2/ai-sim:1`; both downloads are pinned by SHA-256 |

`platform.sh` copies the `c2/*` images into each cluster's internal registry.

## Secrets

No password, key or token is stored in this repository. The scripts read them from root-only files that
you create once (see `secrets.env.example` for the variables):

- `/root/scd-secrets/appliances.env`: switch, PA-VM, ONTAP and host credentials
- `/root/scd-secrets/netapp.env` and `/root/scd-secrets/host.env`: the ONTAP launcher's and the hosts' accounts
- `/root/scd-secrets/f5-regkeys.txt`: one BIG-IP registration key per line; `./f5.sh secrets` writes each unit's env file from it
- `/root/scd-secrets/ontap-licenses.txt`: the ONTAP simulator's licence codes, one per line, read by `ontap-setup.sh` (both designs)
- `/root/pull-secret.json` and `~/.ssh/id_ed25519.pub`: read by `gen.py` for the agent-based installs

The one-cluster scripts predate the secrets files and carry a placeholder (`CHANGE_ME_<VARIABLE>`) where
the lab used a literal; replace it with your own value before you run them. They read the ONTAP vsadmin password
(`ONTAP_VSADMIN_PW`) from `one-cluster/.env`, which you create (mode 600).

## Building the labs

The scripts expect the repository at `/root/sonic-clos-dc` and run as root. The VM disks go under `$VMHOME` (default `/opt/unetlab`).

1. **One cluster** (`one-cluster/`), in this order, each part followed by its check:
   `./up.sh --check`, then `./up.sh` (fabric, rails, firewall, load balancer; `validate-fabric.sh`),
   `./ontap-grow.sh` and `./ontap-setup.sh` (`validate-storage.sh`), `./make-iso.sh` and `./ocp-install.sh`
   (`validate-ocp.sh`), `./tenant-net.sh` and `./platform.sh` (`validate-platform.sh`),
   `./tenant-apps.sh prod` and `./tenant-apps.sh dev`, `./f5.sh base ha tls apps model waf`
   (`validate-f5.sh`, `validate-isolation.sh`), then `./validate-all.sh`.
2. **Hard tenancy** (top level): the one-cluster build migrated in place, in this order:
   the fabric per leaf pair (`migrate-fabric.sh`), the storage array (`ontap-migrate.sh`), the nodes re-created
   (`node-recreate.sh`), `./ocp-install.sh prod`, `dev`, then `gpu`, `./platform.sh gpu`,
   `./tenant-apps.sh prod` and `dev`, `./f5.sh p6 model apps waf`, then `./validate-all.sh`.

## Validating

`./validate-all.sh [--no-drills]` runs every check, one at a time, in this order: `validate-fabric.sh all`,
`validate-rails.sh all`, `validate-storage.sh`, `validate-ocp.sh`, `validate-platform.sh` for each cluster
(`gpu`, `prod`, `dev` at the top level; `ocp`, `prod`, `dev` in one-cluster/), `validate-isolation.sh`,
`validate-f5.sh`, then `drills.sh` unless `--no-drills` is given. The drills shut switch ports, move an
ONTAP LIF and fail over the BIG-IP pair under live traffic, and restore each element before the next.

Each check prints one PASS, FAIL or KNOWN line per test and ends with a `RESULT:` line. It writes its own
directory `results/sonic-clos-dc_<check>_<UTC timestamp>/` with `result.txt` (the judged lines) and
`commands.txt` (every command it ran, with secrets redacted); `drills.sh` adds `report.md` and `raw/`.
`validate-all.sh` prints each check's RESULT line, writes `results/summary.txt` (one line per check) and
exits non-zero when any check fails. A KNOWN line records a platform limit of the virtual lab, not a failure.
Every check can also run on its own, for example `./validate-platform.sh prod` or `./drills.sh d1 d8`.

## Tearing down

`./down.sh` revokes both BIG-IP licences first (a key bound to a deleted VM is lost), shuts the OpenShift
nodes down from inside, halts ONTAP cleanly and removes the containers; every disk is kept. `./up.sh`
brings the lab back.

## Conventions

- `gen.py` is the single source: change an address, a port or a memory size there and regenerate; never edit
  a generated configuration by hand.
- Every script is idempotent: a stage that fails can run again.
- Runtime state (node disks, install folders, `clab-*` directories, `results/`) is never committed.
- The outside LAN is 192.168.100.0/24. Use your own addresses in `gen.py` and regenerate (`outside.txt` is written from it).
- If a fresh run of these labs disagrees with an output the book prints, please open an issue.
