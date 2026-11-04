# c2/rdma-tools:1: RDMA verbs tools for the pod-level RoCE probe on the rails: rdma-core with the rxe (SoftRoCE) provider, perftest
# (ib_write_bw / ib_send_lat), iproute2. The pods get /dev/infiniband through rdma/rdma_shared and a rail through a MacvlanNetwork.
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends rdma-core ibverbs-providers ibverbs-utils perftest iproute2 iputils-ping && rm -rf /var/lib/apt/lists/*
