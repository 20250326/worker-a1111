#!/usr/bin/env bash

echo "Worker Initiated"

# --- 1. ネットワークボリュームの定義と準備 ---
VOLUME_PATH="/runpod-volume"
MODELS_ROOT="/stable-diffusion-webui/models"

# 永続化したいモデルのパスを定義
SD_MODEL_DEST="$VOLUME_PATH/models/Stable-diffusion/model.safetensors"
CODEFORMER_DIR="$VOLUME_PATH/models/Codeformer"
GFPGAN_DIR="$VOLUME_PATH/models/GFPGAN"
ADETAILER_MODEL_DIR="$VOLUME_PATH/models/adetailer"
VAE_DEST="$VOLUME_PATH/models/VAE/vae-ft-mse-840000-ema-pruned.safetensors"

# curl が入っていなければインストールする
if ! command -v curl &> /dev/null; then
    echo "curl not found. Installing..."
    apt-get update && apt-get install -y curl jq
fi

if [ -d "$VOLUME_PATH" ]; then
    echo "Network Volume found. Synchronizing models..."

    # フォルダの作成
    mkdir -p "$VOLUME_PATH/models/Stable-diffusion"
    mkdir -p "$CODEFORMER_DIR"
    mkdir -p "$GFPGAN_DIR"
    mkdir -p "$ADETAILER_MODEL_DIR"
    mkdir -p "$VOLUME_PATH/models/VAE"

    # --- 2. 存在チェック & ダウンロード（初回のみ） ---
    # メインモデル
    if [ ! -f "$SD_MODEL_DEST" ]; then
        echo "Downloading SD Model to Volume..."
        wget -q -O "$SD_MODEL_DEST" "https://civitai.com/api/download/models/177164?type=Model&format=SafeTensor&size=pruned&fp=fp16"
    fi

    # CodeFormer
    if [ ! -f "$CODEFORMER_DIR/codeformer-v0.1.0.pth" ]; then
        echo "Downloading CodeFormer to Volume..."
        wget -q -O "$CODEFORMER_DIR/codeformer-v0.1.0.pth" "https://github.com/sczhou/CodeFormer/releases/download/v0.1.0/codeformer.pth"
    fi

    # GFPGAN (Face Detection)
    if [ ! -f "$GFPGAN_DIR/detection_Resnet50_Final.pth" ]; then
        echo "Downloading GFPGAN detection model to Volume..."
        wget -q -O "$GFPGAN_DIR/detection_Resnet50_Final.pth" "https://github.com/xinntao/facexlib/releases/download/v0.1.0/detection_Resnet50_Final.pth"
    fi

    # 顔用モデルのダウンロード
    if [ ! -f "$ADETAILER_MODEL_DIR/face_yolov8n.pt" ]; then
        echo "Downloading ADetailer Face model..."
        wget -q -O "$ADETAILER_MODEL_DIR/face_yolov8n.pt" "https://huggingface.co/Bingsu/adetailer/resolve/main/face_yolov8n.pt"
    fi

    # VAE
    if [ ! -f "$VAE_DEST" ]; then
        echo "Downloading VAE to Volume..."
        wget -q -O "$VAE_DEST" "https://huggingface.co/stabilityai/sd-vae-ft-mse-original/resolve/main/vae-ft-mse-840000-ema-pruned.safetensors"
    fi

    # --- ADetailer 拡張機能本体のインストール ---
    EXTENSIONS_ROOT="/stable-diffusion-webui/extensions"
    ADETAILER_EXT_DIR="$EXTENSIONS_ROOT/adetailer"

    if [ ! -d "$ADETAILER_EXT_DIR" ]; then
        echo "Installing ADetailer extension (Git Clone)..."
        git clone https://github.com/Bing-su/adetailer.git "$ADETAILER_EXT_DIR"
        
        # ★ ここが重要！足りないライブラリをインストールする ★
        echo "Installing requirements for ADetailer..."
        pip install rich
    else
        echo "ADetailer extension already exists."
    fi

    # --- 3. シンボリックリンクの構築 ---
    # イメージ側のデフォルトディレクトリを消して、ボリュームへ繋ぐ
    rm -rf "$MODELS_ROOT/Stable-diffusion" && ln -s "$VOLUME_PATH/models/Stable-diffusion" "$MODELS_ROOT/Stable-diffusion"
    rm -rf "$MODELS_ROOT/Codeformer" && ln -s "$CODEFORMER_DIR" "$MODELS_ROOT/Codeformer"
    rm -rf "$MODELS_ROOT/GFPGAN" && ln -s "$GFPGAN_DIR" "$MODELS_ROOT/GFPGAN"
    rm -rf "$MODELS_ROOT/adetailer" && ln -s "$ADETAILER_MODEL_DIR" "$MODELS_ROOT/adetailer"
    rm -rf "$MODELS_ROOT/VAE" && ln -s "$VOLUME_PATH/models/VAE" "$MODELS_ROOT/VAE"

    echo "Model synchronization complete."
else
    echo "Error: Network Volume not found at $VOLUME_PATH."
fi

# --- 4. WebUI 起動 ---
echo "Starting WebUI API"
TCMALLOC="$(ldconfig -p | grep -Po "libtcmalloc.so.\d" | head -n 1)"
export LD_PRELOAD="${TCMALLOC}"
export PYTHONUNBUFFERED=true

# --ckpt はボリューム側の実体を指定
python /stable-diffusion-webui/webui.py \
  --xformers \
  --no-half-vae \
  --skip-python-version-check \
  --skip-torch-cuda-test \
  --skip-install \
  --ckpt "$SD_MODEL_DEST" \
  --opt-sdp-attention \
  --disable-safe-unpickle \
  --port 3000 \
  --api \
  --nowebui \
  --skip-version-check \
  --no-hashing \
  --no-download-sd-model &

# WebUIが起動するまで少し待つ（APIが反応するまでループ）
echo "Waiting for WebUI API to be ready..."
until curl -s http://localhost:3000/sdapi/v1/sd-vae > /dev/null; do
    echo "Waiting for WebUI API..."
    sleep 2
done

# 登録されているVAEの一覧を取得してログに出力
echo "Listing available VAEs:"
curl -s http://localhost:3000/sdapi/v1/sd-vae | jq -r '.[].model_name'

# --- デバッグ用：ADetailerがAPIに認識されているか確認 ---
echo "Checking ADetailer API status..."
# 1. 拡張機能の一覧を取得
SCRIPTS=$(curl -s http://localhost:3000/sdapi/v1/scripts)
if echo "$SCRIPTS" | grep -iq "adetailer"; then
    echo "SUCCESS: ADetailer extension is detected by WebUI."
else
    echo "ERROR: ADetailer extension NOT found in scripts list!"
    echo "Available scripts: $SCRIPTS"
fi

# 2. モデルファイルがWebUIから見える場所にあるか再確認
echo "Physical model check:"
ls -lh /stable-diffusion-webui/models/adetailer/face_yolov8n.pt

echo "Starting RunPod Handler"
python -u /handler.py
