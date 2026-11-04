# lib.sh: shared helpers for the sonic-clos-dc scripts (source it). three OpenShift clusters prod, dev, gpu.
# no password in any script. Appliance and service credentials live in root-only env files under /root/scd-secrets (mode 600), read
# here into the environment of the calling script and handed to tools by environment or stdin, never on a command line, never printed.
LAB=sonic-clos-dc; TOPO=$LAB.clab.yml; C=clab-$LAB
SECRETS=${SCD_SECRETS:-/root/scd-secrets}
# appliances.env: SONIC_USER SONIC_PW (Dell SONiC switches), PA_USER PA_PW (fw-pa), ONTAP_USER ONTAP_PW (dc-ontap cluster admin),
#                 ONTAP_VSADMIN_PW ONTAP_DIAG_PW (was .env), HOST_ADMIN_PW HOST_ROOT_PW (scd/host containers: probes, dns-ntp, LAN clients)
# The BIG-IP pair keeps its own per-unit files (<unit>.env). Create appliances.env once from secrets.env.example (mode 600).
if [ -r "$SECRETS/appliances.env" ]; then set -a; . "$SECRETS/appliances.env"; set +a
else echo "lib.sh: $SECRETS/appliances.env is missing or unreadable (create it from secrets.env.example, mode 600)" >&2; fi
mip() { awk -v n="$1" '$2==n{print $1}' mgmt-hosts.txt; }                       # management address of a node
X() { docker exec $C-$1 sh -c "$2" 2>&1; }                                       # run in a linux node
SSHO="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
# sshpass -e reads SSHPASS from the environment: the password never appears in a process list
SW() { SSHPASS="$SONIC_PW" sshpass -e ssh $SSHO -o ConnectTimeout=10 "${SONIC_USER:-admin}"@"$(mip $1)" "$2" </dev/null; }
KL() { local s=$1; shift; local a=""; for c in "$@"; do a+=" -c \"$c\""; done; SW $s "sonic-cli $a"; }   # KLISH, chained -c (stdin is ignored)
ONTAP() { SSHPASS="$ONTAP_PW" sshpass -e ssh $SSHO -o ConnectTimeout=15 "${ONTAP_USER:-admin}"@"$(mip netapp-01)" \
          "set -rows 0 -confirmations off; $*" 2>&1 | tr -d '\r' | grep -v -E '^$|^Last login|first recorded login|Unsuccessful login'; }
# ONTAP REST: curl reads the basic-auth line from stdin (-K -), never from its arguments
ontap_rest() { local m=$1 p=$2; shift 2
  printf 'user = "%s:%s"\n' "${ONTAP_USER:-admin}" "$ONTAP_PW" | curl -sk -K - -X "$m" "https://$(mip netapp-01)/api$p" "$@"; }
PA=$(awk '$2=="fw-pa"{print $1}' mgmt-hosts.txt 2>/dev/null)   # the PA-VM (fw-pa)
# the PAN-OS API key: the password goes in the POST body from stdin, not in the URL (URLs land in logs)
pakey() { printf '%s' "$PA_PW" | curl -sk --data-urlencode "user=${PA_USER:-admin}" --data-urlencode "password@-" "https://$PA/api/?type=keygen" \
          | sed -n 's|.*<key>\(.*\)</key>.*|\1|p'; }
paop() { curl -sk "https://$PA/api/?type=op&key=$(pakey)" --data-urlencode "cmd=$1"; }
say() { echo "[$(date +%H:%M:%S)] $*"; }
# ---------------------------------------------------------------- three clusters (gen.py CLUSTERS), each run from its own bastion
CLUSTERS="prod dev gpu"
TENANTS="prod dev"
BAST() { echo $C-bastion-$1; }                                                   # bastion-prod / bastion-dev / bastion-gpu
OCL() { local cl=$1; shift; docker exec -i $C-bastion-$cl oc "$@"; }             # oc against cluster <cl> from its bastion
SHL() { docker exec -i $C-bastion-$1 bash -c "$2"; }                             # a shell on cluster <cl>'s bastion (oc, helm, jq there)
# mgmt-hosts.txt node lines carry "<mgmt ip> <container> <cluster> <hostname>" (gen.py): the nodes of a cluster, the container of a node
nodes_of() { awk -v c="$1" 'NF >= 4 && $3==c {print $4}' mgmt-hosts.txt; }      # OpenShift hostnames of cluster <cl>
ctr_of() { awk -v c="$1" -v h="$2" 'NF >= 4 && $3==c && $4==h {print $2}' mgmt-hosts.txt; }   # container (clab node) of <cl> <hostname>
NSSH() { ssh $SSHO -o ConnectTimeout=8 core@"$(mip "$1")" "$2" 2>&1; }           # ssh to an RHCOS node by its container name (key auth)
# resdir <name>: makes a new result directory results/<lab>_<name>_<UTC timestamp> and prints its path
resdir() { local d=results/${LAB}_$1_$(date -u +%Y%m%d_%H%M%S); mkdir -p "$d" && echo "$d"; }
# redact: what goes into a command log never carries a secret: basic-auth pairs, URL credentials, key / token headers and fields,
# password fields, LiteLLM-style keys. Every command-log write goes through it (validate-*.sh want / deny, check-lib.sh ev / R).
redact() { sed -E \
  -e 's#(https?://[^:/@ ]+:)[^@ ]+@#\1<redacted>@#g' \
  -e 's/(-u +"?[^: "]+:)[^ "]+/\1<redacted>/g' \
  -e 's/((authorization|proxy-authorization)"?[:=] *"?(bearer|basic)? *)[^" ,}]+/\1<redacted>/Ig' \
  -e 's/((x-api-key|api-key|apikey|api_key|master[_-]key)"?[:=] *"?)[^" ,}]+/\1<redacted>/Ig' \
  -e 's/((password|passwd|secret|token|_pw|_key)"?[:=] *"?)[^" ,}]+/\1<redacted>/Ig' \
  -e 's/\bsk-[A-Za-z0-9_-]{8,}/sk-<redacted>/g'; }
# each tenant's Harbor holds apps/$SEED_IMG (the image platform.sh also put in the gpu cluster's registry; tenant-apps.sh puts it in the
#   tenant's own), pushed from bastion-<t> (tenant-apps.sh seed), pulled from the LAN by validate-platform.sh
SEED_IMG=mc:RELEASE.2025-08-13T08-35-41Z; SKOPEO=quay.io/skopeo/stable:v1.18.0
# skopeo_at <lab node> <registry host> <hosts file> <CA file> <sh cmd>: skopeo in that node's network namespace, the hosts file as /etc/hosts,
#   the CA in /certs. With HP in the caller's environment (HP=... skopeo_at ...: by name, never on a
#   command line) the cmd finds /tmp/auth.json for admin@<registry host> (--authfile); without it, it is anonymous
skopeo_at() { HR=$2 docker run --rm --network container:$C-$1 -v "$3:/etc/hosts:ro" -v "$4:/certs/ca.crt:ro" \
  -e HP -e HR --entrypoint bash $SKOPEO -c \
  '[ -z "$HP" ] || printf "{\"auths\":{\"%s\":{\"auth\":\"%s\"}}}" "$HR" "$(printf "admin:%s" "$HP" | base64 -w0)" > /tmp/auth.json; '"$5" 2>&1; }
# lan_skopeo <registry host> <sh cmd>: as a user on the LAN: client-lan1's hosts file (*.<t>.dc.lab = the PA-VM > the BIG-IP VIP), the lab CA
lan_skopeo() { skopeo_at client-lan1 "$1" "$(docker inspect -f '{{.HostsPath}}' $C-client-lan1)" $SECRETS/tls/ca.crt "$2"; }
# lan_harbor <sh cmd>: a command on client-lan1 with HP from the caller's environment; curl takes it from stdin: printf 'user = "admin:%s"\n' "$HP" | curl -K - ...
lan_harbor() { docker exec -e HP $C-client-lan1 sh -c "$1" 2>&1; }
