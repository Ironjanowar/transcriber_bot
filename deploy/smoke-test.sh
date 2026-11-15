#!/usr/bin/env bash
#
# Functional smoke test for an installed transcriptor_bot deployment.
#
#   ./deploy/smoke-test.sh
#   ./deploy/smoke-test.sh --delete-webhook
#
# This deliberately does not call getUpdates: consuming updates here would
# steal them from the running bot and produce a false "conflict" in its log.
# The final end-to-end step is a real voice note from Telegram; exact steps are
# printed at the end.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

DELETE_WEBHOOK=0
FAILURES=0

usage() {
  cat <<'EOF'
Uso: ./deploy/smoke-test.sh [opciones]

Comprueba servicios, Bot API local, long polling, GPU, modelo y SQLite.
No consume updates de Telegram.

Opciones:
  --delete-webhook  Eliminar un webhook registrado (necesario para long polling).
  -h, --help        Mostrar esta ayuda.
EOF
}

ok() {
  printf 'OK    %s\n' "$*"
}

fail() {
  FAILURES=$((FAILURES + 1))
  printf 'FALLO %s\n' "$*" >&2
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --delete-webhook) DELETE_WEBHOOK=1 ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; die "Opción desconocida: $1" ;;
    esac
    shift
  done

  assert_runtime_user
  require_cmd systemctl curl stat
  [[ -r "$APP_ENV_FILE" ]] || die "Falta ${APP_ENV_FILE}; ejecuta bootstrap.sh."
  load_env_file "$APP_ENV_FILE"
  is_valid_bot_token "${BOT_TOKEN:-}" || die "BOT_TOKEN inválido."

  log "Smoke test de transcriptor_bot"

  for unit in "$BOT_API_SERVICE" "$APP_SERVICE"; do
    if systemctl --user is-active --quiet "$unit"; then
      ok "${unit} activa"
    else
      fail "${unit} no está activa"
      journalctl --user -u "$unit" -n 30 --no-pager >&2 || true
    fi
  done

  if me="$(bot_api_get getMe 2>/dev/null)"; then
    if have jq; then
      ok "Bot API getMe: $(jq -r '.result.username // .result.first_name // "bot"' <<<"$me") (id $(jq -r '.result.id // "?"' <<<"$me"))"
    else
      ok "Bot API getMe responde"
    fi
  else
    fail "Bot API local no responde en ${BOT_API_URL}"
  fi

  if webhook="$(bot_api_get getWebhookInfo 2>/dev/null)"; then
    url=""
    if have jq; then
      url="$(jq -r '.result.url // empty' <<<"$webhook")"
      pending="$(jq -r '.result.pending_update_count // 0' <<<"$webhook")"
    fi
    if [[ -n "$url" ]]; then
      if [[ "$DELETE_WEBHOOK" == "1" ]]; then
        if bot_api_get deleteWebhook >/dev/null 2>&1; then
          ok "webhook eliminado; queda long polling"
        else
          fail "no se pudo eliminar el webhook"
        fi
      else
        fail "hay un webhook registrado (${url}); ejecuta ./deploy/smoke-test.sh --delete-webhook"
      fi
    else
      ok "sin webhook; long polling"
    fi
    if [[ "${pending:-0}" -gt 0 ]]; then
      ok "${pending} update(s) pendientes en la cola de Telegram"
    fi
  else
    fail "getWebhookInfo no responde"
  fi

  if have ss; then
    bindings="$(ss -ltnH 2>/dev/null | awk -v p=":${BOT_API_PORT}" '$4 ~ p"$" { print $4 }')"
    if [[ -z "$bindings" ]]; then
      fail "nada escucha en ${BOT_API_PORT}"
    elif printf '%s\n' "$bindings" | grep -Eqv '^(127\.0\.0\.1|\[::1\]):'"${BOT_API_PORT}"'$'; then
      fail "el Bot API escucha fuera de loopback: ${bindings//$'\n'/ }"
    else
      ok "Bot API solo en loopback (${bindings//$'\n'/, })"
    fi
  fi

  if [[ -f "$MODEL_FILE" ]] && [[ "$(stat -c '%s' "$MODEL_FILE")" == "$MODEL_SIZE" ]]; then
    ok "modelo large-v3 F16 presente ($(( MODEL_SIZE / 1024 / 1024 )) MiB)"
  else
    fail "modelo ausente o incompleto: ${MODEL_FILE}"
  fi

  if verify_vad_model_file "$VAD_MODEL_FILE"; then
    ok "modelo Silero VAD v6.2.0 presente y verificado"
  else
    fail "modelo VAD ausente o inválido: ${VAD_MODEL_FILE}"
  fi

  if gpu="$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null)"; then
    ok "GPU: ${gpu//$'\n'/ | }"
  else
    fail "nvidia-smi no responde"
  fi

  if have sqlite3 && [[ -f "$DB_PATH" ]]; then
    if [[ "$(sqlite3 "$DB_PATH" 'PRAGMA integrity_check;' 2>/dev/null)" == "ok" ]]; then
      ok "SQLite íntegra"
    else
      fail "SQLite no pasa integrity_check"
    fi
    pending_jobs="$(sqlite3 "$DB_PATH" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='jobs';" 2>/dev/null || echo 0)"
    if [[ "${pending_jobs:-0}" -gt 0 ]]; then
      ok "tabla jobs presente"
    else
      warn "no se encontró la tabla jobs; el esquema puede usar otro nombre"
    fi
  else
    fail "no se pudo comprobar SQLite (falta sqlite3 o ${DB_PATH})"
  fi

  restarts="$(systemctl --user show -p NRestarts --value "$APP_SERVICE" 2>/dev/null || echo 0)"
  if [[ "${restarts:-0}" -gt 5 ]]; then
    warn "${APP_SERVICE} acumula ${restarts} reinicios; revisa journalctl"
  else
    ok "${APP_SERVICE} sin bucle de reinicios (${restarts:-0})"
  fi

  cat <<EOF

Smoke test automático terminado. Prueba real de extremo a extremo:
  1. Añade el bot a un grupo y ejecuta /allow y /enable (solo el owner puede
     añadir administradores; el owner fijado es ${OWNER_TELEGRAM_USER_ID}).
  2. Envía una nota de voz o un audio al grupo.
  3. Observa el proceso:
       journalctl --user -u ${APP_SERVICE} -f
  4. Comprueba que llega la transcripción y que SQLite no conserva el audio:
       sqlite3 ${DB_PATH} '.tables'
       find ${WORK_DIR} -type f -maxdepth 1
EOF

  [[ "$FAILURES" -eq 0 ]] || { printf '\n%d comprobación(es) fallaron.\n' "$FAILURES" >&2; exit 1; }
}

main "$@"
