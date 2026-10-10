#!/usr/bin/env bash
# comfysetup.sh - ONE small ComfyUI build: clones the repo, builds a deps-only container image, runs it.
# Not the full ~33 GB kit (parked at ~/dev/caveutils/unused/comfy/): only what is needed to work, the rest you
# add yourself whenever you want (drop files under ./.comfy/models/<subdir>, or use the Manager inside ComfyUI).
#
# In the box:
#   ComfyUI-Manager     ComfyUI's own (--enable-manager, pip package comfyui_manager) - installs nodes/models from the UI
#   export to Python    pydn/ComfyUI-to-Python-Extension in ./.comfy/nodes ("Save as Script" in the UI)
#   models (optional)   `comfysetup.sh models`: a starter set of ~2.4 GB, never more than the 10 GB budget
#
#   comfysetup.sh          build (if needed) + (re)start
#   comfysetup.sh models   download the starter models (asks first, resumes, skips what exists)
#   comfysetup.sh nodes    install/update the export-to-Python node
#   comfysetup.sh info     show detected engine/accel/paths
#   comfysetup.sh logs     follow the container log
#   comfysetup.sh stop     stop the container
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC=${COMFY_SRC:-${TMPDIR:-/tmp}/comfyui-src}     # disposable, re-cloned
DATA_HOME=${COMFY_HOME:-$ROOT/.comfy}              # models/output/user - persistent
IMAGE=${COMFY_IMAGE:-comfyui-minimal}
NAME=${COMFY_NAME:-comfyui}
PORT=${COMFY_PORT:-8188}
COMFY_REPO=${COMFY_REPO:-https://github.com/comfyanonymous/ComfyUI}

# ---- edit me: what comes with it ------------------------------------------------------------------------
NODES=${COMFY_NODES-pydn/ComfyUI-to-Python-Extension}          # GitHub owner/repo, cloned into .comfy/nodes
NODE_PIP=${COMFY_NODE_PIP-black}                                # python packages those nodes need (the export formats with black)
MODEL_BUDGET_MB=${COMFY_MODEL_BUDGET_MB:-10240}                 # `models` refuses a list bigger than this
# starter models: subdir <TAB> file <TAB> url <TAB> size in MiB (a low-VRAM friendly set; bigger ones you add by hand)
MODELS_LIST=${COMFY_MODEL_LIST:-}
models_default() {
	cat <<'EOF'
checkpoints	v1-5-pruned-emaonly-fp16.safetensors	https://huggingface.co/Comfy-Org/stable-diffusion-v1-5-archive/resolve/main/v1-5-pruned-emaonly-fp16.safetensors	2034
vae	vae-ft-mse-840000-ema-pruned.safetensors	https://huggingface.co/stabilityai/sd-vae-ft-mse-original/resolve/main/vae-ft-mse-840000-ema-pruned.safetensors	320
upscale_models	RealESRGAN_x4plus.pth	https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth	64
EOF
}
# ----------------------------------------------------------------------------------------------------------

say() { printf '\033[36m>>\033[0m %s\n' "$*"; }

# --- container engine ------------------------------------------------------
ENGINE=${COMFY_ENGINE:-}
if [ -z "$ENGINE" ]; then
    if   command -v podman >/dev/null 2>&1; then ENGINE=podman
    elif command -v docker >/dev/null 2>&1; then ENGINE=docker
    else echo "comfysetup: need podman or docker on PATH" >&2; exit 1
    fi
fi
pm() { command "$ENGINE" ${COMFY_ENGINE_ARGS:-} "$@"; }

# --- accelerator + VRAM ------------------------------------------------
ACCEL=${COMFY_ACCEL:-}
if [ -z "$ACCEL" ]; then
    if   command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then ACCEL=nvidia
    elif [ -e /dev/kfd ] && [ -e /dev/dri/renderD128 ];                          then ACCEL=rocm
    else ACCEL=cpu
    fi
fi
VRAM=
[ "$ACCEL" = nvidia ] && VRAM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -dc 0-9)

BASE=${COMFY_BASE:-}
TORCH_PIP=${COMFY_TORCH_PIP-__unset__}
if [ -z "$BASE" ]; then
    case $ACCEL in
        rocm) BASE=docker.io/rocm/pytorch:latest ;;
        cpu)  BASE=docker.io/library/python:3.12-slim
              [ "$TORCH_PIP" = __unset__ ] && \
                  TORCH_PIP='torch torchvision --index-url https://download.pytorch.org/whl/cpu' ;;
        *)    # nvidia: torch 2.7.1 is the widest-working pin - Pascal
              # (sm_50-61, e.g. GTX 1050 Ti) through Ada/Hopper. Newer
              # card? COMFY_BASE=<newer image>.
              BASE=docker.io/pytorch/pytorch:2.7.1-cuda12.6-cudnn9-runtime ;;
    esac
fi
[ "$TORCH_PIP" = __unset__ ] && TORCH_PIP=

_common='--use-split-cross-attention --disable-smart-memory --preview-method none'
if   [ -n "${COMFY_FLAGS:-}" ];              then read -ra FLAGS <<< "$COMFY_FLAGS"
elif [ "$ACCEL" = cpu ];                     then read -ra FLAGS <<< "--cpu $_common"
elif [ -z "$VRAM" ] || [ "$VRAM" -lt 6500 ]; then read -ra FLAGS <<< "--lowvram $_common"
elif [ "$VRAM" -lt 12000 ];                  then read -ra FLAGS <<< "$_common"
else                                              read -ra FLAGS <<< "--highvram $_common"
fi

case " ${FLAGS[*]} " in *' --enable-manager '*) ;; *) FLAGS+=(--enable-manager) ;; esac

gpu_flag() {
    case $ACCEL in
        cpu)  : ;;
        rocm) printf -- '--device=/dev/kfd --device=/dev/dri --group-add=video --security-opt=seccomp=unconfined' ;;
        *)    if [ -e /etc/cdi/nvidia.yaml ] || [ -e /var/run/cdi/nvidia.yaml ]; then
                  printf -- '--device=nvidia.com/gpu=all'
              else
                  printf -- '--gpus=all'
              fi ;;
    esac
}

Z=
command -v getenforce >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null)" = Enforcing ] && Z=:z

info() {
    printf 'engine  : %s\n' "$ENGINE"
    printf 'accel   : %s%s\n' "$ACCEL" "${VRAM:+  (${VRAM} MiB VRAM)}"
    printf 'base    : %s\n' "$BASE"
    [ -n "$TORCH_PIP" ] && printf 'torch   : pip install %s\n' "$TORCH_PIP"
    printf 'flags   : %s\n' "${FLAGS[*]}"
    printf 'src     : %s   %s\n' "$SRC" "$([ -d "$SRC/.git" ] && echo '(cloned)' || echo '(will clone)')"
    printf 'data    : %s\n' "$DATA_HOME"
    printf 'plugins : ComfyUI-Manager (built in, --enable-manager)  nodes: %s\n' "${NODES:-none}"
    printf 'address : http://127.0.0.1:%s   image=%s  container=%s%s\n' \
        "$PORT" "$IMAGE" "$NAME" "${Z:+  (selinux :z)}"
}

case "${1:-}" in
    info) info; exit 0 ;;
    logs) exec pm logs -f "$NAME" ;;
    stop) pm stop -t 20 "$NAME" && say "stopped"; exit 0 ;;
    -h|--help|help) sed -n '2,17p' "$0"; exit 0 ;;
esac

# --- nodes: the export-to-Python extension (ComfyUI-Manager itself comes with ComfyUI) ------------------------
install_nodes() {
    mkdir -p "$DATA_HOME/nodes"
    for r in $NODES; do
        d=$DATA_HOME/nodes/${r##*/}
        if [ -d "$d/.git" ]; then
            git -C "$d" pull --ff-only --quiet 2>/dev/null && say "node  ${r##*/} up to date" || say "node  ${r##*/} (not updated - offline or modified)"
        else
            say "node  clone $r"
            git clone --depth 1 --quiet "https://github.com/$r" "$d" || say '  (clone failed - run: comfysetup.sh nodes)'
        fi
    done
}

# --- models: an explicit, size-checked download, never part of the normal start -------------------------------
install_models() {
    list=$(if [ -n "$MODELS_LIST" ]; then cat "$MODELS_LIST"; else models_default; fi)
    total=0; todo=0
    while IFS='	' read -r sub file url mb; do
        [ -n "$file" ] || continue
        total=$((total + mb))
        [ -f "$DATA_HOME/models/$sub/$file" ] || todo=$((todo + mb))
    done <<EOF
$list
EOF
    if [ "$total" -gt "$MODEL_BUDGET_MB" ]; then
        echo "comfysetup: this model list is $total MiB, over the $MODEL_BUDGET_MB MiB budget (COMFY_MODEL_BUDGET_MB) - trim the list" >&2
        exit 1
    fi
    if [ "$todo" -eq 0 ]; then say "all starter models are already in $DATA_HOME/models"; return 0; fi
    printf '%s\n' "$list" | while IFS='	' read -r sub file url mb; do
        [ -n "$file" ] || continue
        [ -f "$DATA_HOME/models/$sub/$file" ] && st="have" || st="get "
        printf '  %s  %-15s %-44s %5d MiB\n' "$st" "$sub" "$file" "$mb"
    done
    printf 'download %d MiB (budget %d MiB)? [y/N] ' "$todo" "$MODEL_BUDGET_MB"
    if [ -z "${COMFY_YES:-}" ]; then read -r a || exit 1; case $a in y|Y|yes|t|T|tak) ;; *) echo cancelled; exit 0 ;; esac; else echo yes; fi
    printf '%s\n' "$list" | while IFS='	' read -r sub file url mb; do
        [ -n "$file" ] || continue
        dst=$DATA_HOME/models/$sub/$file
        [ -f "$dst" ] && continue
        mkdir -p "$DATA_HOME/models/$sub"
        say "download $file"
        curl -fL --retry 3 -C - -o "$dst.part" "$url" && mv "$dst.part" "$dst" || { echo "comfysetup: failed: $file (run again to resume)" >&2; exit 1; }
    done
    say "models are in $DATA_HOME/models"
}

case "${1:-}" in
    models) mkdir -p "$DATA_HOME/models"; install_models; exit 0 ;;
    nodes)  install_nodes; exit 0 ;;
esac

# --- source: clone or fast-forward -----------------------------------
if [ -d "$SRC/.git" ]; then
    say "pull  ComfyUI ($SRC)"
    git -C "$SRC" pull --ff-only --quiet 2>/dev/null || say "  (skipped - offline or dirty)"
else
    say "clone ComfyUI -> $SRC"
    mkdir -p "$(dirname "$SRC")"
    git clone --depth 1 "$COMFY_REPO" "$SRC"
fi

mkdir -p "$DATA_HOME"/{models,output,assets,user,nodes}
install_nodes

# --- build: deps-only image, idempotent (skip unless requirements.txt
# changed since the last build) ------------------------------------------
[ -f "$SRC/manager_requirements.txt" ] || : > "$SRC/manager_requirements.txt"   # older ComfyUI without the built-in manager
reqhash=$({ cat "$SRC/requirements.txt" "$SRC/manager_requirements.txt"; printf %s "$NODE_PIP"; } | sha1sum | cut -c1-12)   # image = ComfyUI + manager + node deps
if ! pm image exists "$IMAGE" || [ "$(cat "$ROOT/.reqhash" 2>/dev/null || true)" != "$reqhash" ]; then
    ctx=$(mktemp -d); trap 'rm -rf "$ctx"' EXIT
    cp "$SRC/requirements.txt" "$ctx/requirements.txt"; cp "$SRC/manager_requirements.txt" "$ctx/manager_requirements.txt"
    printf '%s\n' $NODE_PIP > "$ctx/node_requirements.txt"

    cat > "$ctx/Containerfile" <<CF
ARG BASE=$BASE
FROM \${BASE}
ARG TORCH_PIP=
ENV DEBIAN_FRONTEND=noninteractive PIP_ROOT_USER_ACTION=ignore PIP_NO_CACHE_DIR=1 CC=gcc
RUN ( command -v apt-get >/dev/null && apt-get update && apt-get install -y --no-install-recommends \\
        git ca-certificates libgl1 libglib2.0-0 build-essential && rm -rf /var/lib/apt/lists/* ) \\
 || ( command -v microdnf >/dev/null && microdnf install -y git mesa-libGL glib2 gcc gcc-c++ make ) \\
 || ( command -v dnf >/dev/null && dnf install -y git mesa-libGL glib2 gcc gcc-c++ make ) \\
 || true
RUN [ -z "\$TORCH_PIP" ] || pip install \$TORCH_PIP
COPY requirements.txt manager_requirements.txt node_requirements.txt /src/
RUN pip install -r /src/requirements.txt -r /src/manager_requirements.txt -r /src/node_requirements.txt && rm -rf /src
WORKDIR /opt/ComfyUI
EXPOSE 8188
ENTRYPOINT ["python", "main.py", "--listen", "0.0.0.0", "--port", "8188"]
CF

    say "building $IMAGE  (base $BASE - first pull is a few GB, once)"
    pm build -t "$IMAGE" --build-arg BASE="$BASE" --build-arg TORCH_PIP="$TORCH_PIP" -f "$ctx/Containerfile" "$ctx"
    printf '%s' "$reqhash" > "$ROOT/.reqhash"
    rm -rf "$ctx"; trap - EXIT
else
    say "$IMAGE already built (requirements unchanged) - rm .reqhash to force a rebuild"
fi

# --- run ---------------------------------------------------------------
say "starting $NAME  (accel=$ACCEL  flags=${FLAGS[*]})"
# shellcheck disable=SC2046
pm run -d --replace --name "$NAME" \
    $(gpu_flag) \
    -p "127.0.0.1:$PORT:8188" \
    -v "$SRC:/opt/ComfyUI${Z}" \
    -v "$DATA_HOME/nodes:/opt/ComfyUI/custom_nodes${Z}" \
    -v "$DATA_HOME/models:/opt/ComfyUI/models${Z}" \
    -v "$DATA_HOME/output:/opt/ComfyUI/output${Z}" \
    -v "$DATA_HOME/assets:/opt/ComfyUI/input${Z}" \
    -v "$DATA_HOME/user:/opt/ComfyUI/user${Z}" \
    "$IMAGE" "${FLAGS[@]}" >/dev/null

# first boot does DB migrations + asset/backend detection - measured ~6+ min
# on this hardware (GTX 1050 Ti, 4 core) before it starts answering. 20 min
# ceiling, not 5 - a real cold start, not a hang.
printf 'waiting for ComfyUI (first boot can take several minutes)'
for _ in $(seq 1 600); do
    if curl -sf -o /dev/null "http://127.0.0.1:$PORT/"; then
        url="http://127.0.0.1:$PORT/"
        echo " -> $url"
        command -v flatpak >/dev/null 2>&1 && flatpak run org.mozilla.firefox "$url" >/dev/null 2>&1 &
        exit 0
    fi
    [ "$(pm inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" = true ] \
        || { echo; say "container exited during boot - comfysetup.sh logs"; exit 1; }
    printf .; sleep 2
done
echo; say "still not answering after 20 min - comfysetup.sh logs (it may still be starting; check there before assuming it's stuck)"
