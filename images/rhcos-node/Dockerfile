# scd/rhcos-node:1: an OpenShift node: a KVM guest wrapped in a container so containerlab wires it like any other node. The guest is
# installed by the OpenShift agent-based installer ISO (bind-mounted, shared by all nodes); the container also stands in
# for the server's BMC on the OOB link. Built on the lab host: docker build --network host -t scd/rhcos-node:1 images/rhcos-node (the VM wrapper and the hold gate)
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      qemu-system-x86 qemu-utils iproute2 bridge-utils iputils-ping procps ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*
COPY vm-init.sh /usr/local/bin/vm-init.sh
RUN chmod +x /usr/local/bin/vm-init.sh
ENTRYPOINT ["/usr/local/bin/vm-init.sh"]
