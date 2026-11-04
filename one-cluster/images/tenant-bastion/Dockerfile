# scd tenant bastion v1 (the one-cluster design): bastion-prod / bastion-dev, the only place a tenant's operators load images into its
# Harbor and objects into its MinIO.
#   base   scd/host:1 (Alpine 3.22 with the lab's network tools: ../images/host)
#   added  skopeo + openssh-client from Alpine's archive (inside this image build only), mc copied from the lab's c2/mc image (the release
#          MinIO's Jobs run)
# Built on the lab host by tenant-bastion.sh:  docker build --network host -t scd/tenant-bastion:1 images/tenant-bastion
FROM c2/mc:RELEASE.2025-08-13T08-35-41Z AS mc
FROM scd/host:1
RUN apk add --no-cache skopeo openssh-client
COPY --from=mc /usr/bin/mc /usr/local/bin/mc
COPY tenant-bastion-init.sh /usr/local/bin/tenant-bastion-init.sh
RUN chmod +x /usr/local/bin/tenant-bastion-init.sh
ENTRYPOINT ["/usr/local/bin/tenant-bastion-init.sh"]
