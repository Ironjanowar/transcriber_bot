#!/usr/bin/env bash
#
# Routine deployment for transcriptor_bot.
#
# Run as cuwano from the checkout that should be deployed:
#   ./deploy/deploy.sh
#
# This script never runs `git pull` and never uses sudo. It builds the exact
# checkout it is invoked from, installs the artifacts in place, initializes/validates the SQLite
# schema, installs the user units, and restarts the services. There is no
# automatic version rollback: if a deploy fails, fix the checkout and deploy
# again.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"

# shellcheck source=lib/common.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

APP_WAS_ACTIVE=0

on_error() {
  local status=$?
  if [[ "$status" -ne 0 && "$APP_WAS_ACTIVE" == "1" ]]; then
    warn "El deploy falló; se intenta volver a arrancar la release instalada (sin rollback de versión)."
    systemctl --user start "$APP_SERVICE" >/dev/null 2>&1 || true
  fi
  printf '[%s] ERROR: deploy.sh falló (código %s).\n' "$(date '+%H:%M:%S')" "$status" >&2
  exit "$status"
}
trap on_error ERR

CONFIGURE=0
SKIP_RUST=0
SKIP_ELIXIR=0
BUILD_ONLY=0

usage() {
  cat <<'EOF'
Uso: ./deploy/deploy.sh [opciones]

Compila el checkout actual y lo instala en ~/apps/transcriptor_bot, inicializa
el esquema SQLite, instala las unidades systemd --user y reinicia los
servicios. No hace git pull y no usa sudo.

Opciones:
  --configure     Volver a pedir los secretos (BOT_TOKEN/API_ID/API_HASH).
  --skip-rust     No recompilar el CLI Rust (usa el binario instalado).
  --skip-elixir   No recompilar la release Elixir (usa la release instalada).
  --build-only    Solo compilar/instalar artefactos; no migrar ni reiniciar.
  -h, --help      Mostrar esta ayuda.

Variables de entorno:
  TRANSCRIPTOR_BOT_APP_DIR   Directorio de instalación (por defecto
                             /home/cuwano/apps/transcriptor_bot).
  RUST_FEATURES              Features extra de Cargo (por defecto se añade
                             "cuda" si el paquete la declara).
EOF
}

sync_checkout() {
  local src dst
  src="$(cd "$REPO_ROOT" && pwd -P)"
  install -d -m 0755 "$APP_DIR"
  dst="$(cd "$APP_DIR" && pwd -P)"

  if [[ "$src" == "$dst" ]]; then
    log "El checkout ya está en ${APP_DIR}; se compila en sitio."
    return 0
  fi

  require_cmd rsync
  log "Sincronizando checkout ${src} -> ${dst} (sin .git, _build, deps, target ni runtime)"
  rsync -a --delete \
    --exclude='/.git/' \
    --exclude='/_build/' \
    --exclude='/deps/' \
    --exclude='/transcriber/target/' \
    --exclude='/runtime/' \
    --exclude='/.elixir_ls/' \
    --exclude='/cover/' \
    --exclude='/doc/' \
    --exclude='/.hermes/' \
    "${src}/" "${dst}/"
}

build_rust() {
  local crate_dir="${APP_DIR}/transcriber" cargo_args=() bin_name
  [[ -f "${crate_dir}/Cargo.toml" ]] || die "No existe ${crate_dir}/Cargo.toml; no se puede compilar el CLI Rust."

  resolve_nvcc || die "nvcc no está disponible. Ejecuta deploy/bootstrap.sh o instala el CUDA toolkit."
  log "Compilando CLI Rust con CUDA (${CUDA_HOME})"

  cargo_args=(build --release)
  if [[ -f "${crate_dir}/Cargo.lock" ]]; then
    cargo_args+=(--locked)
  fi
  if cargo_has_feature "$crate_dir" cuda; then
    cargo_args+=(--features cuda)
  elif [[ -n "${RUST_FEATURES:-}" ]]; then
    # shellcheck disable=SC2206
    cargo_args+=(--features "${RUST_FEATURES}")
  else
    warn "Cargo.toml no declara la feature 'cuda'; se usa la configuración por defecto."
  fi

  (
    cd "$crate_dir"
    cargo "${cargo_args[@]}"
  )

  bin_name="$(cargo_bin_name "$crate_dir")" || die "No se pudo determinar el binario de Cargo."
  [[ -x "${crate_dir}/target/release/${bin_name}" ]] \
    || die "Cargo no produjo ${crate_dir}/target/release/${bin_name}"

  install -d -m 0755 "${RUNTIME_DIR}/bin"
  local tmp_bin
  tmp_bin="$(mktemp "${RUNTIME_DIR}/bin/.transcriber.XXXXXX")"
  install -m 0755 "${crate_dir}/target/release/${bin_name}" "$tmp_bin"
  mv -f "$tmp_bin" "$APP_BIN"
  log "CLI instalado: ${APP_BIN}"

  verify_cuda_linkage "$APP_BIN" \
    || die "El CLI Rust no muestra enlace dinámico con CUDA/cuBLAS; se rechaza el artefacto."

  if ! "$APP_BIN" --help >/dev/null 2>&1; then
    warn "El CLI no respondió a --help; revisa su interfaz antes del smoke test."
  fi
  write_transcriber_wrapper
}

write_transcriber_wrapper() {
  local tmp
  [[ -x "$APP_BIN" ]] || die "No existe ${APP_BIN}; no se puede escribir el wrapper del transcriptor."
  tmp="$(mktemp "${RUNTIME_DIR}/.transcribe-audio.XXXXXX")"
  {
    printf '#!/bin/sh\n'
    printf 'set -eu\n'
    # shellcheck disable=SC2016  # ${1:?} is for the generated wrapper, not this shell
    printf 'exec "%s" --model "%s" --vad-model "%s" --input "${1:?missing input WAV}"\n' \
      "$APP_BIN" "$MODEL_FILE" "$VAD_MODEL_FILE"
  } > "$tmp"
  chmod 0755 "$tmp"
  mv -f "$tmp" "$APP_TRANSCRIBER"
  log "Wrapper del transcriptor actualizado: ${APP_TRANSCRIBER}"
}

write_launcher() {
  local tmp
  [[ -x "$RELEASE_BIN" ]] || die "No existe la release ${RELEASE_BIN}; no se puede escribir el lanzador."
  install -d -m 0755 "${RUNTIME_DIR}/bin"
  tmp="$(mktemp "${RUNTIME_DIR}/.start-transcriptor-bot.XXXXXX")"
  {
    printf '#!/bin/sh\n'
    printf 'set -eu\n'
    printf 'exec "%s" start\n' "$RELEASE_BIN"
  } > "$tmp"
  chmod 0755 "$tmp"
  mv -f "$tmp" "$APP_LAUNCHER"
  log "Lanzador actualizado: ${APP_LAUNCHER} -> ${RELEASE_BIN}"
}

stop_app_if_active() {
  if systemctl --user is-active --quiet "$APP_SERVICE"; then
    APP_WAS_ACTIVE=1
    log "Deteniendo ${APP_SERVICE} para migrar y sustituir la release"
    systemctl --user stop "$APP_SERVICE"
  fi
}

build_elixir() {
  local app_name
  [[ -f "${APP_DIR}/mix.exs" ]] || die "No existe ${APP_DIR}/mix.exs; no se puede compilar la release Elixir."
  if [[ "$BUILD_ONLY" != "1" ]]; then
    require_cmd systemctl
  fi

  app_name="$(elixir_app_name "${APP_DIR}/mix.exs")"
  if [[ -z "$app_name" ]]; then
    die "No se pudo leer el nombre de la app en ${APP_DIR}/mix.exs."
  fi
  if [[ "$app_name" != "$RELEASE_NAME" ]]; then
    log "mix.exs usa la app :${app_name}; se ajusta el nombre de release (era ${RELEASE_NAME})."
    RELEASE_NAME="$app_name"
    RELEASE_DIR="${APP_DIR}/_build/prod/rel/${RELEASE_NAME}"
    RELEASE_BIN="${RELEASE_DIR}/bin/${RELEASE_NAME}"
  fi

  log "Compilando release Elixir ${RELEASE_NAME}"
  (
    cd "$APP_DIR"
    env MIX_ENV=prod LANG=C.UTF-8 LC_ALL=C.UTF-8 "$MISE" exec -- mix local.hex --force
    env MIX_ENV=prod LANG=C.UTF-8 LC_ALL=C.UTF-8 "$MISE" exec -- mix local.rebar --force
    env MIX_ENV=prod LANG=C.UTF-8 LC_ALL=C.UTF-8 "$MISE" exec -- mix deps.get --only prod
    env MIX_ENV=prod LANG=C.UTF-8 LC_ALL=C.UTF-8 "$MISE" exec -- mix compile --warnings-as-errors
  )

  if [[ "$BUILD_ONLY" == "1" ]]; then
    (cd "$APP_DIR" && env MIX_ENV=prod "$MISE" exec -- mix release --overwrite)
    write_launcher
    return 0
  fi

  stop_app_if_active
  (
    cd "$APP_DIR"

    if env MIX_ENV=prod LANG=C.UTF-8 LC_ALL=C.UTF-8 "$MISE" exec -- mix help ecto.migrate >/dev/null 2>&1; then
      env MIX_ENV=prod LANG=C.UTF-8 LC_ALL=C.UTF-8 "$MISE" exec -- mix ecto.create
      env MIX_ENV=prod LANG=C.UTF-8 LC_ALL=C.UTF-8 "$MISE" exec -- mix ecto.migrate
    else
      # transcriptor_bot uses Exqlite directly: Store.init/1 creates its
      # schema with CREATE TABLE IF NOT EXISTS on first start.
      log "Sin tareas Ecto; el esquema SQLite se inicializa al arrancar (Exqlite)."
    fi
    env MIX_ENV=prod LANG=C.UTF-8 LC_ALL=C.UTF-8 "$MISE" exec -- mix release --overwrite
  )
  write_launcher
}

install_units() {
  local unit_dir="${APP_HOME}/.config/systemd/user"
  install -d -m 0755 "$unit_dir"
  install -m 0644 "${SCRIPT_DIR}/telegram-bot-api.service" "${unit_dir}/telegram-bot-api.service"
  install -m 0644 "${SCRIPT_DIR}/transcriptor-bot.service" "${unit_dir}/transcriptor-bot.service"
  systemctl --user daemon-reload
  systemctl --user enable "$BOT_API_SERVICE" "$APP_SERVICE"
  log "Unidades instaladas y habilitadas en ${unit_dir}"
}

journal_tail() {
  local unit="$1"
  journalctl --user -u "$unit" -n 50 --no-pager >&2 || true
}

start_services() {
  local ok=1
  systemctl --user reset-failed "$BOT_API_SERVICE" "$APP_SERVICE" >/dev/null 2>&1 || true
  log "Reiniciando ${BOT_API_SERVICE}"
  if ! systemctl --user restart "$BOT_API_SERVICE"; then
    journal_tail "$BOT_API_SERVICE"
    die "No se pudo reiniciar ${BOT_API_SERVICE}."
  fi
  if ! wait_for_bot_api 45; then
    journal_tail "$BOT_API_SERVICE"
    die "${BOT_API_SERVICE} no responde en ${BOT_API_URL}."
  fi
  log "Bot API local operativo en ${BOT_API_URL}"

  log "Reiniciando ${APP_SERVICE}"
  if ! systemctl --user restart "$APP_SERVICE"; then
    journal_tail "$APP_SERVICE"
    die "No se pudo reiniciar ${APP_SERVICE}."
  fi
  wait_for_unit_active "$APP_SERVICE" 60 || ok=0
  sleep 2
  if [[ "$ok" != "1" ]] || ! systemctl --user is-active --quiet "$APP_SERVICE"; then
    journal_tail "$APP_SERVICE"
    die "${APP_SERVICE} no quedó activo."
  fi
  log "${APP_SERVICE} activo"
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --configure) CONFIGURE=1 ;;
      --skip-rust) SKIP_RUST=1 ;;
      --skip-elixir) SKIP_ELIXIR=1 ;;
      --build-only) BUILD_ONLY=1 ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; die "Opción desconocida: $1" ;;
    esac
    shift
  done

  assert_not_root
  assert_runtime_user
  ensure_base_dirs

  ensure_env_file "$CONFIGURE"
  check_env_permissions "$APP_ENV_FILE"
  check_env_permissions "$BOT_API_ENV_FILE"
  load_env_file "$APP_ENV_FILE"
  is_valid_bot_token "${BOT_TOKEN:-}" || die "BOT_TOKEN inválido en ${APP_ENV_FILE}."
  is_valid_api_id "$(env_file_get TELEGRAM_API_ID "$BOT_API_ENV_FILE" || true)" \
    || die "TELEGRAM_API_ID inválido en ${BOT_API_ENV_FILE}."
  is_valid_api_hash "$(env_file_get TELEGRAM_API_HASH "$BOT_API_ENV_FILE" || true)" \
    || die "TELEGRAM_API_HASH inválido en ${BOT_API_ENV_FILE}."
  [[ "${OWNER_TELEGRAM_USER_ID:-}" == "$OWNER_TELEGRAM_USER_ID" ]] \
    || die "OWNER_TELEGRAM_USER_ID debe ser ${OWNER_TELEGRAM_USER_ID}."

  sync_checkout
  ensure_cargo_path

  if [[ "$SKIP_ELIXIR" != "1" ]]; then
    MISE="$(mise_bin)" || die "mise no está instalado; ejecuta deploy/bootstrap.sh."
    export MISE
    export PATH="${APP_HOME}/.local/bin:${PATH}"
  fi

  if [[ "$SKIP_RUST" != "1" ]]; then
    build_rust
  else
    [[ -x "$APP_BIN" ]] || die "--skip-rust requiere un transcriptor ejecutable: ${APP_BIN}"
    verify_cuda_linkage "$APP_BIN" \
      || die "--skip-rust requiere un transcriptor enlazado con CUDA/cuBLAS: ${APP_BIN}"
    write_transcriber_wrapper
  fi

  if [[ "$SKIP_ELIXIR" != "1" ]]; then
    build_elixir
  else
    [[ -x "$APP_LAUNCHER" ]] || warn "Se omite Elixir pero ${APP_LAUNCHER} no existe."
  fi

  if [[ "$BUILD_ONLY" != "1" ]]; then
    verify_model_file "$MODEL_FILE" \
      || die "El modelo Whisper no coincide con el tamaño y SHA-256 fijados: ${MODEL_FILE}"
    verify_vad_model_file "$VAD_MODEL_FILE" \
      || die "El modelo VAD no coincide con el tamaño y SHA-256 fijados: ${VAD_MODEL_FILE}"
    verify_bot_api_binary "$BOT_API_BIN" \
      || die "El Bot API instalado no soporta las flags requeridas."
    [[ "$(cat "${STATE_DIR}/telegram-bot-api-revision" 2>/dev/null || true)" == "$TELEGRAM_BOT_API_REF" ]] \
      || die "El Bot API instalado no corresponde al commit fijado ${TELEGRAM_BOT_API_REF}."
    install_units
    start_services
    record_revision "$REPO_ROOT"
  fi

  log "Deploy completado (${REPO_ROOT})."

  if [[ "$BUILD_ONLY" != "1" ]]; then
    cat >&2 <<EOF

Verificación:
  ./deploy/verify.sh
  ./deploy/smoke-test.sh

Operación:
  systemctl --user status ${APP_SERVICE} ${BOT_API_SERVICE}
  journalctl --user -u ${APP_SERVICE} -f
EOF
  fi
}

main "$@"
