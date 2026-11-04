# c2/llm:2: the model servers of llm-serve.sh: llama.cpp release b11382 (llama-server and rpc-server, CPU build) on Python 3.12 slim.
# Build context: dl/llama.tar.gz, fetched by images/fetch-dl.sh. Built on the lab host:
#   ./images/fetch-dl.sh && cp images/ai-sim/dl/llama.tar.gz images/llm/dl/ && docker build --network host -t c2/llm:2 images/llm
FROM python:3.12-slim
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends iproute2 iputils-ping curl libgomp1 libcurl4 procps ca-certificates \
    && rm -rf /var/lib/apt/lists/*
ADD dl/llama.tar.gz /opt/
RUN ln -s /opt/llama-* /opt/llama
ENV LD_LIBRARY_PATH=/opt/llama PATH=/opt/llama:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin PYTHONUNBUFFERED=1
CMD ["sleep", "infinity"]
