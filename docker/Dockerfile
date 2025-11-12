FROM nvidia/cuda:12.8.1-cudnn-runtime-ubuntu22.04

# Install git, pip3, and uv
RUN apt-get update && apt-get install -y git python3-pip && pip3 install uv

WORKDIR /app
RUN git clone https://github.com/jwohlwend/boltz.git /app/boltz

WORKDIR /app/boltz
RUN uv pip install --system -e .[cuda]

ENTRYPOINT ["boltz"]