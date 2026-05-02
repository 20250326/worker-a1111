# ---------------------------------------------------------------------------- #
#                         Stage 1: Download the models                         #
# ---------------------------------------------------------------------------- #
# FROM alpine/git:2.43.0 AS download

# NOTE: CivitAI usually requires an API token, so you need to add it in the header
#       of the wget command if you're using a model from CivitAI.
# RUN apk add --no-cache wget && \
#     wget -q -O /model.safetensors "https://civitai.com/api/download/models/177164?type=Model&format=SafeTensor&size=pruned&fp=fp16" && \
#     wget -q -O /codeformer-v0.1.0.pth "https://github.com/sczhou/CodeFormer/releases/download/v0.1.0/codeformer.pth"

# ---------------------------------------------------------------------------- #
#                        Stage 2: Build the final image                        #
# ---------------------------------------------------------------------------- #
FROM python:3.10.14-slim AS build_final_image

ARG A1111_RELEASE=v1.9.3

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_PREFER_BINARY=1 \
    ROOT=/stable-diffusion-webui \
    PYTHONUNBUFFERED=1

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update && \
    apt install -y \
    fonts-dejavu-core rsync git jq moreutils aria2 wget libgoogle-perftools-dev libtcmalloc-minimal4 procps libgl1 libglib2.0-0 && \
    apt-get autoremove -y && rm -rf /var/lib/apt/lists/* && apt-get clean -y

RUN --mount=type=cache,target=/root/.cache/pip \
    git clone https://github.com/AUTOMATIC1111/stable-diffusion-webui.git && \
    cd stable-diffusion-webui && \
    git reset --hard ${A1111_RELEASE} && \
    # mkdir -p /stable-diffusion-webui/models/Codeformer/ && \
    mkdir -p repositories/stable-diffusion-stability-ai && \
    git clone https://github.com/joypaul162/Stability-AI-stablediffusion.git repositories/stable-diffusion-stability-ai && \
    sed -i 's/git_clone(stable_diffusion_repo,/# git_clone(stable_diffusion_repo,/g' modules/launch_utils.py && \
    pip install -U xformers --index-url https://download.pytorch.org/whl/cu121 && \
    pip install -r requirements_versions.txt && \
    pip install git+https://github.com/openai/CLIP.git && \
    pip install open_clip_torch && \
    python -c "from launch import prepare_environment; prepare_environment()" --skip-torch-cuda-test

# COPY --from=download /model.safetensors /model.safetensors
# COPY --from=download /codeformer-v0.1.0.pth /stable-diffusion-webui/models/Codeformer/codeformer-v0.1.0.pth

# install dependencies
COPY requirements.txt .
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --no-cache-dir -r requirements.txt

COPY test_input.json .

ADD src .

RUN chmod +x /start.sh
CMD /start.sh
