#!/usr/bin/env bash
set -Eeuo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
DEPLOY_DIR="$(cd -- "${TEST_DIR}/.." && pwd -P)"
FAIL=0

expect() {
  local label="$1" pattern="$2" file="$3"
  if grep -Eq -- "$pattern" "$file"; then
    printf 'ok   %s\n' "$label"
  else
    printf 'FAIL %s\n' "$label" >&2
    FAIL=$((FAIL + 1))
  fi
}

reject() {
  local label="$1" pattern="$2" file="$3"
  if grep -Eq -- "$pattern" "$file"; then
    printf 'FAIL %s\n' "$label" >&2
    FAIL=$((FAIL + 1))
  else
    printf 'ok   %s\n' "$label"
  fi
}

bot_unit="${DEPLOY_DIR}/telegram-bot-api.service"
app_unit="${DEPLOY_DIR}/transcriptor-bot.service"
bootstrap="${DEPLOY_DIR}/bootstrap.sh"
deploy="${DEPLOY_DIR}/deploy.sh"

expect "Bot API usa entorno aislado" 'EnvironmentFile=.*/bot-api\.env$' "$bot_unit"
reject "credenciales Bot API ausentes de argv" '--api-(id|hash)' "$bot_unit"
expect "aplicación usa entorno aislado" 'EnvironmentFile=.*/app\.env$' "$app_unit"
expect "wrapper activa VAD" '--vad-model' "$deploy"
expect "wrapper usa el modelo VAD fijado" 'VAD_MODEL_FILE' "$deploy"
expect "skip-rust falla sin binario" '--skip-rust requiere un transcriptor ejecutable' "$deploy"
expect "modelo Whisper se verifica antes de servicios" 'verify_model_file' "$deploy"
expect "modelo VAD se verifica antes de servicios" 'verify_vad_model_file' "$deploy"
expect "build-only separa instalación" 'if \[\[ "\$BUILD_ONLY" != "1" \]\]' "$deploy"
expect "revisión solo se registra en instalación" '^[[:space:]]+record_revision "\$REPO_ROOT"' "$deploy"
expect "ref Bot API exige commit completo" 'is_valid_git_commit.*TELEGRAM_BOT_API_REF' "$bootstrap"
expect "fetch obtiene el commit exacto" 'fetch.*TELEGRAM_BOT_API_REF' "$bootstrap"
expect "checkout verifica el hash fijado" 'rev-parse.*HEAD.*TELEGRAM_BOT_API_REF|TELEGRAM_BOT_API_REF.*rev-parse.*HEAD' "$bootstrap"
reject "sin fallback a master" 'fetch.*master|usará master' "$bootstrap"

[[ "$FAIL" -eq 0 ]]