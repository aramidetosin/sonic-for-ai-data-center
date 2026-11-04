# c2/ai-sim:1: the image of the training job (ai-train.sh) and the source of the Qwen model. Built on the lab host and imported into containerd on the
# nodes that run the workloads (never pulled: the lab's uplink is slow and Harbor's proxy cuts large layers).
#   training   PyTorch (CPU build) DistributedDataParallel, gloo backend over a rail interface   -> /opt/ai/train.py
#   inference  llama.cpp llama-server + ggml-rpc-server (one model spread over several nodes) and a small open model (Qwen2.5-0.5B-Instruct, Q4_K_M, Apache-2.0)
#   traffic    iperf3 for the collective-traffic pattern on the other rails
# Build context needs dl/llama.tar.gz (llama.cpp release b11382, ubuntu-x64) and dl/model.gguf (Qwen2.5-0.5B-Instruct Q4_K_M): images/fetch-dl.sh
FROM python:3.12-slim
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends iperf3 iproute2 iputils-ping curl tcpdump libgomp1 libcurl4 procps ca-certificates && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir torch --index-url https://download.pytorch.org/whl/cpu
RUN pip install --no-cache-dir numpy
ADD dl/llama.tar.gz /opt/
RUN ln -s /opt/llama-* /opt/llama
COPY dl/model.gguf /models/model.gguf
COPY train.py /opt/ai/train.py
ENV LD_LIBRARY_PATH=/opt/llama PATH=/opt/llama:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin PYTHONUNBUFFERED=1
CMD ["sleep", "infinity"]
