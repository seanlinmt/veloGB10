#!/usr/bin/env bash
# launch_qwen38_flash_next.sh
# Launcher for Qwen3.8-Flash-Next EXL3 on veloGB10.
# Supports jeffpeng3/Qwen3.8-Flash-Next-exl3-3.05bpw-heretic (uncensored) and doth4580/Qwen3.8-Flash-Next-EXL3-3.05bpw.
# Topologies: TP=1 (single machine), TP=2 (2x DGX Spark: ai + ai2), and TP=4.
# Reference: QWEN_38_FLASH_NEXT_SETUP.md
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/gb10_inference" ] && [ -d "$SCRIPT_DIR/src/ptx" ]; then
  REPO_ROOT="$SCRIPT_DIR"
elif [ -f "$SCRIPT_DIR/../gb10_inference" ] && [ -d "$SCRIPT_DIR/../src/ptx" ]; then
  REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
else
  REPO_ROOT="$SCRIPT_DIR"
fi

cd "$REPO_ROOT"

BIN=""
if [ -x "./gb10_inference" ]; then
  BIN="./gb10_inference"
elif [ -x "./target/release/gb10_inference" ]; then
  BIN="./target/release/gb10_inference"
else
  echo "ERROR: gb10_inference binary not found in $REPO_ROOT or target/release/" >&2
  exit 1
fi

if [ ! -d "./src/ptx" ]; then
  echo "ERROR: ./src/ptx/ directory missing in $REPO_ROOT. The binary loads PTX relative to CWD." >&2
  exit 1
fi

# Default parameters
TP="${TP:-2}"
PORT="${PORT:-8888}"
SERVED_NAME="${SERVED_MODEL_NAME:-qwen3.8-flash-next}"
MAX_SEQ_LEN="${MAX_SEQ_LEN:-262144}"
MAX_BATCH="${MAX_BATCH:-10}"
MAX_TOKENS="${MAX_TOKENS:-65536}"
PREFIX_CACHE="${PREFIX_CACHE:-on}"
RDMA_DEV="${RDMA_DEV:-rocep1s0f0,roceP2p1s0f0}"
WORKER_HOST="${WORKER_HOST:-ai2}"
TP_DH_SHARD="${TP_DH_SHARD:-off}"
SPEC_PASS="${SPEC_PASS:-0}"
MODEL_DIR="${MODEL_DIR:-}"
NODES="${NODES:-}"
IS_DRY_RUN="${DRY_RUN:-0}"
OTEL_ENDPOINT="${OTEL_ENDPOINT:-http://192.168.20.16:9381}"
MEM_WATCHDOG_GB="${MEM_WATCHDOG_GB:-3}"
PLE_RAM="${PLE_RAM:-auto}"
MTP_K="${MTP_K:-${MTP_DEPTH:-${MTP:-3}}}"
USER_ARGS=()

show_help() {
  cat << 'EOF'
Usage: ./launch_qwen38_flash_next.sh [1|2|4] [OPTIONS] [-- EXTRA_FLAGS]

Launch Qwen3.8-Flash-Next EXL3 (heretic / 3.05bpw) on veloGB10.

Topologies:
  1, --tp 1                Single machine (TP=1, no worker nodes)
  2, --tp 2                TP=2 across ai (head) + ai2 (worker) [default]
  4, --tp 4                TP=4 across 4 DGX Spark nodes

Options:
  -p, --port PORT          Server port (default: 8888)
  -b, --max-batch N        Max concurrent sequences/lanes (default: 10)
  -m, --model-dir PATH     Explicit path to EXL3 pack (auto-detected if omitted)
  -n, --nodes LIST         Node list (default: 192.168.177.12:29500 for TP=2)
  --name NAME              Served model name (default: qwen3.8-flash-next)
  --mtp, --mtp-depth N     Speculative decoding draft depth / MTP K (default: 3)
  --otel-endpoint URL      OpenTelemetry collector endpoint (default: http://192.168.20.16:9381)
  --no-otel                Disable OpenTelemetry export
  --dry-run                Validate and display command without launching
  -h, --help               Show this help message

Environment Overrides:
  TP, PORT, MAX_BATCH, MODEL_DIR, NODES, WORKER_HOST, RDMA_DEV, MAX_SEQ_LEN, OTEL_ENDPOINT
EOF
  exit 0
}

# Parse CLI arguments
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      show_help
      ;;
    1|2|4)
      TP="$1"
      shift
      ;;
    --tp)
      TP="${2:-2}"
      shift 2
      ;;
    --tp=*)
      TP="${1#*=}"
      shift
      ;;
    -p|--port)
      PORT="$2"
      shift 2
      ;;
    --port=*)
      PORT="${1#*=}"
      shift
      ;;
    -m|--model-dir)
      MODEL_DIR="$2"
      shift 2
      ;;
    --model-dir=*)
      MODEL_DIR="${1#*=}"
      shift
      ;;
    -n|--nodes)
      NODES="$2"
      shift 2
      ;;
    --nodes=*)
      NODES="${1#*=}"
      shift
      ;;
    --name|--served-name|--served-model-name)
      SERVED_NAME="$2"
      shift 2
      ;;
    --served-name=*|--served-model-name=*)
      SERVED_NAME="${1#*=}"
      shift
      ;;
    -b|--batch|--max-batch)
      MAX_BATCH="$2"
      shift 2
      ;;
    --batch=*|--max-batch=*)
      MAX_BATCH="${1#*=}"
      shift
      ;;
    --otel-endpoint)
      OTEL_ENDPOINT="$2"
      shift 2
      ;;
    --otel-endpoint=*)
      OTEL_ENDPOINT="${1#*=}"
      shift
      ;;
    --no-otel)
      OTEL_ENDPOINT=""
      shift
      ;;
    --mem-watchdog-gb)
      MEM_WATCHDOG_GB="$2"
      shift 2
      ;;
    --mem-watchdog-gb=*)
      MEM_WATCHDOG_GB="${1#*=}"
      shift
      ;;
    --ple-ram)
      PLE_RAM="$2"
      shift 2
      ;;
    --ple-ram=*)
      PLE_RAM="${1#*=}"
      shift
      ;;
    --mtp-k|--mtp-depth|--exl3-mtp-k)
      MTP_K="$2"
      shift 2
      ;;
    --mtp-k=*|--mtp-depth=*|--exl3-mtp-k=*)
      MTP_K="${1#*=}"
      shift
      ;;
    --mtp)
      if [[ "$2" =~ ^[0-9]+$ ]]; then
        MTP_K="$2"
        shift 2
      else
        USER_ARGS+=("--mtp" "$2")
        shift 2
      fi
      ;;
    --mtp=*)
      val="${1#*=}"
      if [[ "$val" =~ ^[0-9]+$ ]]; then
        MTP_K="$val"
      else
        USER_ARGS+=("$1")
      fi
      shift
      ;;
    --dry-run)
      IS_DRY_RUN=1
      shift
      ;;
    --)
      shift
      USER_ARGS+=("$@")
      break
      ;;
    *)
      USER_ARGS+=("$1")
      shift
      ;;
  esac
done

# Resolve model directory if not explicitly provided
if [ -z "$MODEL_DIR" ]; then
  for candidate in \
    /mnt/nvmeof/huggingface/hub/models--jeffpeng3--Qwen3.8-Flash-Next-exl3-3.05bpw-heretic/snapshots/* \
    "${HOME}/.cache/huggingface/hub/models--jeffpeng3--Qwen3.8-Flash-Next-exl3-3.05bpw-heretic/snapshots"/* \
    "${REPO_ROOT}/Qwen3.8-Flash-Next-exl3-3.05bpw-heretic" \
    "${HOME}/models/Qwen3.8-Flash-Next-exl3-3.05bpw-heretic" \
    /mnt/nvmeof/huggingface/hub/models--doth4580--Qwen3.8-Flash-Next-EXL3-3.05bpw/snapshots/* \
    "${HOME}/.cache/huggingface/hub/models--doth4580--Qwen3.8-Flash-Next-EXL3-3.05bpw/snapshots"/* \
    "${REPO_ROOT}/Qwen3.8-Flash-Next-EXL3-3.05bpw" \
    "${HOME}/models/Qwen3.8-Flash-Next-EXL3-3.05bpw"; do
    if [ -f "$candidate/config.json" ]; then
      MODEL_DIR="$candidate"
      break
    fi
  done
fi

if [ -z "$MODEL_DIR" ] || [ ! -f "$MODEL_DIR/config.json" ]; then
  echo "ERROR: Could not locate Qwen3.8-Flash-Next EXL3 pack with config.json." >&2
  echo "Set MODEL_DIR=/path/to/pack or download with:" >&2
  echo "  hf download jeffpeng3/Qwen3.8-Flash-Next-exl3-3.05bpw-heretic" >&2
  echo "  # or: hf download doth4580/Qwen3.8-Flash-Next-EXL3-3.05bpw" >&2
  exit 1
fi

# Base server arguments
CMD=(
  "$BIN" --server
  --model-dir "$MODEL_DIR"
  --served-model-name "$SERVED_NAME"
  --port "$PORT"
  --max-seq-len "$MAX_SEQ_LEN"
  --max-batch "$MAX_BATCH"
  --max-tokens "$MAX_TOKENS"
  --prefix-cache "$PREFIX_CACHE"
  --ple-ram "$PLE_RAM"
  --mem-watchdog-gb "$MEM_WATCHDOG_GB"
)

if [ -n "$MTP_K" ]; then
  CMD+=(--exl3-mtp-k "$MTP_K")
fi

if [ -n "$OTEL_ENDPOINT" ]; then
  CMD+=(--otel-endpoint "$OTEL_ENDPOINT")
fi

if [ "$TP" -gt 1 ]; then
  CMD+=(--tp "$TP")

  if [ -z "$NODES" ]; then
    if [ "$TP" -eq 2 ]; then
      NODES="192.168.177.12:29500"
    elif [ "$TP" -eq 4 ]; then
      NODES="192.168.177.12:29500,192.168.177.13:29500,192.168.177.14:29500"
    fi
  fi

  if [ -n "$NODES" ]; then
    CMD+=(--nodes "$NODES")
  fi

  if [ -n "$RDMA_DEV" ]; then
    CMD+=(--rdma-dev "$RDMA_DEV")
  fi

  if [ -n "$TP_DH_SHARD" ]; then
    CMD+=(--tp-dh-shard "$TP_DH_SHARD")
  fi

  if [ -n "$SPEC_PASS" ]; then
    CMD+=(--spec-pass "$SPEC_PASS")
  fi

  # Auto-check/start peer node if target is ai2
  if [ "$TP" -eq 2 ] && [[ "$NODES" == *"192.168.177.12"* ]]; then
    if ssh -o BatchMode=yes -o ConnectTimeout=3 -n "$WORKER_HOST" "true" 2>/dev/null; then
      if ! ssh -n "$WORKER_HOST" "pgrep -f 'gb10_inference.*--node' >/dev/null 2>&1"; then
        echo "=== Peer node on $WORKER_HOST not running. Starting supervisor... ==="
        ssh -f "$WORKER_HOST" "cd '$REPO_ROOT' && nohup ./gb10_inference --node --port 29500 --rdma-dev '$RDMA_DEV' >'$REPO_ROOT/node_${WORKER_HOST}.log' 2>&1 < /dev/null"
        sleep 1
      else
        echo "=== Peer node already running on $WORKER_HOST ==="
      fi
    fi
  fi
fi

if [ ${#USER_ARGS[@]} -gt 0 ]; then
  CMD+=("${USER_ARGS[@]}")
fi

echo "=========================================================="
echo " Launching Qwen 3.8 Flash-Next EXL3 on veloGB10"
echo "=========================================================="
echo " Model:       $MODEL_DIR"
echo " Served Name: $SERVED_NAME"
echo " Topology:    TP=$TP"
[ "$TP" -gt 1 ] && echo " Nodes:       $NODES"
echo " Port:        $PORT"
[ -n "$MTP_K" ] && echo " MTP Depth:   k=$MTP_K (speculative decoding)"
echo " Context:     $MAX_SEQ_LEN tokens (256K full)"
echo " Batch:       $MAX_BATCH lanes"
echo " OTel Server: ${OTEL_ENDPOINT:-disabled}"
echo " Working Dir: $REPO_ROOT"
echo " Command:     ${CMD[*]}"
echo "=========================================================="

if [ "$IS_DRY_RUN" = "1" ]; then
  echo
  echo "=== [DRY RUN] Command validated successfully (not executing) ==="
  exit 0
fi

exec "${CMD[@]}"
