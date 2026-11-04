# lib.sh: shared helpers for the sonic-clos-dc scripts (source it). Device credentials are placeholders (CHANGE_ME_<VARIABLE>): set your own.
LAB=sonic-clos-dc; TOPO=$LAB.clab.yml; C=clab-$LAB
mip() { awk -v n="$1" '$2==n{print $1}' mgmt-hosts.txt; }                       # management address of a node
X() { docker exec $C-$1 sh -c "$2" 2>&1; }                                       # run in a linux node
SW() { sshpass -p admin ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 admin@"$(mip $1)" "$2" </dev/null; }
KL() { local s=$1; shift; local a=""; for c in "$@"; do a+=" -c \"$c\""; done; SW $s "sonic-cli $a"; }   # KLISH, chained -c (stdin is ignored)
ONTAP() { sshpass -p CHANGE_ME_ONTAP_PW ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=15 admin@"$(mip netapp-01)" \
          "set -rows 0 -confirmations off; $*" 2>&1 | tr -d '\r' | grep -v -E '^$|^Last login|first recorded login|Unsuccessful login'; }
PA=$(awk '$2=="fw-pa"{print $1}' mgmt-hosts.txt 2>/dev/null)   # the PA-VM (fw-pa)
pakey() { curl -sk "https://$PA/api/?type=keygen&user=admin&password=CHANGE_ME_PA_PW" | sed -n 's:.*<key>\(.*\)</key>.*:\1:p'; }
paop() { curl -sk "https://$PA/api/?type=op&key=$(pakey)" --data-urlencode "cmd=$1"; }
say() { echo "[$(date +%H:%M:%S)] $*"; }
# resdir <name>: makes a new result directory results/<lab>_<name>_<UTC timestamp> and prints its path
resdir() { local d=results/${LAB}_$1_$(date -u +%Y%m%d_%H%M%S); mkdir -p "$d" && echo "$d"; }
# redact: what goes into a command log never carries a secret: basic-auth passwords, API key headers, bearer tokens, password fields
redact() { sed -E "s/(-u [A-Za-z0-9_.-]+:)[^ \"']+/\1<redacted>/g; s/((apikey|x-api-key|authorization): *(Bearer )?)[A-Za-z0-9._~+\/=-]{12,}/\1<redacted>/Ig; s/(\"?password\"? *[=:] *\"?)[^ ,\"']+/\1<redacted>/Ig"; }
# each tenant's Harbor holds apps/$SEED_IMG (the image platform.sh also put in the internal registry), pushed from bastion-<t>
#   (tenant-apps.sh seed), pulled from the LAN by validate-platform.sh
SEED_IMG=mc:RELEASE.2025-08-13T08-35-41Z; SKOPEO=quay.io/skopeo/stable:v1.18.0
# skopeo_at <lab node> <registry host> <hosts file> <CA file> <sh cmd>: skopeo in that node's network namespace, the hosts file as /etc/hosts,
#   the CA in /certs. With HP in the caller's environment (HP=... skopeo_at ...: by name, never on a
#   command line) the cmd finds /tmp/auth.json for admin@<registry host> (--authfile); without it, it is anonymous
skopeo_at() { HR=$2 docker run --rm --network container:$C-$1 -v "$3:/etc/hosts:ro" -v "$4:/certs/ca.crt:ro" \
  -e HP -e HR --entrypoint bash $SKOPEO -c \
  '[ -z "$HP" ] || printf "{\"auths\":{\"%s\":{\"auth\":\"%s\"}}}" "$HR" "$(printf "admin:%s" "$HP" | base64 -w0)" > /tmp/auth.json; '"$5" 2>&1; }
# lan_skopeo <registry host> <sh cmd>: as a user on the LAN: client-lan1's hosts file (*.<t>.dc.lab = the PA-VM > the BIG-IP VIP), the lab CA
lan_skopeo() { skopeo_at client-lan1 "$1" "$(docker inspect -f '{{.HostsPath}}' $C-client-lan1)" /root/scd-secrets/tls/ca.crt "$2"; }
# lan_harbor <sh cmd>: a command on client-lan1 with HP from the caller's environment; curl takes it from stdin: printf 'user = "admin:%s"\n' "$HP" | curl -K - ...
lan_harbor() { docker exec -e HP $C-client-lan1 sh -c "$1" 2>&1; }
