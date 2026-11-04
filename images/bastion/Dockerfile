# scd/bastion:1: the bastion of each cluster (bastion-gpu; the tenant bastions build on it): Ubuntu 24.04 with the OpenShift client
# (oc and kubectl 4.22.12), helm, jq and dig, and its own PID 1 (scd-bastion-init.sh: addresses, routes, sshd, the cluster's kubeconfig).
# Built on the lab host: docker build --network host -t scd/bastion:1 images/bastion
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
ARG OC_VERSION=4.22.12
ARG HELM_VERSION=v3.21.4
RUN apt-get update && apt-get install -y --no-install-recommends locales ethtool dnsutils chrony curl ca-certificates openssl iproute2 \
      iputils-ping tcpdump traceroute socat openssh-server sudo bash-completion vim-tiny less procps jq gettext-base net-tools \
    && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL --retry 5 -o /tmp/oc.tgz "https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/${OC_VERSION}/openshift-client-linux.tar.gz" \
    && tar -xzf /tmp/oc.tgz -C /usr/local/bin oc kubectl && rm -f /tmp/oc.tgz \
    && curl -fsSL --retry 5 -o /tmp/helm.tgz "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" \
    && tar -xzf /tmp/helm.tgz -C /usr/local/bin --strip-components=1 linux-amd64/helm && rm -f /tmp/helm.tgz
# the operator account: no password (set one, or use keys); root keeps no password unless host.env sets it (see secrets.env.example)
RUN useradd -m -s /bin/bash admin && usermod -aG sudo admin && mkdir -p /root/.ssh /home/admin/.ssh && chmod 700 /root/.ssh /home/admin/.ssh \
    && chown admin:admin /home/admin/.ssh
COPY scd-bastion-init.sh /usr/local/bin/scd-bastion-init.sh
RUN chmod +x /usr/local/bin/scd-bastion-init.sh
ENTRYPOINT ["/usr/local/bin/scd-bastion-init.sh"]
