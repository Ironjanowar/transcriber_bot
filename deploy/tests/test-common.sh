#!/usr/bin/env bash
#
# Shell-level tests for deploy/lib/common.sh.
#
# These tests do not touch the real $HOME, systemd, Telegram, or CUDA. They
# exercise path derivation, secret validation, the non-evaluating environment
# parser, split environment-file writers, and pinned artifact verification.

set -Eeuo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
DEPLOY_DIR="$(cd -- "${TEST_DIR}/.." && pwd -P)"
TEST_TMP="$(mktemp -d)"

cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

export TRANSCRIPTOR_BOT_HOME="${TEST_TMP}/home"
export TRANSCRIPTOR_BOT_ALLOW_ANY_USER=1
mkdir -p "$TRANSCRIPTOR_BOT_HOME"

# shellcheck source=../lib/common.sh
# shellcheck disable=SC1091
source "${DEPLOY_DIR}/lib/common.sh"

PASS=0
FAIL=0

ok() {
  PASS=$((PASS + 1))
  printf 'ok   %s\n' "$*"
}

not_ok() {
  FAIL=$((FAIL + 1))
  printf 'FAIL %s\n' "$*" >&2
}

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  if [[ "$expected" == "$actual" ]]; then
    ok "$label"
  else
    not_ok "$label (esperado: ${expected}, actual: ${actual})"
  fi
}

assert_true() {
  local label="$1"
  shift
  if "$@"; then
    ok "$label"
  else
    not_ok "$label"
  fi
}

assert_false() {
  local label="$1"
  shift
  if "$@"; then
    not_ok "$label"
  else
    ok "$label"
  fi
}

token="123456789:$(printf 'A%.0s' {1..35})"
api_id="1234567"
api_hash="0123456789abcdef0123456789abcdef"

# Paths derive from the overridden home, never from the caller's real home.
assert_eq "${TRANSCRIPTOR_BOT_HOME}/apps/transcriptor_bot" "$APP_DIR" "APP_DIR"
assert_eq "${TRANSCRIPTOR_BOT_HOME}/.local/share/transcriptor_bot" "$STATE_DIR" "STATE_DIR"
assert_eq "${TRANSCRIPTOR_BOT_HOME}/.config/transcriptor_bot/app.env" "$APP_ENV_FILE" "APP_ENV_FILE"
assert_eq "${TRANSCRIPTOR_BOT_HOME}/.config/transcriptor_bot/bot-api.env" "$BOT_API_ENV_FILE" "BOT_API_ENV_FILE"
assert_eq "${STATE_DIR}/transcriptor_bot.db" "$DB_PATH" "DB_PATH"
assert_eq "${STATE_DIR}/models/ggml-large-v3.bin" "$MODEL_FILE" "MODEL_FILE"

# Secret shape validation.
assert_true "token válido" is_valid_bot_token "$token"
assert_false "token sin ':' rechazado" is_valid_bot_token "123456789"
assert_false "token con letras en el id rechazado" is_valid_bot_token "abc:${token#*:}"
assert_true "api id válido" is_valid_api_id "$api_id"
assert_false "api id no numérico rechazado" is_valid_api_id "abc"
assert_true "api hash válido" is_valid_api_hash "$api_hash"
assert_false "api hash corto rechazado" is_valid_api_hash "abcdef"
assert_true "commit completo válido" is_valid_git_commit "7232881b39dfcd048a0d569f1983c5184249ee05"
assert_false "commit abreviado rechazado" is_valid_git_commit "7232881"
assert_false "ref simbólica rechazada" is_valid_git_commit "master"

# write_env_files creates isolated 0600 files. The Bot API must never receive
# the bot token and the application must never receive api_id/api_hash.
export BOT_TOKEN="$token"
export TELEGRAM_API_ID="$api_id"
export TELEGRAM_API_HASH="$api_hash"
write_env_files
assert_eq "600" "$(stat -c '%a' "$APP_ENV_FILE")" "app env mode 0600"
assert_eq "600" "$(stat -c '%a' "$BOT_API_ENV_FILE")" "bot api env mode 0600"
assert_eq "1" "$(grep -c '^OWNER_TELEGRAM_USER_ID=' "$APP_ENV_FILE")" "owner aparece una vez"
assert_eq "$OWNER_TELEGRAM_USER_ID" "$(env_file_get OWNER_TELEGRAM_USER_ID "$APP_ENV_FILE")" "owner fijado"
assert_eq "$DB_PATH" "$(env_file_get DATABASE_PATH "$APP_ENV_FILE")" "DATABASE_PATH escrito"
assert_eq "$APP_TRANSCRIBER" "$(env_file_get TRANSCRIBER_COMMAND "$APP_ENV_FILE")" "wrapper del transcriptor escrito"
assert_eq "0" "$(grep -c '^TELEGRAM_API_ID=' "$APP_ENV_FILE" || true)" "app no recibe api id"
assert_eq "0" "$(grep -c '^TELEGRAM_API_HASH=' "$APP_ENV_FILE" || true)" "app no recibe api hash"
assert_eq "0" "$(grep -c '^BOT_TOKEN=' "$BOT_API_ENV_FILE" || true)" "Bot API no recibe token"
assert_eq "2" "$(grep -c '^[A-Z_]*=' "$BOT_API_ENV_FILE")" "Bot API recibe solo dos variables"
assert_eq "$api_id" "$(env_file_get TELEGRAM_API_ID "$BOT_API_ENV_FILE")" "Bot API api id"
assert_eq "$api_hash" "$(env_file_get TELEGRAM_API_HASH "$BOT_API_ENV_FILE")" "Bot API api hash"

# load_env_file imports values without evaluating shell syntax.
load_env_file "$APP_ENV_FILE"
assert_eq "$token" "$BOT_TOKEN" "BOT_TOKEN cargado"
assert_eq "14977303" "$OWNER_TELEGRAM_USER_ID" "owner cargado"
assert_eq "$BOT_API_URL" "$TELEGRAM_API_BASE_URL" "base URL cargada"

evil_file="${TEST_TMP}/evil.env"
# shellcheck disable=SC2016  # the literal $() must reach the parser unexpanded
printf 'EVIL=$(touch %s/pwned)\n' "$TEST_TMP" > "$evil_file"
load_env_file "$evil_file"
assert_false "el parser no ejecuta command substitution" test -e "${TEST_TMP}/pwned"
# shellcheck disable=SC2016
assert_eq '$(touch '"${TEST_TMP}"'/pwned)' "$EVIL" "el valor se conserva literal"

bad_key_file="${TEST_TMP}/bad-key.env"
printf 'BAD-KEY=value\n' > "$bad_key_file"
if ( load_env_file "$bad_key_file" ) >/dev/null 2>&1; then
  not_ok "clave inválida rechazada"
else
  ok "clave inválida rechazada"
fi

# ensure_env_file is non-interactive when the variables are already exported.
ensure_env_file 1 >/dev/null
assert_eq "$token" "$(env_file_get BOT_TOKEN "$APP_ENV_FILE")" "ensure_env_file conserva token"

# A former combined env file is migrated and removed rather than retained as a
# stale aggregate secret.
rm -f "$APP_ENV_FILE" "$BOT_API_ENV_FILE"
printf 'BOT_TOKEN=%s\nTELEGRAM_API_ID=%s\nTELEGRAM_API_HASH=%s\n' \
  "$token" "$api_id" "$api_hash" > "$LEGACY_ENV_FILE"
chmod 600 "$LEGACY_ENV_FILE"
ensure_env_file 0 >/dev/null
assert_true "migración crea app.env" test -f "$APP_ENV_FILE"
assert_true "migración crea bot-api.env" test -f "$BOT_API_ENV_FILE"
assert_false "migración elimina env combinado" test -e "$LEGACY_ENV_FILE"

# Generic pinned files require both exact size and SHA-256.
pinned="${TEST_TMP}/pinned.bin"
printf 'silero-vad-test' > "$pinned"
pinned_size="$(stat -c '%s' "$pinned")"
pinned_sha="$(sha256sum "$pinned" | awk '{print $1}')"
assert_true "archivo fijado válido" verify_pinned_file "$pinned" "$pinned_size" "$pinned_sha"
assert_false "tamaño fijado incorrecto" verify_pinned_file "$pinned" "$((pinned_size + 1))" "$pinned_sha"
assert_false "sha fijado incorrecto" verify_pinned_file "$pinned" "$pinned_size" "$(printf '0%.0s' {1..64})"

# Pure metadata helpers.
fake_mix="${TEST_TMP}/mix.exs"
printf 'defmodule Fake.MixProject do\n  def project, do: [app: :transcriptor_bot]\nend\n' > "$fake_mix"
assert_eq "transcriptor_bot" "$(elixir_app_name "$fake_mix")" "elixir_app_name lee mix.exs"
fake_crate="${TEST_TMP}/crate"
mkdir -p "$fake_crate"
printf '[package]\nname = "transcriber"\nversion = "0.1.0"\n' > "${fake_crate}/Cargo.toml"
assert_eq "transcriber" "$(cargo_bin_name "$fake_crate")" "cargo_bin_name por Cargo.toml"

assert_true "disk_available_kb devuelve un número" bash -c "[[ \"\$(source '${DEPLOY_DIR}/lib/common.sh'; disk_available_kb '${TEST_TMP}')\" =~ ^[0-9]+$ ]]"

printf '\n%d pruebas pasaron, %d fallaron.\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
