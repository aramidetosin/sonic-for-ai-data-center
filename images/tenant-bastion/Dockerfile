# scd tenant bastion v2: bastion-prod / bastion-dev install and operate their own cluster AND are the only place a
# tenant's operators load images into its Harbor and objects into its MinIO.
#   base   scd/bastion:1 (Ubuntu 24.04 with oc 4.22.12, kubectl, helm, jq, dig: images/bastion); openshift-install is bind-mounted
#          (static binary, /root/ocp-bin) and the cluster's agent directory is bind-mounted at /w/agent (gen.py topology)
#   added  skopeo + openssh-server from Ubuntu's archive (inside this image build only: nothing is installed on the lab host's host), mc copied from
#          the lab's c2/mc image (the release MinIO's Jobs run)
# Built on the lab host by tenant-bastion.sh:  docker build --network host -t scd/tenant-bastion:2 images/tenant-bastion
FROM c2/mc:RELEASE.2025-08-13T08-35-41Z AS mc
FROM scd/bastion:1
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends skopeo openssh-server \
 && rm -rf /var/lib/apt/lists/*
COPY --from=mc /usr/bin/mc /usr/local/bin/mc
COPY tenant-bastion-init.sh /usr/local/bin/tenant-bastion-init.sh
RUN chmod +x /usr/local/bin/tenant-bastion-init.sh
ENTRYPOINT ["/usr/local/bin/tenant-bastion-init.sh"]
