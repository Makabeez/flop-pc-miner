#!/usr/bin/env bash
# flop-miner.sh — FLOP devnet GPU miner on a Windows PC with an NVIDIA GPU, in a dedicated WSL2 distro "flop-miner".
# https://github.com/Makabeez/flop-pc-miner  (MIT). Tested on an RTX 5080 (16 GB), Windows 11, Ubuntu 24.04.
#
# Trust model (everything below is checked by this script, nothing is taken from third parties):
#   - Container images: only ghcr.io/flop-labs/flop-core/* (the official github.com/flop-labs org),
#     pulled by sha256 digest exactly as listed in Flop's official https://flop.network/releases.json.
#     One exception: when the chain runs a newer runtime than the CLI in releases.json supports, the CLI
#     is the newest version tag of that same official image that works with the live chain (pinned by digest).
#   - Model hash and decode policy: taken from that same official releases.json.
#   - Sponsor request: the documented POST https://faucet.flop.network/sponsor/miner, signed message
#     "flop-sponsor/v1|miner|<genesis>|<address>|<issuedAt>"; only address + signature leave the PC.
#   - System packages: Ubuntu, Docker, NVIDIA and Cloudflare official signed apt repositories.
#   - Exposure: nothing listens on your LAN. The only public entry is the Cloudflare tunnel to the
#     worker's session port (127.0.0.1:8645), which refuses requests without SESSION_AUTH_TOKEN.
#   - Secrets (miner seed, session seed, tokens) stay in /opt/flop-miner, mode 600; seeds root-owned.
#   - One community tool, optional but installed by setup: the signer-fence guard from
#     github.com/UfukNode/flop-miner-setup, downloaded at one reviewed commit and checked file by file
#     against the sha256 values below before anything runs. It never signs or sends a transaction.
#
#   ./flop-miner.sh prereqs   once, first: Docker Engine + NVIDIA Container Toolkit from their official apt repos
#   ./flop-miner.sh setup     once: verify official release list, settings, images, key, sponsor, model, tunnel
#   ./flop-miner.sh harden    once, after setup: cut this distro off from your Windows files and programs
#   ./flop-miner.sh up        each session: tunnel -> new HTTPS address -> backend -> worker
#   ./flop-miner.sh status    chain status, calibration, tunnel, GPU power, last worker lines
#   ./flop-miner.sh logs      follow the worker log (Ctrl+C leaves the log; the miner keeps running)
#   ./flop-miner.sh sponsor   ask the sponsor (waits as long as it asks), or top up stake if calibration runs short
#   ./flop-miner.sh toploc on|off   switch the optional TOPLOC activation proof (kept across restarts)
#   ./flop-miner.sh commitids on|off   SESSION_COMMIT_IDS (Flop Labs' fix for the V2 leaf + TOPLOC error, 8 Nov 2026)
#   ./flop-miner.sh fence     signer-fence status; `fence install` sets up the guard that clears a fence safely
#   ./flop-miner.sh update    after Flop upgrades the chain: newest official images that support it, then restart
#   ./flop-miner.sh down      stop worker, backend and tunnel (run before switching the PC off)
#   ./flop-miner.sh version   print this script's version
#
# Devnet only: no rewards, no airdrop weight. Unanswered network test jobs expire after 600 blocks and
# cut the sponsored stake, so run `down` before switching the PC off. Never reuse the miner seed.
set -euo pipefail

D=/opt/flop-miner
RELEASES_URL=https://flop.network/releases.json
SPONSOR_URL=https://faucet.flop.network
RPC=wss://rpc.devnet.flop.network
MAILBOX=https://mailbox.devnet.flop.network
GENESIS=0x99c172c095340ace980631f9123544c6bebd4839f3437e463533422d8be2d631
MODEL_HASH=0x1a52c1abe781db051e70ae357f72bb70161ca0c092df0b618f22a9292ba63306
MODEL_NAME=Qwen/Qwen2.5-0.5B-Instruct
MODEL_SLUG=qwen/qwen2.5-0.5b-instruct
GPU_UTIL_ARG="${GPU_UTIL:-}"; WORKER_NAME_ARG="${WORKER_NAME:-}"   # only override saved values when given
GPU_UTIL="${GPU_UTIL:-0.6}"
WORKER_NAME="${WORKER_NAME:-flop-pc-miner}"   # public label; choose yours: WORKER_NAME=alice-4090 ./flop-miner.sh setup
VERSION=1.2.0
# CLI v0.1.290 reports a verified model without an "ok" field, so the model check also accepts
# verified_root == MODEL_HASH (the root the CLI recomputed from the files, compared with the chain).
# Floor for the CLI image. The chain's runtime can move ahead of the CLI listed in releases.json: on 7 Nov 2026
# (runtime 1014014, releases.json cli v0.1.220) and again on 11 Nov 2026 (runtime 1014020, releases.json
# cli v0.1.321, both too old). v0.1.342 is published by the same official org and supports 1014020.
# setup and update start from the newer of this floor and releases.json, test it against the live chain,
# and if the chain rejects it, try newer version tags of the same official image (see pick_cli).
MIN_CLI=ghcr.io/flop-labs/flop-core/cli:v0.1.342@sha256:8972372a89f804909c483e1d3578dd57642e88ef0c01fbca26cf2276176775e1
# Signer-fence guard (community, UfukNode/flop-miner-setup), pinned to the commit reviewed for this repo.
# If an RPC drop leaves a transaction unconfirmed, the worker "fences" its signer: it stops signing,
# answers 503 and gets no gateway work, and restarts do not clear it. The guard clears it only once the
# chain proves the stuck transaction can never be included (archives the fence first, max 3 per 6 h).
FENCE_GUARD_COMMIT=ad2d5224cc6e258e8dadf47b9f98126e4816055b
FENCE_GUARD_FILES="e606193fb5434997343ca7eee4a8d3177d49709d71120ba352101b02d139be2f fence-guard.sh
4fb5788db9e51650912af01fcfd4da8483cbe0e5f9478406385eb76c466c43b7 status.mjs
6d3b07d76a04a4b536c97e4d358cd5af25d74be99c31d5b877aefba4d9ba351d recover.mjs
f0fcd78fe292ec50c7f985278039159790f9d1cd3663320454f3d290be4261c0 reconcile.mjs
c2daba8e5af7729a24b15bb5d6d13db705797ebe8421cb8806bc638389056459 flop-fence-guard.service
778986ac88ed04a9db7a3ba2841599b80d0c133a65b1163a264e98fe84076853 flop-fence-guard.timer"

die()  { echo "error: $*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }

: "${USER:=$(id -un)}"   # not always set when WSL runs a command without a login shell
[ "${WSL_DISTRO_NAME:-}" = flop-miner ] || die "run this inside the flop-miner WSL distro (this is: ${WSL_DISTRO_NAME:-not WSL})"
need_docker() {
  command -v docker >/dev/null || die "docker is not installed in this distro yet: run ./flop-miner.sh prereqs"
  docker info >/dev/null 2>&1 || die "docker needs sudo here: in PowerShell run 'wsl --terminate flop-miner', reopen the distro, retry"
}

envget()  { grep "^$1=" "$D/miner.env" | head -n 1 | cut -d= -f2-; }
envset()  { if grep -q "^$1=" "$D/miner.env"; then sed -i "s|^$1=.*|$1=$2|" "$D/miner.env"; else echo "$1=$2" >> "$D/miner.env"; fi; }
cli()     { docker run --rm --network host -v "$D:/work" "$(envget FLOP_CLI)" "$@"; }
compose() { docker compose --env-file "$D/miner.env" -f "$D/docker-compose.yml" "$@"; }
address() { [ -f "$D/address" ] || die "no miner key yet: run ./flop-miner.sh setup"; cat "$D/address"; }
backend_ready() {
  compose exec -T backend python3 -c 'import os, urllib.request as u; u.urlopen(u.Request("http://127.0.0.1:8000/health", headers={"Authorization": "Bearer " + os.environ["INFERENCE_API_KEY"]}), timeout=5)' >/dev/null 2>&1
}

# --- official release list and image versions ---------------------------------------------------------
# Reads releases.json into REL_CLI, REL_WORKER, REL_BACKEND, REL_POLICY_HASH, REL_POLICY (all validated).
load_release() {
  local rel img
  rel=$(curl -fsS --proto '=https' "$RELEASES_URL") || die "cannot read $RELEASES_URL"
  REL_CLI=$(jq -r '.cli.image' <<<"$rel")
  REL_WORKER=$(jq -r '."miner-worker".image' <<<"$rel")
  REL_BACKEND=$(jq -r '."miner-vllm-toploc".image' <<<"$rel")
  for img in "$REL_CLI" "$REL_WORKER" "$REL_BACKEND"; do
    valid_ref "$img" || die "release list returned an unexpected image reference: $img"
    echo "  $img"
  done
  jq -e --arg m "$MODEL_HASH" '.models[$m].name' <<<"$rel" >/dev/null || die "model $MODEL_HASH is not in the official release list"
  REL_POLICY_HASH=$(jq -r --arg m "$MODEL_HASH" '.models[$m].decode_policies | keys[0]' <<<"$rel")
  [[ "$REL_POLICY_HASH" =~ ^0x[0-9a-f]{64}$ ]] || die "no decode policy for the model in the release list"
  REL_POLICY=$(jq -c --arg m "$MODEL_HASH" --arg p "$REL_POLICY_HASH" '.models[$m].decode_policies[$p]' <<<"$rel")
  echo "  model $MODEL_HASH ($MODEL_NAME), decode policy $REL_POLICY_HASH"
}
valid_ref() { [[ "$1" =~ ^ghcr\.io/flop-labs/flop-core/[a-z0-9-]+:v[0-9.]+@sha256:[0-9a-f]{64}$ ]]; }
img_ver()   { sed -E 's/.*:v([0-9.]+)@.*/\1/' <<<"$1"; }
img_tag()   { sed -E 's/.*:(v[0-9.]+)@.*/\1/' <<<"$1"; }
# The newer of two image references by version tag (an empty or invalid one loses).
newer_img() {
  valid_ref "${2:-}" || { echo "$1"; return; }
  valid_ref "${1:-}" || { echo "$2"; return; }
  if [ "$(printf '%s\n%s\n' "$(img_ver "$1")" "$(img_ver "$2")" | sort -V | tail -n 1)" = "$(img_ver "$1")" ]; then echo "$1"; else echo "$2"; fi
}
# Runtime spec version the live chain runs (JSON-RPC over HTTPS on the same endpoint).
chain_spec() {
  curl -fsS --proto '=https' -m 20 -H 'Content-Type: application/json' \
    -d '{"id":1,"jsonrpc":"2.0","method":"state_getRuntimeVersion","params":[]}' "${RPC/wss:/https:}" \
    | jq -r '.result.specVersion // empty' 2>/dev/null || true
}
# Read-only, anonymous access to the official image repository (the same API `docker pull` uses).
GHCR_ACCEPT='application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'
ghcr_token() { curl -fsS --proto '=https' -m 20 "https://ghcr.io/token?scope=repository:flop-labs/flop-core/$1:pull" | jq -r '.token // empty'; }
ghcr_tags() {   # version tags of one official image, oldest first
  local t; t=$(ghcr_token "$1") && [ -n "$t" ] || return 1
  curl -fsS --proto '=https' -m 30 -H "Authorization: Bearer $t" "https://ghcr.io/v2/flop-labs/flop-core/$1/tags/list?n=1000" \
    | jq -r '.tags[]?' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V
}
ghcr_ref() {    # image + tag -> reference pinned by the digest the registry serves for that tag
  local t d; t=$(ghcr_token "$1") && [ -n "$t" ] || return 1
  d=$(curl -fsSI --proto '=https' -m 20 -H "Authorization: Bearer $t" -H "Accept: $GHCR_ACCEPT" \
        "https://ghcr.io/v2/flop-labs/flop-core/$1/manifests/$2" | tr -d '\r' | awk 'tolower($1)=="docker-content-digest:" {print $2}')
  [[ "$d" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
  echo "ghcr.io/flop-labs/flop-core/$1:$2@$d"
}
# Does this CLI image work with the live chain? 0 yes, 1 runtime too new for it, 2 cannot tell (pull or RPC failed).
cli_fits() {
  local out who try
  docker pull -q "$1" >/dev/null 2>&1 || docker pull -q "$1" >/dev/null 2>&1 || return 2
  who=$(cat "$D/address" 2>/dev/null || echo 5GrwvaEF5zXb26Fz9rcQpDWS57CtERHpNehXCPcNoHGKutQY)   # any address makes it connect
  for try in 1 2; do
    out=$(docker run --rm --network host "$1" --network devnet --rpc "$RPC" miner status "$who" --json 2>&1 || true)
    grep -q RUNTIME_INCOMPATIBLE <<<"$out" && return 1
    grep -q '"registered"' <<<"$out" && return 0
    grep -qiE 'RPC_UNREACHABLE|not connected|timed out' <<<"$out" || return 0
    [ "$try" = 1 ] && sleep 10
  done
  return 2
}
# Picks the CLI to use: the newer of releases.json's and MIN_CLI (and the current one), if the chain accepts it;
# otherwise the newest official version tag above it that the chain accepts. Prints the reference;
# progress goes to stderr. Fails if the chain cannot be reached or no published CLI supports its runtime yet.
pick_cli() {
  local best rc tag ref tried=0
  best=$(newer_img "$1" "$MIN_CLI"); best=$(newer_img "$best" "$(envget FLOP_CLI 2>/dev/null || true)")
  rc=0; cli_fits "$best" || rc=$?
  case $rc in
    0) echo "  cli $(img_tag "$best") works with the chain" >&2; echo "$best"; return 0 ;;
    2) echo "  could not check cli $(img_tag "$best") against the chain (pull failed or RPC unreachable)" >&2; return 2 ;;
  esac
  echo "  cli $(img_tag "$best") does not support the chain's runtime; trying newer official CLI tags" >&2
  for tag in $(ghcr_tags cli | tac); do
    [ "$(printf '%s\n%s\n' "${tag#v}" "$(img_ver "$best")" | sort -V | tail -n 1)" = "${tag#v}" ] || break
    [ "${tag#v}" = "$(img_ver "$best")" ] && break
    tried=$((tried + 1)); [ "$tried" -le 8 ] || break
    ref=$(ghcr_ref cli "$tag") || continue
    rc=0; cli_fits "$ref" || rc=$?
    [ "$rc" = 0 ] && { echo "  cli $tag works with the chain" >&2; echo "$ref"; return 0; }
    echo "  cli $tag: $( [ "$rc" = 1 ] && echo 'too old as well' || echo 'could not check')" >&2
  done
  return 1
}

write_compose() {
  # Same services as the community guide (UfukNode/FLOP-Miner-Kurulum), reviewed line by line, plus
  # GPU_MEMORY_UTILIZATION for a desktop GPU. Backend: no published port. Worker: localhost-only port.
  # Secrets are mounted read-only. No privileged mode, no Docker socket, no host paths beyond this folder.
  cat > "$D/docker-compose.yml" <<'EOF'
name: flop-miner

services:
  backend:
    image: ${FLOP_BACKEND_IMAGE:?set FLOP_BACKEND_IMAGE in miner.env}
    restart: unless-stopped
    environment:
      MODEL_NAME: ${MODEL_NAME}
      MODEL_HASH: ${MODEL_HASH}
      MODEL_DIR: /models/checkpoint
      GPU_MEMORY_UTILIZATION: ${GPU_MEMORY_UTILIZATION:-0.6}
      TOPLOC_PRECISION: ${TOPLOC_PRECISION}
      DECODE_POLICY: ${DECODE_POLICY}
      DECODE_POLICY_HASH: ${DECODE_POLICY_HASH}
      INFERENCE_API_KEY: ${INFERENCE_API_KEY:?set INFERENCE_API_KEY in miner.env}
    volumes:
      - ./models/qwen2.5-0.5b-instruct:/models/checkpoint:ro
    ipc: host
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]

  worker:
    image: ${FLOP_WORKER_IMAGE:?set FLOP_WORKER_IMAGE in miner.env}
    restart: unless-stopped
    depends_on:
      - backend
    command: ["--rpc", "${FLOP_RPC}"]
    working_dir: /data
    environment:
      MINER_BACKEND: openai
      OPENAI_BASE_URL: http://backend:8000/v1
      INFERENCE_API_KEY: ${INFERENCE_API_KEY}
      MINER_MODEL: ${MODEL_NAME}
      OPENROUTER_MODEL_SLUG: ${OPENROUTER_MODEL_SLUG}
      WORKER_NAME: ${WORKER_NAME}
      MINER_SIGNER_FILE: /run/flop/signer
      MINER_ENCLAVE_KEY_FILE: /run/flop/enclave.seed
      MODEL_HASH: ${MODEL_HASH}
      MODEL_PRECISION: ${MODEL_PRECISION}
      MODEL_CHECKPOINT_DIR: /models/checkpoint
      DECODE_POLICY_HASH: ${DECODE_POLICY_HASH}
      TOPLOC_ENABLED: "${TOPLOC_ENABLED:-1}"
      TOPLOC_PRECISION: ${TOPLOC_PRECISION}
      SESSION_PORT: "8645"
      SESSION_CHAIN: "1"
      SESSION_COMMIT_IDS: "${SESSION_COMMIT_IDS:-1}"
      SESSION_AUTH_TOKEN: ${SESSION_AUTH_TOKEN:?set SESSION_AUTH_TOKEN in miner.env}
      SESSION_PUBLIC_HOST: ${SESSION_PUBLIC_HOST}
      GHOST_MAILBOX_URL: ${GHOST_MAILBOX_URL}
      GHOST_KEY_FILE: /data/ghost-x25519.json
    volumes:
      - ./signer:/run/flop/signer:ro
      - ./session-keys/enclave.seed:/run/flop/enclave.seed:ro
      - ./models/qwen2.5-0.5b-instruct:/models/checkpoint:ro
      - worker-data:/data
    ports:
      - "127.0.0.1:8645:8645"

volumes:
  worker-data:

# WSL's own network link can be smaller than Docker's default 1500-byte packets (1280 on the test PC).
# Without matching it, TLS/WebSocket connections from the miner network stall and drop (1006).
networks:
  default:
    driver_opts:
      com.docker.network.driver.mtu: "${NET_MTU:-1280}"
EOF
}

write_sponsor() {
  # Reviewed: signs the documented message with the miner seed and POSTs only
  # {address, issuedAt, signature} to the official sponsor. It never prints or sends the seed,
  # and refuses to sign if the sponsor reports a different chain than the FLOP devnet.
  cat > "$D/sponsor.mjs" <<'EOF'
import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';
const require = createRequire('/app/');
const { Keyring } = require('@polkadot/keyring');
const { cryptoWaitReady } = require('@polkadot/util-crypto');
const SPONSOR = process.env.SPONSOR_URL;
const GENESIS = process.env.EXPECTED_GENESIS;
const seed = readFileSync('/work/signer', 'utf8').trim();
await cryptoWaitReady();
const pair = new Keyring({ type: 'sr25519', ss58Format: 42 }).addFromUri(seed);
const chain = await (await fetch(`${SPONSOR}/chain`)).json();
if (chain.genesisHash !== GENESIS) { console.log(`refusing: sponsor reports genesis ${chain.genesisHash}`); process.exit(1); }
const issuedAt = String(Date.now());
const message = `flop-sponsor/v1|miner|${chain.genesisHash}|${pair.address}|${issuedAt}`;
const signature = `0x${Buffer.from(pair.sign(new Uint8Array(Buffer.from(message, 'utf8')))).toString('hex')}`;
console.log(`Miner address: ${pair.address}`);
const res = await fetch(`${SPONSOR}/sponsor/miner`, {
  method: 'POST', headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ address: pair.address, issuedAt, signature }),
});
console.log(`HTTP ${res.status}`);
console.log(await res.text());
process.exit(res.ok ? 0 : 1);
EOF
  chmod 644 "$D/sponsor.mjs"
}

is_registered() {
  # true when the chain already lists this miner (then the sponsor must not be asked again)
  cli --network devnet --rpc "$RPC" miner status "$(address)" --json 2>/dev/null \
    | jq -e '(.registered // false) | if type == "boolean" then . else (. != null and . != 0) end' >/dev/null 2>&1
}

# Retry the sponsor, waiting as long as it asks (retryAfterSeconds, at least 3 min). Prints the real reason.
sponsor_until_ok() {
  local tries="$1" i out wait reason
  for i in $(seq 1 "$tries"); do
    if out=$(sponsor_once 2>&1); then echo "$out" | tail -n 3; return 0; fi
    reason=$(echo "$out" | grep -o '"error":"[^"]*"' | head -n 1 | cut -d'"' -f4)
    wait=$(echo "$out" | grep -o '"retryAfterSeconds":[0-9]*' | head -n 1 | cut -d: -f2)
    [ "${wait:-0}" -ge 180 ] || wait=180
    echo "$(date '+%H:%M') sponsor refused ($i/$tries): ${reason:-$(echo "$out" | tail -n 1 | cut -c1-160)}"
    [ "$i" -lt "$tries" ] || return 1
    echo "  next try in $((wait / 60)) min (Ctrl+C is safe; nothing is registered yet)"; sleep "$wait"
  done
}

sponsor_once() {
  docker run --rm -v "$D:/work" -e SPONSOR_URL="$SPONSOR_URL" -e EXPECTED_GENESIS="$GENESIS" \
    --entrypoint node "$(envget FLOP_CLI)" /work/sponsor.mjs
}

cmd_prereqs() {
  # Docker Engine (download.docker.com) and NVIDIA Container Toolkit (nvidia.github.io), each from its
  # official signed apt repository, following their install guides. No Docker Desktop needed.
  grep -q 'Ubuntu' /etc/os-release || die "this expects an Ubuntu distro (wsl --install Ubuntu-24.04 --name flop-miner)"
  [ -e /usr/lib/wsl/lib/libcuda.so.1 ] || [ -e /usr/lib/wsl/lib/libcuda.so ] \
    || die "no NVIDIA GPU driver visible from WSL: install the latest NVIDIA driver on Windows, then wsl --shutdown"
  step "Docker Engine (official apt repository)"
  sudo apt-get update -qq && sudo apt-get install -y -qq ca-certificates curl gnupg jq openssl >/dev/null
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  local codename; codename=$(sed -n 's/^UBUNTU_CODENAME=//p' /etc/os-release)
  [ -n "$codename" ] || codename=$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release)
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $codename stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  step "NVIDIA Container Toolkit (official apt repository)"
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | sudo gpg --batch --yes --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin nvidia-container-toolkit >/dev/null
  sudo nvidia-ctk runtime configure --runtime=docker >/dev/null
  sudo systemctl restart docker
  sudo usermod -aG docker "$USER"
  step "GPU inside Docker"
  sudo docker run --rm --gpus all ubuntu:24.04 nvidia-smi -L || die "Docker cannot see the GPU (see the guide's troubleshooting)"
  echo
  echo "prereqs done. In PowerShell: wsl --terminate flop-miner, reopen the distro, then: ./flop-miner.sh setup"
}

cmd_setup() {
  step "packages (Ubuntu official)"
  sudo apt-get update -qq && sudo apt-get install -y -qq jq openssl curl ca-certificates >/dev/null

  step "official release list: $RELEASES_URL"
  local cli_img worker_img backend_img policy_hash policy
  load_release
  worker_img=$REL_WORKER; backend_img=$REL_BACKEND; policy_hash=$REL_POLICY_HASH; policy=$REL_POLICY
  echo "  chain runtime: $(chain_spec)"
  cli_img=$(pick_cli "$REL_CLI") || die "no published CLI works with the chain right now (or the chain is unreachable); retry later"

  step "settings in $D"
  sudo install -d -o "$USER" -g "$USER" -m 700 "$D"
  install -d -m 700 "$D/models" "$D/session-keys"
  [ -f "$D/miner.env" ] || install -m 600 /dev/null "$D/miner.env"
  envset FLOP_CLI "$cli_img"
  envset FLOP_WORKER_IMAGE "$worker_img"
  envset FLOP_BACKEND_IMAGE "$backend_img"
  envset FLOP_RPC "$RPC"
  envset GHOST_MAILBOX_URL "$MAILBOX"
  { [ -n "$WORKER_NAME_ARG" ] || ! grep -q "^WORKER_NAME=" "$D/miner.env"; } && envset WORKER_NAME "$WORKER_NAME"
  envset MODEL_NAME "$MODEL_NAME"
  envset OPENROUTER_MODEL_SLUG "$MODEL_SLUG"
  envset MODEL_HASH "$MODEL_HASH"
  envset MODEL_PRECISION BF16
  envset TOPLOC_PRECISION bf16
  envset DECODE_POLICY_HASH "$policy_hash"
  envset DECODE_POLICY "'$policy'"
  { [ -n "$GPU_UTIL_ARG" ] || ! grep -q "^GPU_MEMORY_UTILIZATION=" "$D/miner.env"; } && envset GPU_MEMORY_UTILIZATION "$GPU_UTIL"
  grep -q '^TOPLOC_ENABLED=' "$D/miner.env" || envset TOPLOC_ENABLED 1
  grep -q '^INFERENCE_API_KEY=[0-9a-f]\{64\}$' "$D/miner.env" || envset INFERENCE_API_KEY "$(openssl rand -hex 32)"
  grep -q '^SESSION_AUTH_TOKEN=[0-9a-f]\{64\}$' "$D/miner.env" || envset SESSION_AUTH_TOKEN "$(openssl rand -hex 32)"
  grep -q '^SESSION_PUBLIC_HOST=' "$D/miner.env" || envset SESSION_PUBLIC_HOST ""
  chmod 600 "$D/miner.env"
  write_compose
  write_sponsor
  compose config -q || die "docker-compose.yml did not validate"

  step "images by digest from ghcr.io/flop-labs (backend is ~23 GB)"
  docker pull -q "$cli_img"
  compose pull -q

  step "miner key (new devnet-only account)"
  if ! sudo test -s "$D/signer"; then
    local tmp; tmp=$(mktemp "$D/.key.XXXXXX"); chmod 600 "$tmp"
    cli keys generate --type sr25519 --show-secret --json > "$tmp"
    (umask 077; jq -r .mnemonic "$tmp" > "$D/signer"; jq -r .address "$tmp" > "$D/address")
    shred -u "$tmp" 2>/dev/null || rm -f "$tmp"
    [ -s "$D/address" ] || die "key generation failed"
  fi
  sudo test -s "$D/session-keys/enclave.seed" || openssl rand -hex 32 | sudo tee "$D/session-keys/enclave.seed" >/dev/null
  # Flop's docs: the worker refuses a signer that is not root-owned with mode 0600.
  sudo chown root:root "$D/signer" "$D/session-keys/enclave.seed"
  sudo chmod 600 "$D/signer" "$D/session-keys/enclave.seed"
  echo "miner address: $(address)"

  step "stake sponsor (official faucet.flop.network)"
  if is_registered; then
    echo "already registered on chain: skipping the sponsor"
  else
    sponsor_until_ok "${SPONSOR_TRIES:-48}" || die "sponsor still refusing; run ./flop-miner.sh sponsor later, then ./flop-miner.sh setup"
  fi

  step "model (the CLI checks every file against the on-chain record)"
  local i mdir="$D/models/qwen2.5-0.5b-instruct"
  # The CLI writes a checkpoint only into an empty folder, so a second setup (e.g. after a new release)
  # would fail here. A model already on disk is re-verified against the chain by the worker's model gate
  # at every start ("model-gate OK" in the log). REFETCH_MODEL=1 moves the old copy aside and downloads again.
  if [ -n "$(ls -A "$mdir" 2>/dev/null)" ] && [ "${REFETCH_MODEL:-0}" != 1 ]; then
    echo "model already downloaded in $mdir; the worker's model gate re-verifies it at every start"
  else
  if [ -n "$(ls -A "$mdir" 2>/dev/null)" ]; then mv "$mdir" "$mdir.old.$(date +%s)"; echo "moved the old copy aside"; fi
  for i in 1 2 3; do
    if cli --network devnet --rpc "$RPC" model fetch "$MODEL_HASH" --precision BF16 \
         --output-dir /work/models/qwen2.5-0.5b-instruct --json \
         | jq -e --arg r "${MODEL_HASH#0x}" '(.ok == true) or (.verified_root == $r)' >/dev/null; then echo "model ok (verified root matches the chain)"; break; fi
    [ "$i" -lt 3 ] || die "model fetch failed 3 times"
    echo "model fetch failed; retrying"; sleep 10
  done
  fi

  step "tunnel (cloudflared from Cloudflare's signed apt repository)"
  if ! command -v cloudflared >/dev/null; then
    sudo install -d -m 0755 /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
    echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' \
      | sudo tee /etc/apt/sources.list.d/cloudflared.list >/dev/null
    sudo apt-get update -qq && sudo apt-get install -y -qq cloudflared >/dev/null
  fi
  sudo tee /etc/systemd/system/flop-tunnel.service >/dev/null <<'EOF'
[Unit]
Description=FLOP miner HTTPS tunnel (forwards only to the worker session port)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/cloudflared tunnel --no-autoupdate --url http://127.0.0.1:8645
Restart=always
RestartSec=5
DynamicUser=yes
StateDirectory=flop-tunnel
Environment=HOME=/var/lib/flop-tunnel
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
EOF
  sudo systemctl daemon-reload

  step "signer-fence guard (community tool, pinned commit, checked by sha256)"
  fence_install || echo "fence guard not installed (see above); setup continues. Retry: ./flop-miner.sh fence install"
  echo
  echo "setup done. Next: ./flop-miner.sh harden (then reopen the distro), then ./flop-miner.sh up"
}

# Is the worker's signer fenced? Asks the worker's own status endpoint from inside the container,
# so the session token never appears on the host. Prints yes, no or unknown.
fence_state() {
  compose exec -T worker node -e '
    fetch(`http://127.0.0.1:${process.env.SESSION_PORT||8645}/internal/signer-fence`,{headers:{Authorization:`Bearer ${process.env.SESSION_AUTH_TOKEN}`},signal:AbortSignal.timeout(10000)})
      .then(r=>r.json()).then(j=>console.log(j.fenced===true?"yes":"no")).catch(()=>console.log("unknown"))' 2>/dev/null || echo unknown
}

# Download the guard at the pinned commit into a temporary folder, check every file's sha256, and only
# then install it to $D/fence-guard (root-only) with a systemd timer that runs it every 2 minutes.
fence_install() {
  local base="https://raw.githubusercontent.com/UfukNode/flop-miner-setup/$FENCE_GUARD_COMMIT/fence-guard"
  local tmp sum f
  command -v flock >/dev/null || sudo apt-get install -y -qq util-linux >/dev/null
  tmp=$(mktemp -d)
  while read -r sum f; do
    curl -fsS --proto '=https' -o "$tmp/$f" "$base/$f" || { rm -rf "$tmp"; echo "download failed: $f"; return 1; }
    [ "$(sha256sum < "$tmp/$f" | cut -d' ' -f1)" = "$sum" ] || { rm -rf "$tmp"; echo "sha256 mismatch for $f: refusing to install"; return 1; }
  done <<<"$FENCE_GUARD_FILES"
  sudo install -d -m 700 -o root -g root "$D/fence-guard"
  while read -r sum f; do
    case "$f" in fence-guard.sh) sudo install -m 700 -o root -g root "$tmp/$f" "$D/fence-guard/$f" ;;
      *.service|*.timer) sudo install -m 644 -o root -g root "$tmp/$f" "/etc/systemd/system/$f" ;;
      *) sudo install -m 644 -o root -g root "$tmp/$f" "$D/fence-guard/$f" ;; esac   # same modes as the guard's own guide
  done <<<"$FENCE_GUARD_FILES"
  rm -rf "$tmp"
  sudo systemctl daemon-reload
  sudo systemctl enable --now flop-fence-guard.timer >/dev/null 2>&1
  echo "fence guard installed (commit ${FENCE_GUARD_COMMIT:0:7}, all 6 files match), timer: $(systemctl is-active flop-fence-guard.timer)"
}

cmd_fence() {
  case "${1:-}" in
    install) fence_install ;;
    "")
      echo "signer fenced: $(fence_state)"
      echo "guard timer:   $(systemctl is-active flop-fence-guard.timer 2>/dev/null || true)"
      sudo test -f "$D/fence-guard/guard.log" && sudo tail -n 5 "$D/fence-guard/guard.log" || true ;;
    *) echo "Use: ./flop-miner.sh fence            (status)"; echo "     ./flop-miner.sh fence install    (install or refresh the guard)" ;;
  esac
}

cmd_harden() {
  # Cut this distro off from Windows: no C:\ drive under /mnt, no launching .exe files, no Windows PATH.
  # The GPU keeps working (it comes through /usr/lib/wsl, not /mnt/c); the check below proves it.
  sudo tee /etc/wsl.conf >/dev/null <<'EOF'
[boot]
systemd=true

[automount]
enabled=false
mountFsTab=false

[interop]
enabled=false
appendWindowsPath=false
EOF
  echo "written /etc/wsl.conf. Now in PowerShell: wsl --terminate flop-miner, reopen the flop-miner terminal, then:"
  echo "  ls /mnt/c 2>&1 | head -1      # must fail or be empty"
  echo "  docker run --rm --gpus all nvidia/cuda:13.0.1-base-ubuntu22.04 nvidia-smi -L   # must list your GPU"
  echo "To undo: sudo rm /etc/wsl.conf, then terminate the distro again (Ubuntu 24.04 keeps systemd on by default)."
}

cmd_up() {
  address >/dev/null
  # Match the miner network's packet size to WSL's link (eth0) and refresh the compose file.
  envset NET_MTU "$(cat /sys/class/net/eth0/mtu 2>/dev/null || echo 1280)"
  grep -q '^SESSION_COMMIT_IDS=' "$D/miner.env" || envset SESSION_COMMIT_IDS 1
  write_compose
  compose config -q || die "docker-compose.yml did not validate"
  if docker network inspect flop-miner_default >/dev/null 2>&1 && \
     [ "$(docker network inspect flop-miner_default -f '{{index .Options "com.docker.network.driver.mtu"}}')" != "$(envget NET_MTU)" ]; then
    echo "recreating the miner network with MTU $(envget NET_MTU)"
    compose down
  fi
  step "tunnel"
  local since host i signer
  since=$(date '+%Y-%m-%d %H:%M:%S')
  sudo systemctl restart flop-tunnel
  for i in $(seq 1 30); do
    host=$(sudo journalctl -u flop-tunnel --since "$since" --no-pager | grep -o '[a-z0-9-]*\.trycloudflare\.com' | grep -v '^api\.' | tail -n 1 || true)
    [ -n "$host" ] && break; sleep 2
  done
  [ -n "$host" ] || die "no tunnel address after 60 s: sudo journalctl -u flop-tunnel -n 30"
  envset SESSION_PUBLIC_HOST "$host"
  echo "public address: https://$host (answers 401 without the session token)"

  step "backend (model on the GPU)"
  compose up -d backend
  for i in $(seq 1 120); do
    backend_ready && break
    if compose logs --since 15m backend 2>/dev/null | grep -qiE 'out of memory|less than desired GPU memory|Traceback'; then
      compose logs --tail 25 backend; die "backend failed to start (see above); try: GPU_UTIL=0.5 ./flop-miner.sh setup"
    fi
    sleep 5
  done
  backend_ready || die "backend not ready after 10 min: ./flop-miner.sh status"
  echo "backend ready"

  step "worker"
  compose up -d --force-recreate worker
  sleep 20
  compose logs --tail 40 worker | grep -E 'Signer:|model-gate|Session host|Endpoint ad|answered task|calibration|rror' || true
  signer=$(compose logs worker | grep -o 'Signer: [0-9A-Za-z]*' | tail -n 1 | cut -d' ' -f2)
  if [ -n "$signer" ] && [ "$signer" != "$(address)" ]; then
    compose stop worker; die "worker signed as $signer, not your miner $(address); stopped it"
  fi
  echo
  echo "mining. You can close this window: the miner keeps running until ./flop-miner.sh down (Stop shortcut)."
}

cmd_status() {
  local a; a=$(address)
  step "miner $a"
  local out err; err=$(mktemp)
  out=$(cli --network devnet --rpc "$RPC" miner status "$a" --json 2>"$err") || true
  if grep -q RUNTIME_INCOMPATIBLE "$err" <(echo "$out"); then
    echo "Flop upgraded the chain (runtime $(chain_spec)) and these images are too old for it."
    echo "Fix: ./flop-miner.sh update   (or double-click \"FLOP Miner - Update\")"
  else
    jq '{registered, stake, calibration}' <<<"$out" 2>/dev/null || tail -n 5 "$err"
  fi
  rm -f "$err"
  echo "explorer: https://explorer.devnet.flop.network/account/$a"
  echo "board:    https://flop-devnet-board.vercel.app"
  step "versions"
  echo "worker $(img_tag "$(envget FLOP_WORKER_IMAGE)") · backend $(img_tag "$(envget FLOP_BACKEND_IMAGE)") · cli $(img_tag "$(envget FLOP_CLI)") · chain runtime $(chain_spec) · script $VERSION"
  step "TOPLOC proof"; [ "$(envget TOPLOC_ENABLED)" = 0 ] && echo "OFF (plain V2 settlements)" || echo "ON"
  step "session commit ids"; [ "$(envget SESSION_COMMIT_IDS)" = 0 ] && echo "OFF" || echo "ON"
  step "tunnel"; echo "https://$(envget SESSION_PUBLIC_HOST)  ($(systemctl is-active flop-tunnel || true))"
  step "signer fence"; echo "fenced: $(fence_state)  (guard timer: $(systemctl is-active flop-fence-guard.timer 2>/dev/null || true))"
  step "containers"; compose ps --format 'table {{.Service}}\t{{.Status}}\t{{.Ports}}'
  step "GPU"; nvidia-smi --query-gpu=power.draw,memory.used,memory.total,utilization.gpu,temperature.gpu --format=csv
  step "worker (last test jobs / calibration)"; compose logs worker 2>/dev/null | grep -E 'answered task|calibration' | tail -n 5 || true
}

# Rewrite the compose file and restart only the worker, and only if the miner is already fully running:
# starting it from here would skip the tunnel (that is `up`'s job).
apply_worker_setting() {
  write_compose
  compose config -q || die "docker-compose.yml did not validate"
  if ! compose ps --status running --services 2>/dev/null | grep -qx worker \
     || ! systemctl is-active -q flop-tunnel; then
    echo "Saved. The miner is not fully running, so nothing was restarted: it applies at the next ./flop-miner.sh up (Start shortcut)."
    return
  fi
  compose up -d --no-deps --force-recreate worker
  sleep 25
  compose logs --since 1m worker | grep -E 'Signer:|TOPLOC lanes|Endpoint ad' || true
}

# TOPLOC proof on/off. Off = the worker's "TOPLOC lanes: disabled" mode. Note: backend v0.1.239 refuses
# requests without a TOPLOC binding ("toploc binding required"), so keep it ON with that backend.
cmd_toploc() {
  case "${1:-}" in
    on)  envset TOPLOC_ENABLED 1 ;;
    off) envset TOPLOC_ENABLED 0 ;;
    *)   echo "TOPLOC proof is $( [ "$(envget TOPLOC_ENABLED)" = 0 ] && echo OFF || echo ON ). Use: ./flop-miner.sh toploc on|off"; return ;;
  esac
  apply_worker_setting
}

# SESSION_COMMIT_IDS: official worker flag that lets the V2 settlement leaf carry the token-id commitment
# the TOPLOC binding needs. Flop Labs' CTO advised it on 8 Nov 2026 until the next release fixes it.
cmd_commitids() {
  case "${1:-}" in
    on)  envset SESSION_COMMIT_IDS 1 ;;
    off) envset SESSION_COMMIT_IDS 0 ;;
    *)   echo "SESSION_COMMIT_IDS is $( [ "$(envget SESSION_COMMIT_IDS)" = 0 ] && echo OFF || echo ON ). Use: ./flop-miner.sh commitids on|off"; return ;;
  esac
  apply_worker_setting
  compose exec -T worker printenv SESSION_COMMIT_IDS 2>/dev/null | sed 's/^/worker sees SESSION_COMMIT_IDS=/' || true
}

# After Flop upgrades the chain or publishes new images: refresh the images (never downgrades), pick a CLI
# the live chain accepts, pull, and restart the miner if it was running. Keeps every setting and the key.
cmd_update() {
  [ -f "$D/miner.env" ] || die "nothing to update yet: run ./flop-miner.sh setup first"
  address >/dev/null
  step "official release list: $RELEASES_URL"
  load_release
  local spec cli_img worker_img backend_img old_cli old_worker old_backend old_policy was_running=0 changed=0
  spec=$(chain_spec); echo "  chain runtime: ${spec:-unknown}"
  old_cli=$(envget FLOP_CLI); old_worker=$(envget FLOP_WORKER_IMAGE); old_backend=$(envget FLOP_BACKEND_IMAGE)
  old_policy=$(envget DECODE_POLICY_HASH)
  worker_img=$(newer_img "$REL_WORKER" "$old_worker"); backend_img=$(newer_img "$REL_BACKEND" "$old_backend")

  step "CLI for this chain"
  cli_img=$(pick_cli "$REL_CLI") || die "no published CLI works with the chain right now (or the chain is unreachable). Flop usually publishes one within hours: retry later"

  step "images by digest from ghcr.io/flop-labs"
  envset FLOP_CLI "$cli_img"
  envset FLOP_WORKER_IMAGE "$worker_img"
  envset FLOP_BACKEND_IMAGE "$backend_img"
  envset DECODE_POLICY_HASH "$REL_POLICY_HASH"
  envset DECODE_POLICY "'$REL_POLICY'"
  chmod 600 "$D/miner.env"
  write_compose
  compose config -q || die "docker-compose.yml did not validate"
  [ "$backend_img" != "$old_backend" ] && echo "  new backend image: about 23 GB to download, this takes a while"
  compose pull -q
  local name old new
  for name in cli worker backend; do
    case $name in cli) old=$old_cli new=$cli_img ;; worker) old=$old_worker new=$worker_img ;; backend) old=$old_backend new=$backend_img ;; esac
    if [ "$old" = "$new" ]; then echo "  $name $(img_tag "$new") (unchanged)"; else echo "  $name $(img_tag "$old") -> $(img_tag "$new")"; changed=1; fi
  done
  [ "$old_policy" = "$REL_POLICY_HASH" ] || { echo "  decode policy changed -> $REL_POLICY_HASH"; changed=1; }

  # The CLI is only used for checks, so a CLI-only change needs no restart.
  if [ "$worker_img" = "$old_worker" ] && [ "$backend_img" = "$old_backend" ] && [ "$old_policy" = "$REL_POLICY_HASH" ]; then
    echo; [ "$changed" = 1 ] && echo "updated (no restart needed)." || echo "already up to date."
    return
  fi
  compose ps --status running --services 2>/dev/null | grep -qx worker && was_running=1
  if [ "$was_running" = 0 ]; then
    echo; echo "updated. The miner is stopped: the new images run at the next ./flop-miner.sh up (Start shortcut)."; return
  fi
  step "restarting the miner on the new images"
  cmd_up
  sleep 30
  if compose logs --since 2m worker 2>/dev/null | grep -qiE 'RUNTIME_INCOMPATIBLE|Unsupported runtime spec'; then
    echo "warning: the worker still reports the chain runtime as unsupported. Flop has not published a worker for"
    echo "runtime ${spec:-?} yet; run ./flop-miner.sh update again later."
  fi
}

cmd_sponsor() { if is_registered; then echo "already registered; asking for a stake top-up"; fi; sponsor_until_ok "${SPONSOR_TRIES:-48}"; }
cmd_logs()    { compose logs -f --tail 50 worker; }
cmd_down() {
  compose stop worker backend || true
  sudo systemctl stop flop-tunnel || true
  echo "stopped. Start again with: ./flop-miner.sh up"
}

case "${1:-}" in
  prereqs) cmd_prereqs; exit ;;
  version) echo "flop-miner.sh $VERSION"; exit ;;
  setup|harden|up|status|logs|sponsor|toploc|commitids|fence|update|down) ;;
  *)       sed -n '2,36p' "$0"; exit 1 ;;
esac
need_docker
case "${1:-}" in
  setup)   cmd_setup ;;
  harden)  cmd_harden ;;
  up)      cmd_up ;;
  status)  cmd_status ;;
  logs)    cmd_logs ;;
  sponsor) cmd_sponsor ;;
  toploc)  shift; cmd_toploc "${1:-}" ;;
  commitids) shift; cmd_commitids "${1:-}" ;;
  fence)   shift; cmd_fence "${1:-}" ;;
  update)  cmd_update ;;
  down)    cmd_down ;;
  *)       sed -n '2,36p' "$0"; exit 1 ;;
esac
