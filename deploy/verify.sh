#!/usr/bin/env bash
#
# Read-only verification of an installed transcriptor_bot deployment.
#
#   ./deploy/verify.sh
#   ./deploy/verify.sh --checksum   # also hash the 3.1 GB model
#
# This script never prints BOT_TOKEN or TELEGRAM_API_HASH.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

CHECKSUM=0
QUIET=0
FAILURES=0

usage() {
  cat <<'EOF'
Uso: ./deploy/verify.sh [opciones]

Comprueba unidades, lingering, permisos, modelo, GPU, ffmpeg, Bot API local,
binding de loopback y la base SQLite.

Opciones:
  --checksum   Verificar también el SHA-256 completo del modelo (lento).
  --quiet      Mostrar solo fallos y el resumen.
  -h, --help   Mostrar esta ayuda.
EOF
}

ok() {
  [[ "$QUIET" == "1" ]] || printf 'OK    %s\n' "$*"
}

fail() {
  FAILURES=$((FAILURES + 1))
  printf 'FALLO %s\n' "$*" >&2
}

warn_check() {
  printf 'AVISO %s\n' "$*" >&2
}

check_unit() {
  local unit="$1" enabled active
  enabled="$(systemctl --user is-enabled "$unit" 2>/dev/null || true)"
  active="$(systemctl --user is-active "$unit" 2>/dev/null || true)"
  if [[ "$enabled" == "enabled" ]]; then
    ok "${unit} habilitada"
  else
    fail "${unit} no está habilitada (estado: ${enabled:-desconocido})"
  fi
  if [[ "$active" == "active" ]]; then
    ok "${unit} activa"
  else
    fail "${unit} no está activa (estado: ${active:-desconocido})"
  fi
}

check_file_mode() {
  local path="$1" expected="$2" label="$3" mode
  if [[ ! -e "$path" ]]; then
    fail "${label} no existe: ${path}"
    return
  fi
  mode="$(stat -Lc '%a' "$path")"
  if [[ "$mode" == "$expected" ]]; then
    ok "${label} modo ${mode}"
  else
    fail "${label} tiene modo ${mode}; se esperaba ${expected} (${path})"
  fi
}

check_bot_api() {
  local me webhook url id username
  if ! me="$(bot_api_get getMe 2>/dev/null)"; then
    fail "Bot API local no responde a getMe en ${BOT_API_URL}"
    return
  fi
  if have jq; then
    id="$(jq -r '.result.id // empty' <<<"$me" 2>/dev/null || true)"
    username="$(jq -r '.result.username // empty' <<<"$me" 2>/dev/null || true)"
    if [[ -n "$id" ]]; then
      ok "Bot API getMe: id=${id} username=${username:-sin_username}"
    else
      fail "getMe no devolvió un bot válido"
    fi
  else
    ok "Bot API getMe responde"
  fi

  if ! webhook="$(bot_api_get getWebhookInfo 2>/dev/null)"; then
    warn_check "No se pudo consultar getWebhookInfo"
    return
  fi
  if have jq; then
    url="$(jq -r '.result.url // empty' <<<"$webhook" 2>/dev/null || true)"
    if [[ -z "$url" ]]; then
      ok "sin webhook registrado (long polling)"
    else
      fail "hay un webhook registrado (${url}); usa ./deploy/smoke-test.sh --delete-webhook"
    fi
  fi
}

check_port() {
  local bindings bad
  if ! have ss; then
    warn_check "ss no está instalado; no se pudo comprobar el binding del Bot API"
    return
  fi
  bindings="$(ss -ltnH 2>/dev/null | awk -v p=":${BOT_API_PORT}" '$4 ~ p"$" { print $4 }')"
  if [[ -z "$bindings" ]]; then
    fail "No hay ningún socket escuchando en el puerto ${BOT_API_PORT}"
    return
  fi
  bad="$(printf '%s\n' "$bindings" | grep -Ev '^(127\.0\.0\.1|\[::1\]):'"${BOT_API_PORT}"'$' || true)"
  if [[ -n "$bad" ]]; then
    fail "Bot API escucha fuera de loopback: ${bad//$'\n'/ }"
  else
    ok "Bot API escucha solo en loopback (${bindings//$'\n'/, })"
  fi
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --checksum) CHECKSUM=1 ;;
      --quiet) QUIET=1 ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; die "Opción desconocida: $1" ;;
    esac
    shift
  done

  assert_runtime_user
  require_cmd systemctl stat curl

  log "Verificando despliegue de transcriptor_bot"

  check_unit "$BOT_API_SERVICE"
  check_unit "$APP_SERVICE"

  if have loginctl; then
    linger="$(loginctl show-user "$APP_USER" -p Linger 2>/dev/null | cut -d= -f2 || true)"
    if [[ "$linger" == "yes" ]]; then
      ok "lingering habilitado"
    else
      fail "lingering deshabilitado; los servicios no arrancarán al reiniciar sin login"
    fi
  else
    warn_check "loginctl no disponible; no se pudo comprobar lingering"
  fi

  check_file_mode "$CONFIG_DIR" 700 "directorio de configuración"
  check_file_mode "$APP_ENV_FILE" 600 "entorno privado de la aplicación"
  check_file_mode "$BOT_API_ENV_FILE" 600 "entorno privado del Bot API"
  check_file_mode "$STATE_DIR" 700 "directorio de estado"
  check_file_mode "$DB_PATH" 600 "base SQLite"

  if [[ -r "$APP_ENV_FILE" ]]; then
    load_env_file "$APP_ENV_FILE"
    if is_valid_bot_token "${BOT_TOKEN:-}"; then ok "BOT_TOKEN con formato válido"; else fail "BOT_TOKEN inválido"; fi
    if [[ "${OWNER_TELEGRAM_USER_ID:-}" == "$OWNER_TELEGRAM_USER_ID" ]]; then
      ok "owner fijado en ${OWNER_TELEGRAM_USER_ID}"
    else
      fail "OWNER_TELEGRAM_USER_ID no es ${OWNER_TELEGRAM_USER_ID}"
    fi
  else
    fail "No se puede leer ${APP_ENV_FILE}"
  fi
  if [[ -r "$BOT_API_ENV_FILE" ]]; then
    if is_valid_api_id "$(env_file_get TELEGRAM_API_ID "$BOT_API_ENV_FILE" || true)"; then ok "TELEGRAM_API_ID con formato válido"; else fail "TELEGRAM_API_ID inválido"; fi
    if is_valid_api_hash "$(env_file_get TELEGRAM_API_HASH "$BOT_API_ENV_FILE" || true)"; then ok "TELEGRAM_API_HASH con formato válido"; else fail "TELEGRAM_API_HASH inválido"; fi
  else
    fail "No se puede leer ${BOT_API_ENV_FILE}"
  fi

  check_file_mode "$BOT_API_BIN" 755 "binario Telegram Bot API"
  check_file_mode "$APP_BIN" 755 "CLI Rust"
  check_file_mode "$APP_TRANSCRIBER" 755 "wrapper del transcriptor"
  check_file_mode "$APP_LAUNCHER" 755 "lanzador de la release"
  if verify_bot_api_binary "$BOT_API_BIN"; then
    ok "Bot API soporta las flags requeridas"
  else
    fail "Bot API no soporta --local/--http-ip-address/--http-port"
  fi
  if [[ "$(cat "${STATE_DIR}/telegram-bot-api-revision" 2>/dev/null || true)" == "$TELEGRAM_BOT_API_REF" ]]; then
    ok "Bot API corresponde al commit fijado"
  else
    fail "No se puede demostrar el commit fijado del Bot API"
  fi
  if verify_cuda_linkage "$APP_BIN"; then
    ok "CLI Rust enlazado con CUDA/cuBLAS"
  else
    fail "CLI Rust sin enlace CUDA/cuBLAS verificable"
  fi

  if [[ -x "$RELEASE_BIN" ]]; then
    ok "release presente: ${RELEASE_BIN}"
  else
    fail "release ausente: ${RELEASE_BIN}"
  fi

  if [[ -f "$MODEL_FILE" ]]; then
    size="$(stat -c '%s' "$MODEL_FILE")"
    if [[ "$size" == "$MODEL_SIZE" ]]; then
      ok "modelo con tamaño esperado ($(( size / 1024 / 1024 )) MiB)"
    else
      fail "modelo con tamaño ${size}; se esperaba ${MODEL_SIZE}"
    fi
    if [[ "$CHECKSUM" == "1" ]]; then
      log "Calculando SHA-256 del modelo (puede tardar)"
      if verify_model_file "$MODEL_FILE"; then
        ok "modelo con SHA-256 correcto"
      else
        fail "modelo con SHA-256 incorrecto"
      fi
    fi
  else
    fail "modelo ausente: ${MODEL_FILE}"
  fi

  if verify_vad_model_file "$VAD_MODEL_FILE"; then
    ok "modelo Silero VAD v6.2.0 con tamaño y SHA-256 correctos"
  else
    fail "modelo VAD ausente o inválido: ${VAD_MODEL_FILE}"
  fi

  if have ffmpeg; then
    ok "ffmpeg: $(ffmpeg -version 2>/dev/null | head -n 1)"
  else
    fail "ffmpeg no está instalado"
  fi

  if have nvidia-smi; then
    if gpu="$(nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>/dev/null)"; then
      ok "GPU: ${gpu//$'\n'/ | }"
    else
      fail "nvidia-smi no puede comunicarse con el driver/GPU"
    fi
  else
    fail "nvidia-smi no está instalado"
  fi

  if [[ -n "${BOT_TOKEN:-}" ]]; then
    check_bot_api
    check_port
  fi

  if have sqlite3 && [[ -f "$DB_PATH" ]]; then
    integrity="$(sqlite3 "$DB_PATH" 'PRAGMA integrity_check;' 2>/dev/null || true)"
    if [[ "$integrity" == "ok" ]]; then
      ok "SQLite integrity_check: ok"
    else
      fail "SQLite integrity_check: ${integrity:-sin respuesta}"
    fi
    tables="$(sqlite3 "$DB_PATH" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';" 2>/dev/null || echo 0)"
    if [[ "$tables" -gt 0 ]]; then
      ok "SQLite con ${tables} tablas de aplicación"
    else
      fail "SQLite sin tablas de aplicación (¿arrancó TranscriptorBot.Store?)"
    fi
  elif [[ -f "$DB_PATH" ]]; then
    warn_check "sqlite3 no está instalado; no se pudo comprobar la base"
  else
    fail "base SQLite ausente: ${DB_PATH}"
  fi

  if [[ -f "${STATE_DIR}/deployed-revision" ]]; then
    ok "revisión desplegada: $(cat "${STATE_DIR}/deployed-revision")"
  fi

  if have journalctl; then
    warnings="$(journalctl --user -u "$APP_SERVICE" -p warning -n 20 --no-pager 2>/dev/null || true)"
    if [[ -n "$warnings" ]]; then
      warn_check "últimos avisos de ${APP_SERVICE}:"
      printf '%s\n' "$warnings" >&2
    fi
  fi

  if [[ "$FAILURES" -gt 0 ]]; then
    printf '\n%d comprobación(es) fallaron.\n' "$FAILURES" >&2
    exit 1
  fi
  printf '\nTodas las comprobaciones pasaron.\n'
}

main "$@"
