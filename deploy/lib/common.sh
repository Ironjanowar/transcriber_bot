#!/usr/bin/env bash
# Shared helpers for the transcriptor_bot deployment scripts.
#
# This file is sourced by bootstrap.sh, deploy.sh, verify.sh and smoke-test.sh.
# It deliberately contains no secrets and never prints the contents of the
# private environment file.

# shellcheck shell=bash

# shellcheck disable=SC2034  # constants are consumed by the scripts that source this file
if [[ -n "${TRANSCRIPTOR_COMMON_SOURCED:-}" ]]; then
  return 0
fi
TRANSCRIPTOR_COMMON_SOURCED=1

APP_USER="${TRANSCRIPTOR_BOT_USER:-cuwano}"
APP_HOME="${TRANSCRIPTOR_BOT_HOME:-/home/${APP_USER}}"
APP_DIR="${TRANSCRIPTOR_BOT_APP_DIR:-${APP_HOME}/apps/transcriptor_bot}"
STATE_DIR="${TRANSCRIPTOR_BOT_STATE_DIR:-${APP_HOME}/.local/share/transcriptor_bot}"
CONFIG_DIR="${TRANSCRIPTOR_BOT_CONFIG_DIR:-${APP_HOME}/.config/transcriptor_bot}"
APP_ENV_FILE="${TRANSCRIPTOR_BOT_APP_ENV_FILE:-${CONFIG_DIR}/app.env}"
BOT_API_ENV_FILE="${TRANSCRIPTOR_BOT_API_ENV_FILE:-${CONFIG_DIR}/bot-api.env}"
LEGACY_ENV_FILE="${TRANSCRIPTOR_BOT_ENV_FILE:-${CONFIG_DIR}/env}"

MODEL_DIR="${STATE_DIR}/models"
MODEL_FILE="${MODEL_DIR}/ggml-large-v3.bin"
VAD_MODEL_FILE="${MODEL_DIR}/ggml-silero-v6.2.0.bin"
WORK_DIR="${STATE_DIR}/work"
STATE_TMP="${STATE_DIR}/tmp"
CACHE_DIR="${STATE_DIR}/cache"
CUDA_CACHE_DIR="${STATE_DIR}/cuda-cache"
DB_PATH="${STATE_DIR}/transcriptor_bot.db"
BOT_API_DIR="${STATE_DIR}/telegram-bot-api"
BOT_API_TMP_DIR="${BOT_API_DIR}/tmp"
BOT_API_BIN="${APP_HOME}/.local/bin/telegram-bot-api"
BOT_API_SRC="${APP_HOME}/.local/src/telegram-bot-api"
CARGO_HOME="${APP_HOME}/.local/share/cargo"
RUSTUP_HOME="${APP_HOME}/.local/share/rustup"

RUNTIME_DIR="${APP_DIR}/runtime"
APP_BIN="${RUNTIME_DIR}/bin/transcriber"
APP_TRANSCRIBER="${RUNTIME_DIR}/bin/transcribe-audio"
APP_LAUNCHER="${RUNTIME_DIR}/bin/start-transcriptor-bot"

RELEASE_NAME="${TRANSCRIPTOR_BOT_RELEASE_NAME:-transcriptor_bot}"
RELEASE_DIR="${APP_DIR}/_build/prod/rel/${RELEASE_NAME}"
RELEASE_BIN="${RELEASE_DIR}/bin/${RELEASE_NAME}"

BOT_API_HOST="${TRANSCRIPTOR_BOT_API_HOST:-127.0.0.1}"
BOT_API_PORT="${TRANSCRIPTOR_BOT_API_PORT:-8081}"
BOT_API_URL="http://${BOT_API_HOST}:${BOT_API_PORT}"

APP_SERVICE="transcriptor-bot.service"
BOT_API_SERVICE="telegram-bot-api.service"

OWNER_TELEGRAM_USER_ID="14977303"

# ggml-large-v3.bin, F16, from ggerganov/whisper.cpp.
MODEL_SIZE="3095033483"
MODEL_SHA256="64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2"
MODEL_URL="${TRANSCRIPTOR_BOT_MODEL_URL:-https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin}"

# Silero VAD v6.2.0 converted to GGML by the whisper.cpp project.
VAD_MODEL_SIZE="885098"
VAD_MODEL_SHA256="2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987"
VAD_MODEL_URL="${TRANSCRIPTOR_BOT_VAD_MODEL_URL:-https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin}"

# Pinned Telegram Bot API server source. There are no upstream release tags;
# override with TELEGRAM_BOT_API_REF if a newer revision is required.
TELEGRAM_BOT_API_REF="${TELEGRAM_BOT_API_REF:-7232881b39dfcd048a0d569f1983c5184249ee05}"
TELEGRAM_BOT_API_URL="https://github.com/tdlib/telegram-bot-api.git"

log() {
  printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2
}

warn() {
  printf '[%s] WARN: %s\n' "$(date '+%H:%M:%S')" "$*" >&2
}

die() {
  printf '[%s] ERROR: %s\n' "$(date '+%H:%M:%S')" "$*" >&2
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    have "$cmd" || die "Falta el comando requerido: ${cmd}"
  done
}

assert_not_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    die "No ejecutes este script como root. Usa la cuenta ${APP_USER}; bootstrap.sh pedirá sudo cuando lo necesite."
  fi
}

assert_runtime_user() {
  local current
  current="$(id -un)"
  if [[ "${TRANSCRIPTOR_BOT_ALLOW_ANY_USER:-0}" != "1" && "$current" != "$APP_USER" ]]; then
    die "Ejecuta este script como ${APP_USER} (usuario actual: ${current})."
  fi
}

ensure_base_dirs() {
  install -d -m 0755 "${APP_HOME}/apps"
  install -d -m 0755 "$APP_DIR"
  install -d -m 0755 "$RUNTIME_DIR" "$RUNTIME_DIR/bin"
  install -d -m 0700 "$STATE_DIR" "$WORK_DIR" "$STATE_TMP" "$CACHE_DIR" \
    "$CUDA_CACHE_DIR" "$MODEL_DIR" "$BOT_API_DIR" "$BOT_API_TMP_DIR"
  install -d -m 0700 "$CONFIG_DIR"
  if [[ ! -e "$DB_PATH" ]]; then
    install -m 0600 /dev/null "$DB_PATH"
  fi
  chmod 0600 "$DB_PATH"
}

is_valid_bot_token() {
  [[ "${1:-}" =~ ^[0-9]{6,12}:[A-Za-z0-9_-]{20,}$ ]]
}

is_valid_api_id() {
  [[ "${1:-}" =~ ^[0-9]{1,12}$ ]]
}

is_valid_api_hash() {
  [[ "${1:-}" =~ ^[0-9a-fA-F]{32}$ ]]
}

is_valid_git_commit() {
  [[ "${1:-}" =~ ^[0-9a-fA-F]{40}$ ]]
}

env_file_get() {
  local key="$1" file="$2" line k v
  [[ -r "$file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" == *=* ]] || continue
    k="${line%%=*}"
    v="${line#*=}"
    if [[ "$k" == "$key" ]]; then
      printf '%s' "$v"
      return 0
    fi
  done < "$file"
  return 1
}

# Parse KEY=value files without evaluating shell code. Never use `source` on
# the environment file: a command substitution in a compromised file would be
# executed by the deploy user.
load_env_file() {
  local file="${1:-$APP_ENV_FILE}" line key value lineno=0
  [[ -r "$file" ]] || die "No se puede leer el archivo de entorno: ${file}"
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" == *=* ]] || die "Línea ${lineno} inválida en ${file}: se esperaba KEY=value"
    key="${line%%=*}"
    value="${line#*=}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "Clave inválida en ${file}:${lineno}"
    export "${key}=${value}"
  done < "$file"
}

check_env_permissions() {
  local file="${1:-$APP_ENV_FILE}" mode owner
  [[ -f "$file" ]] || die "No existe el archivo de secretos: ${file}. Ejecuta bootstrap.sh o deploy.sh --configure."
  owner="$(stat -c '%u' "$file")"
  [[ "$owner" == "$(id -u)" ]] || die "${file} no pertenece al usuario actual."
  mode="$(stat -c '%a' "$file")"
  if [[ "$mode" != "600" ]]; then
    warn "${file} tenía modo ${mode}; se corrige a 0600."
    chmod 600 "$file"
  fi
}

write_env_files() {
  local app_tmp bot_api_tmp
  install -d -m 0700 "$CONFIG_DIR"
  umask 077
  app_tmp="$(mktemp "${CONFIG_DIR}/.app.env.XXXXXX")"
  {
    printf '# Entorno exclusivo de transcriptor_bot. Modo 0600.\n'
    printf 'BOT_TOKEN=%s\n' "${BOT_TOKEN}"
    printf 'OWNER_TELEGRAM_USER_ID=%s\n' "${OWNER_TELEGRAM_USER_ID}"
    printf 'DATABASE_PATH=%s\n' "${DB_PATH}"
    printf 'TRANSCRIBER_COMMAND=%s\n' "${APP_TRANSCRIBER}"
    printf 'WORK_DIR=%s\n' "${WORK_DIR}"
    printf 'TELEGRAM_API_BASE_URL=%s\n' "${BOT_API_URL}"
    printf '# Alias de compatibilidad para la configuración de ExGram.\n'
    printf 'TELEGRAM_BOT_API_URL=%s\n' "${BOT_API_URL}"
    printf 'MODEL_PATH=%s\n' "${MODEL_FILE}"
  } > "$app_tmp"

  bot_api_tmp="$(mktemp "${CONFIG_DIR}/.bot-api.env.XXXXXX")"
  {
    printf '# Credenciales exclusivas del servidor Telegram Bot API. Modo 0600.\n'
    # These are the environment variable names supported by telegram-bot-api.
    printf 'TELEGRAM_API_ID=%s\n' "${TELEGRAM_API_ID}"
    printf 'TELEGRAM_API_HASH=%s\n' "${TELEGRAM_API_HASH}"
  } > "$bot_api_tmp"

  chmod 600 "$app_tmp" "$bot_api_tmp"
  mv -f "$app_tmp" "$APP_ENV_FILE"
  mv -f "$bot_api_tmp" "$BOT_API_ENV_FILE"
  chmod 600 "$APP_ENV_FILE" "$BOT_API_ENV_FILE"
  if [[ "$LEGACY_ENV_FILE" != "$APP_ENV_FILE" && "$LEGACY_ENV_FILE" != "$BOT_API_ENV_FILE" ]]; then
    rm -f "$LEGACY_ENV_FILE"
  fi
  log "Archivos de entorno actualizados: ${APP_ENV_FILE}, ${BOT_API_ENV_FILE} (0600)"
}

prompt_secret() {
  local var="$1" label="$2" validator="$3" current="${4:-}" value=""
  if [[ -n "${!var:-}" ]]; then
    value="${!var}"
  else
    [[ -t 0 ]] || die "${var} no está definido y no hay terminal interactiva. Exporta ${var} o ejecuta el script en una terminal."
    if [[ -n "$current" ]]; then
      printf '%s [Enter para conservar]: ' "$label" >&2
    else
      printf '%s: ' "$label" >&2
    fi
    read -r -s value
    printf '\n' >&2
    if [[ -z "$value" && -n "$current" ]]; then
      value="$current"
    fi
  fi
  "$validator" "$value" || die "${var} no tiene un formato válido."
  printf -v "$var" '%s' "$value"
}

ensure_env_file() {
  local force="${1:-0}" current_token="" current_id="" current_hash=""
  local existing_app="$APP_ENV_FILE" existing_bot="$BOT_API_ENV_FILE"
  if [[ ! -f "$existing_app" && -f "$LEGACY_ENV_FILE" ]]; then
    existing_app="$LEGACY_ENV_FILE"
  fi
  if [[ ! -f "$existing_bot" && -f "$LEGACY_ENV_FILE" ]]; then
    existing_bot="$LEGACY_ENV_FILE"
  fi
  if [[ "$force" != "1" && -f "$existing_app" && -f "$existing_bot" ]]; then
    check_env_permissions "$existing_app"
    check_env_permissions "$existing_bot"
    local token id hash
    token="$(env_file_get BOT_TOKEN "$existing_app" || true)"
    id="$(env_file_get TELEGRAM_API_ID "$existing_bot" || true)"
    hash="$(env_file_get TELEGRAM_API_HASH "$existing_bot" || true)"
    if is_valid_bot_token "$token" && is_valid_api_id "$id" && is_valid_api_hash "$hash"; then
      log "Usando secretos existentes en ${existing_app} y ${existing_bot}"
      BOT_TOKEN="$token"
      TELEGRAM_API_ID="$id"
      TELEGRAM_API_HASH="$hash"
      # Rewrite split files, also migrating the former combined env file.
      write_env_files
      return 0
    fi
    warn "Los archivos de entorno existen pero les faltan secretos válidos; se pedirán de nuevo."
    current_token="$token"
    current_id="$id"
    current_hash="$hash"
  fi

  log "Configurando secretos en ${CONFIG_DIR}"
  prompt_secret BOT_TOKEN "BOT_TOKEN (BotFather, oculto)" is_valid_bot_token "$current_token"
  prompt_secret TELEGRAM_API_ID "TELEGRAM_API_ID (my.telegram.org)" is_valid_api_id "$current_id"
  prompt_secret TELEGRAM_API_HASH "TELEGRAM_API_HASH (oculto)" is_valid_api_hash "$current_hash"
  write_env_files
}

bot_api_get() {
  local method="$1"
  [[ -n "${BOT_TOKEN:-}" ]] || die "BOT_TOKEN no está cargado."
  # Put the URL in a curl config read from stdin so the bot token never
  # appears in the process list.
  printf 'url = "%s/bot%s/%s"\nsilent\nshow-error\nfail\n' \
    "$BOT_API_URL" "$BOT_TOKEN" "$method" | curl --config -
}

wait_for_bot_api() {
  local attempts="${1:-30}" i
  for ((i = 1; i <= attempts; i++)); do
    if bot_api_get getMe >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_unit_active() {
  local unit="$1" attempts="${2:-30}" i
  for ((i = 1; i <= attempts; i++)); do
    if systemctl --user is-active --quiet "$unit"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

resolve_nvcc() {
  local candidate
  NVCC=""
  CUDA_HOME="${CUDA_HOME:-${CUDA_PATH:-}}"
  if [[ -n "$CUDA_HOME" && -x "${CUDA_HOME}/bin/nvcc" ]]; then
    NVCC="${CUDA_HOME}/bin/nvcc"
  else
    for candidate in "$(command -v nvcc 2>/dev/null || true)" \
      /usr/local/cuda/bin/nvcc /opt/cuda/bin/nvcc /usr/lib/cuda/bin/nvcc; do
      if [[ -n "$candidate" && -x "$candidate" ]]; then
        NVCC="$candidate"
        break
      fi
    done
  fi
  if [[ -n "$NVCC" ]]; then
    CUDA_HOME="$(cd "$(dirname "$NVCC")/.." && pwd -P)"
    export CUDA_HOME
    export CUDA_PATH="$CUDA_HOME"
    export CUDACXX="$NVCC"
    export PATH="${CUDA_HOME}/bin:${PATH}"
    return 0
  fi
  return 1
}

ensure_cargo_path() {
  if [[ -x "${CARGO_HOME}/bin/cargo" ]]; then
    export CARGO_HOME RUSTUP_HOME
    export PATH="${CARGO_HOME}/bin:${PATH}"
  elif [[ -x "${APP_HOME}/.cargo/bin/cargo" ]]; then
    export PATH="${APP_HOME}/.cargo/bin:${PATH}"
  fi
}

mise_bin() {
  if [[ -x "${APP_HOME}/.local/bin/mise" ]]; then
    printf '%s\n' "${APP_HOME}/.local/bin/mise"
    return 0
  fi
  if have mise; then
    command -v mise
    return 0
  fi
  return 1
}

elixir_app_name() {
  local mix_file="$1"
  sed -n 's/.*app:[[:space:]]*:\([A-Za-z0-9_]*\).*/\1/p' "$mix_file" | head -n 1
}

cargo_bin_name() {
  local dir="$1" names="" preferred
  if have jq && have cargo; then
    names="$(cd "$dir" && cargo metadata --no-deps --format-version 1 2>/dev/null \
      | jq -r '.packages[0].targets[] | select(.kind | index("bin")) | .name' 2>/dev/null || true)"
  fi
  if [[ -z "$names" ]]; then
    names="$(sed -n 's/^[[:space:]]*name[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$dir/Cargo.toml" | head -n 1)"
  fi
  [[ -n "$names" ]] || return 1
  preferred="$(printf '%s\n' "$names" | grep -E '^(transcriber|transcriptor.*)$' | head -n 1 || true)"
  printf '%s\n' "${preferred:-$(printf '%s\n' "$names" | head -n 1)}"
}

cargo_has_feature() {
  local dir="$1" feature="$2"
  if have jq && have cargo; then
    if (cd "$dir" && cargo metadata --no-deps --format-version 1 2>/dev/null \
      | jq -e --arg f "$feature" '.packages[0].features | has($f)' >/dev/null 2>&1); then
      return 0
    fi
  fi
  grep -qE "^[[:space:]]*${feature}[[:space:]]*=" "${dir}/Cargo.toml" 2>/dev/null
}

record_revision() {
  local repo="$1" rev dirty
  [[ -d "$STATE_DIR" ]] || return 0
  if git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
    rev="$(git -C "$repo" rev-parse HEAD)"
    dirty=""
    if [[ -n "$(git -C "$repo" status --porcelain 2>/dev/null)" ]]; then
      dirty="-dirty"
    fi
    printf '%s%s\n' "$rev" "$dirty" > "${STATE_DIR}/deployed-revision"
  fi
}

disk_available_kb() {
  local path="$1"
  df -Pk "$path" | awk 'NR == 2 { print $4 }'
}

sha256_of() {
  sha256sum "$1" | awk '{ print $1 }'
}

verify_model_file() {
  verify_pinned_file "${1:-$MODEL_FILE}" "$MODEL_SIZE" "$MODEL_SHA256"
}

verify_vad_model_file() {
  verify_pinned_file "${1:-$VAD_MODEL_FILE}" "$VAD_MODEL_SIZE" "$VAD_MODEL_SHA256"
}

verify_pinned_file() {
  local file="$1" expected_size="$2" expected_sha="$3" size
  [[ -f "$file" ]] || return 1
  size="$(stat -c '%s' "$file")"
  [[ "$size" == "$expected_size" ]] || return 1
  [[ "$(sha256_of "$file")" == "$expected_sha" ]] || return 1
}

verify_cuda_linkage() {
  local binary="${1:-$APP_BIN}" linked
  [[ -x "$binary" ]] || return 1
  have ldd || return 1
  linked="$(ldd "$binary" 2>/dev/null || true)"
  grep -Eq 'libcudart\.so|libcuda\.so' <<<"$linked" \
    && grep -Eq 'libcublas\.so' <<<"$linked"
}

verify_bot_api_binary() {
  local binary="${1:-$BOT_API_BIN}" help
  [[ -x "$binary" ]] || return 1
  help="$("$binary" --help 2>&1 || true)"
  grep -q -- '--local' <<<"$help" \
    && grep -q -- '--http-ip-address' <<<"$help" \
    && grep -q -- '--http-port' <<<"$help"
}
