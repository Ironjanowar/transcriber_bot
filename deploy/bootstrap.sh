#!/usr/bin/env bash
#
# One-time host preparation for transcriptor_bot.
#
# Run as the service user (cuwano), from the repository checkout:
#   ./deploy/bootstrap.sh
#
# This script may use sudo to install native packages and enable lingering.
# It does not build the Elixir application or start the services; that is
# deploy.sh's job.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"

# shellcheck source=lib/common.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

on_error() {
  local status=$?
  printf '[%s] ERROR: bootstrap.sh falló (código %s).\n' "$(date '+%H:%M:%S')" "$status" >&2
  exit "$status"
}
trap on_error ERR

ASSUME_YES=0
SKIP_SYSTEM_PACKAGES=0
SKIP_BOT_API=0
SKIP_MODEL=0
FORCE_BOT_API=0
ALLOW_MISSING_CUDA=0
FORCE_CONFIGURE=0

usage() {
  cat <<'EOF'
Uso: ./deploy/bootstrap.sh [opciones]

Prepara una máquina una sola vez: dependencias nativas, toolchain de Elixir,
CUDA, ffmpeg, Telegram Bot API local, modelo Whisper y lingering.

Opciones:
  --yes                    No preguntar antes de instalar paquetes o linger.
  --skip-system-packages   No instalar paquetes; solo comprobar que existan.
  --skip-bot-api           No compilar el servidor local de Telegram Bot API.
  --force-bot-api          Recompilar el Bot API aunque ya exista.
  --skip-model             No descargar los modelos Whisper y Silero VAD.
  --allow-missing-cuda     Continuar sin nvcc (el build Rust fallará después).
  --configure              Volver a pedir BOT_TOKEN, API_ID y API_HASH.
  -h, --help               Mostrar esta ayuda.

Variables de entorno útiles:
  TELEGRAM_BOT_API_REF     Commit del repositorio tdlib/telegram-bot-api.
  TELEGRAM_BOT_API_JOBS    Paralelismo de compilación del Bot API.
  RUST_VERSION             Toolchain de Rust para rustup (por defecto 1.99.1).
  TRANSCRIPTOR_BOT_MODEL_URL  URL alternativa para el modelo.
  TRANSCRIPTOR_BOT_VAD_MODEL_URL  URL alternativa para el modelo Silero VAD.
EOF
}

confirm() {
  local prompt="$1" answer
  [[ "$ASSUME_YES" == "1" ]] && return 0
  [[ -t 0 ]] || die "Se requiere confirmación y no hay terminal. Usa --yes."
  printf '%s [s/N]: ' "$prompt" >&2
  read -r answer
  [[ "$answer" =~ ^[sSyY]$ ]]
}

sudo_cmd() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    have sudo || die "Se necesita sudo para esta operación y no está instalado."
    sudo "$@"
  fi
}

detect_package_manager() {
  local pm
  for pm in apt-get dnf pacman zypper; do
    if have "$pm"; then
      printf '%s\n' "$pm"
      return 0
    fi
  done
  return 1
}

required_commands() {
  printf '%s\n' \
    git curl cmake make gcc g++ clang pkg-config gperf ffmpeg ffprobe rsync sqlite3 \
    sha256sum unzip autoconf jq
}

missing_commands() {
  local cmd missing=()
  while IFS= read -r cmd; do
    have "$cmd" || missing+=("$cmd")
  done < <(required_commands)
  printf '%s\n' "${missing[@]:-}"
}

install_system_packages() {
  local missing pm packages=()
  missing="$(missing_commands)"
  if [[ -z "$missing" ]]; then
    log "Dependencias nativas presentes."
    return 0
  fi

  log "Comandos que faltan: ${missing//$'\n'/ }"
  if [[ "$SKIP_SYSTEM_PACKAGES" == "1" ]]; then
    die "Faltan dependencias y se pasó --skip-system-packages. Instálalas manualmente y repite."
  fi

  pm="$(detect_package_manager)" || die "No se reconoce el gestor de paquetes. Instala manualmente: ${missing//$'\n'/ }"

  case "$pm" in
    apt-get)
      packages=(build-essential clang libclang-dev cmake git curl ca-certificates pkg-config libssl-dev zlib1g-dev gperf ffmpeg rsync sqlite3 unzip autoconf libncurses-dev jq)
      ;;
    dnf)
      packages=(gcc gcc-c++ clang clang-devel make cmake git curl ca-certificates pkgconf-pkg-config openssl-devel zlib-devel gperf ffmpeg rsync sqlite unzip autoconf ncurses-devel jq)
      ;;
    pacman)
      packages=(base-devel clang cmake git curl ca-certificates pkgconf openssl zlib gperf ffmpeg rsync sqlite unzip autoconf ncurses jq)
      ;;
    zypper)
      packages=(gcc gcc-c++ clang clang-devel make cmake git curl ca-certificates pkg-config libopenssl-devel zlib-devel gperf ffmpeg rsync sqlite3 unzip autoconf ncurses-devel jq)
      ;;
    *)
      die "Gestor de paquetes no soportado: ${pm}"
      ;;
  esac

  if ! confirm "Se instalarán paquetes con sudo (${pm}). ¿Continuar?"; then
    die "Instalación de paquetes cancelada."
  fi

  log "Instalando paquetes con ${pm}"
  case "$pm" in
    apt-get)
      sudo_cmd env DEBIAN_FRONTEND=noninteractive apt-get update
      sudo_cmd env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}"
      ;;
    dnf)
      sudo_cmd dnf install -y "${packages[@]}"
      ;;
    pacman)
      sudo_cmd pacman -S --needed --noconfirm "${packages[@]}"
      ;;
    zypper)
      sudo_cmd zypper --non-interactive install "${packages[@]}"
      ;;
  esac

  missing="$(missing_commands)"
  [[ -z "$missing" ]] || die "Siguen faltando comandos tras instalar: ${missing//$'\n'/ }"
}

check_cuda() {
  log "Comprobando CUDA"
  if resolve_nvcc; then
    log "nvcc: ${NVCC}"
    "$NVCC" --version | tail -n 1 >&2 || true
    if [[ ! -f "${CUDA_HOME}/include/cuda_runtime.h" ]]; then
      warn "No se encontró ${CUDA_HOME}/include/cuda_runtime.h; el toolkit puede estar incompleto."
    fi
    if ! compgen -G "${CUDA_HOME}/lib64/libcublas.so*" >/dev/null 2>&1; then
      warn "No se encontró libcublas en ${CUDA_HOME}/lib64; whisper.cpp puede no compilar con CUDA."
    fi
  else
    warn "No se encontró nvcc (CUDA toolkit)."
    cat >&2 <<'EOF'
  Para compilar el CLI Rust con CUDA necesitas el toolkit de CUDA, no solo el driver:
    Ubuntu/Debian: instala el driver NVIDIA y CUDA Toolkit 12.x desde
                   https://developer.nvidia.com/cuda-downloads
                   y exporta CUDA_HOME=/usr/local/cuda
    Arch:          sudo pacman -S cuda
  Después verifica: nvcc --version && nvidia-smi
EOF
    if [[ "$ALLOW_MISSING_CUDA" != "1" ]]; then
      die "Instala CUDA o usa --allow-missing-cuda para preparar el resto del host."
    fi
    warn "Continuando sin CUDA por --allow-missing-cuda."
  fi

  if have nvidia-smi; then
    if nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader; then
      :
    else
      warn "nvidia-smi existe pero no puede comunicarse con el driver/GPU."
    fi
  else
    warn "nvidia-smi no está disponible; el runtime CUDA no podrá usarse."
  fi

  if [[ ! -e /dev/nvidia0 ]]; then
    warn "No existe /dev/nvidia0. En un contenedor puede ser normal; en el host revisa el driver NVIDIA."
  fi
  log "gcc: $(gcc -dumpfullversion 2>/dev/null || echo desconocido)"
}

ensure_rust() {
  local version rust_version major minor
  ensure_cargo_path
  if have cargo && have rustc; then
    version="$(cargo --version 2>/dev/null | awk '{print $2}')"
    major="${version%%.*}"
    minor="${version#*.}"
    minor="${minor%%.*}"
    if [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] \
      && (( major < 1 || (major == 1 && minor < 85) )); then
      warn "Rust ${version} es anterior a 1.85; se instalará el toolchain fijado."
    else
      log "Rust presente: cargo ${version}"
      return 0
    fi
  fi

  rust_version="${RUST_VERSION:-1.99.1}"
  log "Instalando Rust ${rust_version} con rustup en ${CARGO_HOME}"
  install -d -m 0755 "${CARGO_HOME}/bin" "$RUSTUP_HOME"
  local installer
  installer="$(mktemp)"
  curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs -o "$installer"
  CARGO_HOME="$CARGO_HOME" RUSTUP_HOME="$RUSTUP_HOME" \
    sh "$installer" -y --no-modify-path --profile minimal --default-toolchain "$rust_version"
  rm -f "$installer"
  ensure_cargo_path
  [[ -x "${CARGO_HOME}/bin/cargo" ]] || die "rustup no instaló ${CARGO_HOME}/bin/cargo"
  log "Rust instalado: $(cargo --version)"
}

ensure_mise() {
  if MISE="$(mise_bin)"; then
    log "mise: ${MISE}"
  else
    log "Instalando mise en ${APP_HOME}/.local/bin"
    install -d -m 0755 "${APP_HOME}/.local/bin"
    local installer
    installer="$(mktemp)"
    curl -fsSL https://mise.run -o "$installer"
    MISE_INSTALL_PATH="${APP_HOME}/.local/bin/mise" sh "$installer"
    rm -f "$installer"
    [[ -x "${APP_HOME}/.local/bin/mise" ]] || die "La instalación de mise no creó ${APP_HOME}/.local/bin/mise"
    MISE="${APP_HOME}/.local/bin/mise"
  fi
  export MISE
  export PATH="${APP_HOME}/.local/bin:${PATH}"

  [[ -f "${REPO_ROOT}/.tool-versions" ]] || die "Falta ${REPO_ROOT}/.tool-versions"
  log "Instalando Erlang/Elixir desde .tool-versions"
  (
    cd "$REPO_ROOT"
    MISE_YES=1 "$MISE" install
    "$MISE" exec -- elixir --version
    "$MISE" exec -- mix local.hex --force
    "$MISE" exec -- mix local.rebar --force
  )
}

install_bot_api() {
  if [[ "$SKIP_BOT_API" == "1" ]]; then
    log "Bot API: omitido por --skip-bot-api"
    [[ -x "$BOT_API_BIN" ]] || warn "No existe ${BOT_API_BIN}; la unidad del Bot API no arrancará."
    return 0
  fi

  is_valid_git_commit "$TELEGRAM_BOT_API_REF" \
    || die "TELEGRAM_BOT_API_REF debe ser un commit hexadecimal completo de 40 caracteres."
  install -d -m 0755 "${APP_HOME}/.local/bin"
  if [[ -x "$BOT_API_BIN" && "$FORCE_BOT_API" != "1" ]]; then
    if [[ "$(cat "${STATE_DIR}/telegram-bot-api-revision" 2>/dev/null || true)" == "$TELEGRAM_BOT_API_REF" ]] \
      && verify_bot_api_binary "$BOT_API_BIN"; then
      log "Bot API fijado ya instalado: ${BOT_API_BIN} (${TELEGRAM_BOT_API_REF})"
      return 0
    fi
    warn "El Bot API instalado no demuestra la revisión fijada o no soporta las flags requeridas; se recompilará."
  fi

  require_cmd git cmake g++ make
  install -d -m 0755 "${APP_HOME}/.local/src"
  if [[ "$FORCE_BOT_API" == "1" && -L "$BOT_API_BIN" ]]; then
    rm -f "$BOT_API_BIN"
  fi

  if [[ ! -d "${BOT_API_SRC}/.git" ]]; then
    [[ ! -e "$BOT_API_SRC" ]] || die "${BOT_API_SRC} existe pero no es un repositorio git."
    log "Inicializando Telegram Bot API (${TELEGRAM_BOT_API_REF})"
    git init "$BOT_API_SRC"
    git -C "$BOT_API_SRC" remote add origin "$TELEGRAM_BOT_API_URL"
  fi

  git -C "$BOT_API_SRC" remote set-url origin "$TELEGRAM_BOT_API_URL"
  log "Obteniendo el objeto exacto de Telegram Bot API ${TELEGRAM_BOT_API_REF}"
  git -C "$BOT_API_SRC" fetch --depth 1 origin "$TELEGRAM_BOT_API_REF"
  [[ "$(git -C "$BOT_API_SRC" rev-parse 'FETCH_HEAD^{commit}')" == "$TELEGRAM_BOT_API_REF" ]] \
    || die "El objeto descargado no coincide con TELEGRAM_BOT_API_REF."
  git -C "$BOT_API_SRC" checkout --detach --force FETCH_HEAD
  [[ "$(git -C "$BOT_API_SRC" rev-parse HEAD)" == "$TELEGRAM_BOT_API_REF" ]] \
    || die "El checkout del Bot API no coincide con TELEGRAM_BOT_API_REF."
  git -C "$BOT_API_SRC" submodule update --init --recursive --depth 1

  local jobs
  jobs="${TELEGRAM_BOT_API_JOBS:-4}"
  log "Compilando Telegram Bot API (jobs=${jobs}); puede tardar varios minutos"
  cmake -S "$BOT_API_SRC" -B "${BOT_API_SRC}/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${APP_HOME}/.local" \
    -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF
  cmake --build "${BOT_API_SRC}/build" --target install --parallel "$jobs"

  verify_bot_api_binary "$BOT_API_BIN" \
    || die "El Bot API compilado no expone --local/--http-ip-address/--http-port."
  git -C "$BOT_API_SRC" rev-parse HEAD > "${STATE_DIR}/telegram-bot-api-revision"
  chmod 600 "${STATE_DIR}/telegram-bot-api-revision"
  log "Bot API instalado: ${BOT_API_BIN}"
}

download_model() {
  if [[ "$SKIP_MODEL" == "1" ]]; then
    log "Modelo: omitido por --skip-model"
    return 0
  fi

  install -d -m 0700 "$MODEL_DIR"

  if verify_model_file "$MODEL_FILE"; then
    chmod 600 "$MODEL_FILE"
    log "Modelo ya presente y verificado: ${MODEL_FILE}"
    return 0
  fi

  local available_kb required_kb part attempt
  available_kb="$(disk_available_kb "$MODEL_DIR")"
  required_kb=$(( MODEL_SIZE / 1024 + 1048576 ))
  if [[ -z "$available_kb" || "$available_kb" -lt "$required_kb" ]]; then
    die "Espacio insuficiente en ${MODEL_DIR}: se necesitan ~$(( required_kb / 1024 )) MiB libres."
  fi

  if [[ -f "$MODEL_FILE" ]]; then
    warn "El modelo existente no coincide en tamaño o SHA-256; se conserva como .corrupt"
    mv -f "$MODEL_FILE" "${MODEL_FILE}.corrupt.$(date +%s)"
  fi

  part="${MODEL_FILE}.part"
  if [[ -f "$part" ]]; then
    local part_size
    part_size="$(stat -c '%s' "$part")"
    if [[ "$part_size" -gt "$MODEL_SIZE" ]]; then
      warn "Descarga parcial mayor que el modelo esperado; se reinicia."
      rm -f "$part"
    else
      log "Reanudando descarga parcial ($(( part_size / 1024 / 1024 )) MiB)."
    fi
  fi

  for attempt in 1 2; do
    log "Descargando ggml-large-v3.bin F16 (intento ${attempt}/2)"
    if ! curl --fail --location --retry 5 --retry-delay 5 --retry-all-errors \
      --continue-at - --output "$part" "$MODEL_URL"; then
      warn "curl falló; se reintentará."
      sleep 5
      continue
    fi

    if [[ "$(stat -c '%s' "$part" 2>/dev/null || echo 0)" != "$MODEL_SIZE" ]]; then
      warn "Tamaño inesperado tras la descarga; se reintentará."
      continue
    fi
    if [[ "$(sha256_of "$part")" != "$MODEL_SHA256" ]]; then
      warn "SHA-256 no coincide; se descarta la descarga parcial."
      rm -f "$part"
      continue
    fi

    mv -f "$part" "$MODEL_FILE"
    chmod 600 "$MODEL_FILE"
    log "Modelo verificado: ${MODEL_FILE}"
    return 0
  done

  die "No se pudo descargar/verificar ${MODEL_FILE}. Revisa ${MODEL_URL} y el checksum; puedes reintentar con bootstrap.sh."
}

download_vad_model() {
  if [[ "$SKIP_MODEL" == "1" ]]; then
    return 0
  fi

  install -d -m 0700 "$MODEL_DIR"
  if verify_vad_model_file "$VAD_MODEL_FILE"; then
    chmod 600 "$VAD_MODEL_FILE"
    log "Modelo VAD ya presente y verificado: ${VAD_MODEL_FILE}"
    return 0
  fi

  local part="${VAD_MODEL_FILE}.part" attempt
  rm -f "$part"
  for attempt in 1 2; do
    log "Descargando Silero VAD v6.2.0 (intento ${attempt}/2)"
    if curl --fail --location --retry 5 --retry-delay 5 --retry-all-errors \
      --output "$part" "$VAD_MODEL_URL" \
      && verify_pinned_file "$part" "$VAD_MODEL_SIZE" "$VAD_MODEL_SHA256"; then
      mv -f "$part" "$VAD_MODEL_FILE"
      chmod 600 "$VAD_MODEL_FILE"
      log "Modelo VAD verificado: ${VAD_MODEL_FILE}"
      return 0
    fi
    warn "El modelo VAD descargado no coincide en tamaño/SHA-256; se reintentará."
    rm -f "$part"
  done
  die "No se pudo descargar/verificar ${VAD_MODEL_FILE}."
}

check_linger() {
  local linger=""
  if have loginctl; then
    linger="$(loginctl show-user "$APP_USER" -p Linger 2>/dev/null | cut -d= -f2 || true)"
  fi

  if [[ "$linger" == "yes" ]]; then
    log "Lingering habilitado para ${APP_USER}."
  else
    warn "Lingering deshabilitado para ${APP_USER}; los servicios no arrancarán al reiniciar sin login."
    if confirm "¿Habilitar lingering ahora con sudo?"; then
      if sudo_cmd loginctl enable-linger "$APP_USER"; then
        linger="$(loginctl show-user "$APP_USER" -p Linger 2>/dev/null | cut -d= -f2 || true)"
      else
        warn "No se pudo habilitar lingering."
      fi
    fi
    if [[ "$linger" != "yes" ]]; then
      cat >&2 <<EOF
  Ejecuta como administrador:
    sudo loginctl enable-linger ${APP_USER}
  Verifica con:
    loginctl show-user ${APP_USER} -p Linger
EOF
    fi
  fi

  if have systemctl; then
    local user_state
    user_state="$(systemctl --user is-system-running 2>/dev/null || true)"
    if [[ "$user_state" == "running" ]]; then
      log "systemd --user está operativo."
    else
      warn "systemd --user estado: ${user_state:-desconocido}. Revisa: systemctl --user is-system-running"
    fi
    [[ -n "${XDG_RUNTIME_DIR:-}" && -d "${XDG_RUNTIME_DIR:-/nonexistent}" ]] \
      || warn "XDG_RUNTIME_DIR no está definido; las unidades de usuario necesitan una sesión systemd válida."
  fi
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes) ASSUME_YES=1 ;;
      --skip-system-packages) SKIP_SYSTEM_PACKAGES=1 ;;
      --skip-bot-api) SKIP_BOT_API=1 ;;
      --force-bot-api) FORCE_BOT_API=1 ;;
      --skip-model) SKIP_MODEL=1 ;;
      --allow-missing-cuda) ALLOW_MISSING_CUDA=1 ;;
      --configure) FORCE_CONFIGURE=1 ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; die "Opción desconocida: $1" ;;
    esac
    shift
  done

  assert_not_root
  assert_runtime_user
  ensure_base_dirs

  install_system_packages
  ensure_rust
  check_cuda
  ensure_mise
  ensure_env_file "$FORCE_CONFIGURE"
  check_env_permissions "$APP_ENV_FILE"
  check_env_permissions "$BOT_API_ENV_FILE"
  install_bot_api
  download_model
  download_vad_model
  check_linger

  cat >&2 <<EOF

Bootstrap completado.

Siguientes pasos:
  cd ${REPO_ROOT}
  ./deploy/deploy.sh
  ./deploy/verify.sh

Después envía una nota de voz al bot en un grupo autorizado y observa:
  journalctl --user -u ${APP_SERVICE} -f
EOF
}

main "$@"
