#!/usr/bin/env bash
#
# Static validation for the deployment assets.
#
#   ./deploy/check-assets.sh
#
# Runs bash -n on every script, shellcheck when available, a systemd unit
# syntax check in a temporary fake $HOME, the shell test suite, and a scan for
# accidentally committed bot tokens.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"

# shellcheck source=lib/common.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

FAILURES=0
UNIT_TMP=""

cleanup() {
  if [[ -n "$UNIT_TMP" && -d "$UNIT_TMP" ]]; then
    rm -rf "$UNIT_TMP"
  fi
}
trap cleanup EXIT

ok() {
  printf 'OK    %s\n' "$*"
}

fail() {
  FAILURES=$((FAILURES + 1))
  printf 'FALLO %s\n' "$*" >&2
}

check_syntax() {
  local file
  while IFS= read -r file; do
    if bash -n "$file"; then
      ok "sintaxis: ${file#"$REPO_ROOT"/}"
    else
      fail "sintaxis: ${file#"$REPO_ROOT"/}"
    fi
    if [[ ! -x "$file" && "$file" != */lib/* ]]; then
      fail "sin permiso de ejecución: ${file#"$REPO_ROOT"/}"
    fi
  done < <(find "${SCRIPT_DIR}" -type f -name '*.sh' -print | sort)
}

check_shellcheck() {
  local file
  if ! command -v shellcheck >/dev/null 2>&1; then
    printf 'AVISO shellcheck no está instalado; se omite.\n'
    return
  fi
  while IFS= read -r file; do
    if shellcheck -x "$file"; then
      ok "shellcheck: ${file#"$REPO_ROOT"/}"
    else
      fail "shellcheck: ${file#"$REPO_ROOT"/}"
    fi
  done < <(find "${SCRIPT_DIR}" -type f -name '*.sh' -print | sort)
}

fake_unit_tree() {
  local root="$1"
  install -d -m 0755 \
    "${root}/home/apps/transcriptor_bot/runtime/bin" \
    "${root}/home/.local/bin" \
    "${root}/home/.config/transcriptor_bot" \
    "${root}/home/.local/share/transcriptor_bot/telegram-bot-api/tmp"
  printf '#!/bin/sh\nexit 0\n' > "${root}/home/apps/transcriptor_bot/runtime/bin/start-transcriptor-bot"
  printf '#!/bin/sh\nexit 0\n' > "${root}/home/.local/bin/telegram-bot-api"
  chmod 0755 \
    "${root}/home/apps/transcriptor_bot/runtime/bin/start-transcriptor-bot" \
    "${root}/home/.local/bin/telegram-bot-api"
  printf 'BOT_TOKEN=123456:placeholder\n' \
    > "${root}/home/.config/transcriptor_bot/app.env"
  printf 'TELEGRAM_API_ID=1\nTELEGRAM_API_HASH=00000000000000000000000000000000\n' \
    > "${root}/home/.config/transcriptor_bot/bot-api.env"
  chmod 0600 "${root}/home/.config/transcriptor_bot/app.env" \
    "${root}/home/.config/transcriptor_bot/bot-api.env"
}

check_units() {
  local unit
  if ! command -v systemd-analyze >/dev/null 2>&1; then
    printf 'AVISO systemd-analyze no está instalado; se omite la validación de unidades.\n'
    return
  fi

  UNIT_TMP="$(mktemp -d)"
  fake_unit_tree "$UNIT_TMP"
  for unit in transcriptor-bot.service telegram-bot-api.service; do
    sed "s#/home/cuwano#${UNIT_TMP}/home#g" "${SCRIPT_DIR}/${unit}" > "${UNIT_TMP}/${unit}"
  done

  if systemd-analyze verify "${UNIT_TMP}/transcriptor-bot.service" "${UNIT_TMP}/telegram-bot-api.service"; then
    ok "systemd-analyze verify: unidades"
  else
    fail "systemd-analyze verify: unidades"
  fi

  for unit in transcriptor-bot.service telegram-bot-api.service; do
    if grep -q '^NoNewPrivileges=yes$' "${SCRIPT_DIR}/${unit}" \
      && grep -q '^ProtectSystem=strict$' "${SCRIPT_DIR}/${unit}" \
      && grep -q '^ProtectHome=read-only$' "${SCRIPT_DIR}/${unit}" \
      && grep -q '^ReadWritePaths=/home/cuwano/.local/share/transcriptor_bot' "${SCRIPT_DIR}/${unit}" \
      && grep -q '^Restart=on-failure$' "${SCRIPT_DIR}/${unit}" \
      && grep -q '^UMask=0077$' "${SCRIPT_DIR}/${unit}"; then
      ok "hardening: ${unit}"
    else
      fail "faltan directivas de hardening en ${unit}"
    fi
  done

  if grep -q -- '--http-ip-address=127.0.0.1' "${SCRIPT_DIR}/telegram-bot-api.service" \
    && grep -q -- '--local' "${SCRIPT_DIR}/telegram-bot-api.service"; then
    ok "Bot API en loopback y modo local"
  else
    fail "el Bot API no está fijado a loopback/local"
  fi
}

check_secrets() {
  local matches
  matches="$(grep -RInE '[0-9]{8,12}:[A-Za-z0-9_-]{30,}' \
    --exclude-dir=.git --exclude-dir=_build --exclude-dir=deps \
    --exclude-dir=target --exclude-dir=runtime \
    "$REPO_ROOT" 2>/dev/null || true)"
  if [[ -n "$matches" ]]; then
    fail "posible token de Telegram en el repositorio"
    printf '%s\n' "$matches" >&2
  else
    ok "sin tokens de Telegram evidentes"
  fi

  if grep -qE '^\*\.env$' "${REPO_ROOT}/.gitignore" 2>/dev/null \
    && grep -qE '^\*\.db|^/?_build/|^/?deps/' "${REPO_ROOT}/.gitignore" 2>/dev/null; then
    ok ".gitignore cubre artefactos y secretos"
  else
    fail ".gitignore no cubre artefactos/secretos esperados"
  fi
}

check_tool_versions() {
  if [[ -f "${REPO_ROOT}/.tool-versions" ]] \
    && grep -qE '^erlang [0-9]' "${REPO_ROOT}/.tool-versions" \
    && grep -qE '^elixir [0-9]' "${REPO_ROOT}/.tool-versions"; then
    ok ".tool-versions fija Erlang y Elixir"
  else
    fail ".tool-versions no fija Erlang y Elixir"
  fi
}

check_test_suite() {
  local test
  for test in "${SCRIPT_DIR}"/tests/test-*.sh; do
    if [[ ! -x "$test" ]]; then
      fail "test sin permiso de ejecución: ${test#"$REPO_ROOT"/}"
    elif "$test"; then
      ok "test: ${test#"$REPO_ROOT"/}"
    else
      fail "test: ${test#"$REPO_ROOT"/}"
    fi
  done
}

main() {
  log "Validando assets de despliegue"
  check_syntax
  check_shellcheck
  check_units
  check_secrets
  check_tool_versions
  check_test_suite

  if command -v git >/dev/null 2>&1 && git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    if git -C "$REPO_ROOT" diff --check; then
      ok "git diff --check"
    else
      fail "git diff --check"
    fi
  fi

  if [[ "$FAILURES" -gt 0 ]]; then
    printf '\n%d comprobación(es) fallaron.\n' "$FAILURES" >&2
    exit 1
  fi
  printf '\nAssets de despliegue validados.\n'
}

main "$@"
