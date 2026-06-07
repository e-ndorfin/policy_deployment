#!/bin/bash
# Run the policy server inside a Yonsei SLURM GPU allocation and expose it
# through a reverse SSH tunnel to a public VM.
#
# Required environment:
#   POLICY_SERVER_API_KEYS  API key accepted by the policy server.
#   TUNNEL_SSH_TARGET       SSH target for the VM, e.g. deploy@vm.example.com.
#
# Common optional environment:
#   TUNNEL_SSH_KEY          Private key path for the VM SSH login.
#   TUNNEL_REMOTE_PORT      VM localhost port Caddy/nginx proxies to. Default: 18000.
#   POLICY_SPEC             Policy import path. Default: examples.echo_policy:EchoPolicy.
#   POLICY_KWARGS           Space-separated k=v constructor args for the policy.

#SBATCH -J policy_server
#SBATCH -o logs/%x.%j.out
#SBATCH -e logs/%x.%j.err
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=4
#SBATCH --time=08:00:00

set -euo pipefail

require_env() {
    local name="$1"
    if [[ -z "${!name:-}" ]]; then
        echo "Missing required environment variable: ${name}" >&2
        exit 2
    fi
}

cleanup() {
    local rc=$?
    trap - EXIT INT TERM
    if [[ -n "${TUNNEL_LOOP_PID:-}" ]]; then
        kill "${TUNNEL_LOOP_PID}" 2>/dev/null || true
        wait "${TUNNEL_LOOP_PID}" 2>/dev/null || true
    fi
    if [[ -n "${SERVER_PID:-}" ]]; then
        kill "${SERVER_PID}" 2>/dev/null || true
        wait "${SERVER_PID}" 2>/dev/null || true
    fi
    exit "${rc}"
}

trap cleanup EXIT INT TERM

require_env POLICY_SERVER_API_KEYS
require_env TUNNEL_SSH_TARGET

REPO_DIR="${POLICY_REPO_DIR:-${SLURM_SUBMIT_DIR:-$(pwd)}}"
PYTHON_BIN="${PYTHON_BIN:-python}"
POLICY_SPEC="${POLICY_SPEC:-examples.echo_policy:EchoPolicy}"
POLICY_HOST="${POLICY_HOST:-127.0.0.1}"
POLICY_PORT="${POLICY_PORT:-8000}"
MAX_CONNECTIONS="${MAX_CONNECTIONS:-4}"
MAX_MESSAGE_SIZE="${MAX_MESSAGE_SIZE:-33554432}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"

TUNNEL_REMOTE_BIND="${TUNNEL_REMOTE_BIND:-127.0.0.1}"
TUNNEL_REMOTE_PORT="${TUNNEL_REMOTE_PORT:-18000}"
TUNNEL_RETRY_SECONDS="${TUNNEL_RETRY_SECONDS:-5}"
TUNNEL_RETRY_LIMIT="${TUNNEL_RETRY_LIMIT:-0}"

echo "START: $(date)"
echo "HOST: $(hostname -f 2>/dev/null || hostname)"
echo "SLURM_JOB_ID=${SLURM_JOB_ID:-}"
echo "CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-}"
echo "REPO_DIR=${REPO_DIR}"
echo "POLICY_SPEC=${POLICY_SPEC}"
echo "POLICY_ENDPOINT=ws://${POLICY_HOST}:${POLICY_PORT}"
echo "TUNNEL=${TUNNEL_REMOTE_BIND}:${TUNNEL_REMOTE_PORT} -> ${POLICY_HOST}:${POLICY_PORT}"

if [[ -n "${CONDA_ENV:-}" ]]; then
    # Yonsei sbatch jobs need the shell init before conda is available.
    # shellcheck disable=SC1090
    source "${HOME}/.bashrc"
    conda activate "${CONDA_ENV}"
fi

cd "${REPO_DIR}"
export PYTHONPATH="${REPO_DIR}${PYTHONPATH:+:${PYTHONPATH}}"
export HF_HOME="${HF_HOME:-/scratch/${USER}/.cache/huggingface}"
export TRANSFORMERS_CACHE="${TRANSFORMERS_CACHE:-${HF_HOME}}"
export TORCH_HOME="${TORCH_HOME:-/scratch/${USER}/.cache/torch}"
export PIP_CACHE_DIR="${PIP_CACHE_DIR:-/scratch/${USER}/.cache/pip}"

mkdir -p "${HF_HOME}" "${TORCH_HOME}" "${PIP_CACHE_DIR}"

LAUNCH_ARGS=(
    scripts/launch.py
    --policy "${POLICY_SPEC}"
    --host "${POLICY_HOST}"
    --port "${POLICY_PORT}"
    --max-connections "${MAX_CONNECTIONS}"
    --max-message-size "${MAX_MESSAGE_SIZE}"
    --log-level "${LOG_LEVEL}"
)

if [[ -n "${POLICY_KWARGS:-}" ]]; then
    read -r -a POLICY_KWARGS_ARRAY <<< "${POLICY_KWARGS}"
    for kv in "${POLICY_KWARGS_ARRAY[@]}"; do
        LAUNCH_ARGS+=(--policy-kwargs "${kv}")
    done
fi

if [[ -n "${POLICY_ALLOW_CIDRS:-}" ]]; then
    read -r -a POLICY_ALLOW_CIDRS_ARRAY <<< "${POLICY_ALLOW_CIDRS}"
    for cidr in "${POLICY_ALLOW_CIDRS_ARRAY[@]}"; do
        LAUNCH_ARGS+=(--allow-cidr "${cidr}")
    done
fi

echo "Launching policy server..."
"${PYTHON_BIN}" "${LAUNCH_ARGS[@]}" &
SERVER_PID=$!

for _ in $(seq 1 60); do
    if curl -fsS "http://${POLICY_HOST}:${POLICY_PORT}/healthz" >/dev/null 2>&1; then
        echo "Policy server health check passed."
        break
    fi
    if ! kill -0 "${SERVER_PID}" 2>/dev/null; then
        echo "Policy server exited before becoming healthy." >&2
        wait "${SERVER_PID}"
    fi
    sleep 1
done

if ! curl -fsS "http://${POLICY_HOST}:${POLICY_PORT}/healthz" >/dev/null; then
    echo "Policy server did not become healthy within 60 seconds." >&2
    exit 1
fi

SSH_ARGS=(
    -N
    -T
    -o BatchMode=yes
    -o ExitOnForwardFailure=yes
    -o ServerAliveInterval=30
    -o ServerAliveCountMax=3
    -o StrictHostKeyChecking=accept-new
)

if [[ -n "${TUNNEL_SSH_PORT:-}" ]]; then
    SSH_ARGS+=(-p "${TUNNEL_SSH_PORT}")
fi

if [[ -n "${TUNNEL_SSH_KEY:-}" ]]; then
    SSH_ARGS+=(-i "${TUNNEL_SSH_KEY}" -o IdentitiesOnly=yes)
fi

SSH_ARGS+=(
    -R "${TUNNEL_REMOTE_BIND}:${TUNNEL_REMOTE_PORT}:${POLICY_HOST}:${POLICY_PORT}"
    "${TUNNEL_SSH_TARGET}"
)

tunnel_loop() {
    local attempt=0
    local rc=0

    while kill -0 "${SERVER_PID}" 2>/dev/null; do
        attempt=$((attempt + 1))
        echo "Opening reverse SSH tunnel, attempt ${attempt}..."
        set +e
        ssh "${SSH_ARGS[@]}"
        rc=$?
        set -e

        if ! kill -0 "${SERVER_PID}" 2>/dev/null; then
            break
        fi

        echo "Tunnel exited with status ${rc}; retrying in ${TUNNEL_RETRY_SECONDS}s."
        if [[ "${TUNNEL_RETRY_LIMIT}" != "0" && "${attempt}" -ge "${TUNNEL_RETRY_LIMIT}" ]]; then
            echo "Tunnel retry limit reached." >&2
            return "${rc}"
        fi
        sleep "${TUNNEL_RETRY_SECONDS}"
    done
}

tunnel_loop &
TUNNEL_LOOP_PID=$!

while true; do
    if ! kill -0 "${TUNNEL_LOOP_PID}" 2>/dev/null; then
        set +e
        wait "${TUNNEL_LOOP_PID}"
        tunnel_rc=$?
        set -e
        if [[ "${tunnel_rc}" -ne 0 ]]; then
            kill "${SERVER_PID}" 2>/dev/null || true
            wait "${SERVER_PID}" 2>/dev/null || true
            exit "${tunnel_rc}"
        fi
    fi

    if ! kill -0 "${SERVER_PID}" 2>/dev/null; then
        set +e
        wait "${SERVER_PID}"
        server_rc=$?
        set -e
        exit "${server_rc}"
    fi

    sleep 1
done
