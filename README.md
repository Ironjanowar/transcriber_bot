# Transcriptor Bot

Bot de Telegram para transcribir audio con whisper.cpp y CUDA. La orquestación
está en Elixir/ExGram y la transcripción en un CLI Rust que se ejecuta como
proceso nuevo por cada audio.

La instalación de producción es un servicio `systemd --user` para la cuenta
`cuwano`, con un servidor local de Telegram Bot API en loopback y long polling.
No se expone ningún puerto entrante.

## Estado

Implementación inicial en desarrollo. Antes de desplegar, lee esta sección y
`deploy/README.md`; los assets de despliegue se validan con
`./deploy/check-assets.sh`.

## Requisitos del host

- Linux con `systemd` y una cuenta `cuwano` con `systemd --user`.
- GPU NVIDIA con driver y **CUDA Toolkit** (no solo el driver). `nvcc` debe
  estar en `PATH`, en `/usr/local/cuda/bin` o en `/opt/cuda/bin`.
- `ffmpeg` y `ffprobe`.
- Rust 1.85+ (el bootstrap instala 1.99.1 con rustup si falta) y `libclang`
  para `bindgen`.
- Acceso a Internet para descargar dependencias, el Bot API local y el modelo.
- Espacio libre: ~10 GB para el modelo, dependencias, compilaciones y el Bot API.
- `api_id` y `api_hash` de <https://my.telegram.org>.
- Token de BotFather y el modo privacidad desactivado para grupos.

El bootstrap instala las dependencias nativas con `sudo` en Debian/Ubuntu,
Fedora, Arch y openSUSE. No instala el driver NVIDIA ni el CUDA Toolkit: si
`nvcc` no existe, muestra las instrucciones y termina.

## Rutas de producción

| Qué | Ruta |
| --- | --- |
| Checkout y release | `/home/cuwano/apps/transcriptor_bot` |
| Release Mix | `/home/cuwano/apps/transcriptor_bot/_build/prod/rel/transcriptor_bot` |
| Lanzador estable de la release | `/home/cuwano/apps/transcriptor_bot/runtime/bin/start-transcriptor-bot` |
| CLI Rust instalado | `/home/cuwano/apps/transcriptor_bot/runtime/bin/transcriber` |
| Wrapper de transcripción | `/home/cuwano/apps/transcriptor_bot/runtime/bin/transcribe-audio` |
| Estado, SQLite, trabajo y modelo | `/home/cuwano/.local/share/transcriptor_bot` |
| SQLite | `/home/cuwano/.local/share/transcriptor_bot/transcriptor_bot.db` |
| Modelos | `/home/cuwano/.local/share/transcriptor_bot/models/ggml-large-v3.bin` y `ggml-silero-v6.2.0.bin` |
| Datos del Bot API local | `/home/cuwano/.local/share/transcriptor_bot/telegram-bot-api` |
| Entorno app | `/home/cuwano/.config/transcriptor_bot/app.env` (`0600`) |
| Entorno Bot API | `/home/cuwano/.config/transcriptor_bot/bot-api.env` (`0600`) |
| Unidades | `/home/cuwano/.config/systemd/user/*.service` |

`bootstrap.sh` crea los directorios con modo `0700`, los archivos privados con
`0600` y los modelos con `0600`. `deploy.sh` no escribe fuera de esas rutas.

## Primera instalación

Entra como `cuwano` y clona el repositorio exactamente en la ruta de la tabla:

```bash
sudo -iu cuwano
mkdir -p ~/apps
git clone --branch <rama> https://github.com/Ironjanowar/transcriptor_bot.git \
  ~/apps/transcriptor_bot
cd ~/apps/transcriptor_bot
```

Ejecuta el bootstrap una sola vez. Pedirá el token y las credenciales de
Telegram de forma oculta; no las imprime ni las escribe en el historial:

```bash
./deploy/bootstrap.sh
```

Qué hace:

1. Comprueba/instala `build-essential`, CMake, clang/libclang, OpenSSL, zlib,
   `gperf`, FFmpeg, `rsync`, `sqlite3`, `git`, `curl` y dependencias de Erlang.
   Instala Rust con rustup si no hay un toolchain utilizable.
2. Verifica `nvcc`, `nvidia-smi` y `/dev/nvidia0`; falla con instrucciones si
   falta CUDA.
3. Instala `mise` en `~/.local/bin` y Erlang/Elixir según `.tool-versions`.
4. Crea directorios y pide `BOT_TOKEN`, `TELEGRAM_API_ID` y
   `TELEGRAM_API_HASH`. El owner queda fijado en `14977303`.
5. Compila el servidor oficial `telegram-bot-api` si no hay uno disponible.
6. Descarga `ggml-large-v3.bin` F16 y Silero VAD v6.2.0 con tamaño y SHA-256 verificados.
7. Comprueba `loginctl` y ofrece habilitar lingering con `sudo`.

Antes de arrancar el Bot API local, el bot debe estar desconectado del Bot API
en la nube. Hazlo una vez, con el token fuera del historial:

```bash
read -rsp 'BOT_TOKEN: ' BOT_TOKEN; echo
printf 'url = "https://api.telegram.org/bot%s/logOut"\n' "$BOT_TOKEN" | curl --config -
unset BOT_TOKEN
```

Detén cualquier otra instancia del bot antes de este paso: dos pollers con el
mismo token se roban las actualizaciones y provocan errores de conflicto.

Después compila e instala la aplicación:

```bash
./deploy/deploy.sh
./deploy/verify.sh --checksum
./deploy/smoke-test.sh
```

## Despliegue rutinario

`deploy.sh` despliega **exactamente el checkout actual**. No ejecuta
`git pull`, no usa `sudo` y no hace rollback automático de la versión anterior.

```bash
cd ~/apps/transcriptor_bot
git fetch --all
git switch <rama>
# Revisa el commit que vas a desplegar; deploy.sh no actualiza el árbol.
git log -1 --oneline
./deploy/deploy.sh
```

Si lo ejecutas desde otro checkout, sincroniza ese árbol a
`/home/cuwano/apps/transcriptor_bot` con `rsync` (sin `.git`, `_build`, `deps`,
`target` ni `runtime`) y compila allí. La release se sustituye en sitio; si el
deploy falla, corrige el checkout y vuelve a ejecutarlo.

`deploy.sh`:

- valida secretos y permisos;
- compila el CLI Rust con la feature `cuda` y `--locked` si hay `Cargo.lock`;
- compila la release Elixir con `MIX_ENV=prod` y
  `mix compile --warnings-as-errors`;
- si el proyecto tiene Ecto ejecuta `ecto.create`/`ecto.migrate`; este proyecto
  usa Exqlite directamente y crea el esquema con `CREATE TABLE IF NOT EXISTS`
  al arrancar;
- instala las unidades y reinicia primero `telegram-bot-api.service` y después
  `transcriptor-bot.service`;
- guarda el commit desplegado en
  `~/.local/share/transcriptor_bot/deployed-revision`.

Opciones útiles:

```bash
./deploy/deploy.sh --build-only   # compila sin migrar ni reiniciar
./deploy/deploy.sh --skip-rust    # reutiliza el CLI ya instalado
./deploy/deploy.sh --skip-elixir  # reutiliza la release ya instalada
./deploy/deploy.sh --configure    # vuelve a pedir los secretos
```

## Contrato de entorno

`deploy.sh` regenera dos archivos aislados. La aplicación solo recibe
`~/.config/transcriptor_bot/app.env`:

```dotenv
BOT_TOKEN=<token de BotFather>
OWNER_TELEGRAM_USER_ID=14977303
DATABASE_PATH=/home/cuwano/.local/share/transcriptor_bot/transcriptor_bot.db
TRANSCRIBER_COMMAND=/home/cuwano/apps/transcriptor_bot/runtime/bin/transcribe-audio
WORK_DIR=/home/cuwano/.local/share/transcriptor_bot/work
TELEGRAM_API_BASE_URL=http://127.0.0.1:8081
```

El servidor oficial recibe únicamente `bot-api.env`, usando los nombres de
entorno soportados por upstream y sin credenciales en argv:

```dotenv
TELEGRAM_API_ID=<api_id numérico>
TELEGRAM_API_HASH=<api_hash hexadecimal de 32 caracteres>
```

`TRANSCRIBER_COMMAND` apunta a un wrapper generado por `deploy.sh`; la
aplicación le pasa la ruta PCM como único argumento y el wrapper ejecuta el CLI
Rust con `--model <modelo> --vad-model <silero> --input <pcm.wav>`. El owner es inmutable desde el
despliegue: `deploy.sh` rechaza cualquier otro valor.

## Servicios

```bash
systemctl --user status telegram-bot-api.service transcriptor-bot.service
systemctl --user restart telegram-bot-api.service
systemctl --user restart transcriptor-bot.service
journalctl --user -u transcriptor-bot.service -f
journalctl --user -u telegram-bot-api.service -n 100 --no-pager
```

El Bot API escucha solo en `127.0.0.1:8081`; la aplicación usa long polling y no
registra webhook. La unidad de la aplicación requiere la del Bot API, pero cada
una se supervisa por separado. Ambas tienen `Restart=on-failure` y escritura
limitada a `~/.local/share/transcriptor_bot`.

Para que los servicios sobrevivan al logout y arranquen al reiniciar:

```bash
loginctl show-user cuwano -p Linger
sudo loginctl enable-linger cuwano
```

## Verificación y smoke test

```bash
./deploy/verify.sh              # estado, permisos, GPU, Bot API, SQLite
./deploy/verify.sh --checksum   # además SHA-256 del modelo (lento)
./deploy/smoke-test.sh          # servicios, getMe, long polling, GPU, modelo
./deploy/smoke-test.sh --delete-webhook
./deploy/check-assets.sh        # bash -n, shellcheck, systemd-analyze, tests
```

`verify.sh` y `smoke-test.sh` no imprimen el token. No llaman a `getUpdates`
porque consumirían actualizaciones del bot en ejecución.

Prueba final real:

1. Añade el bot a un grupo; el owner `14977303` ejecuta `/allow` y `/enable`.
2. Envía una nota de voz o un audio.
3. Observa `journalctl --user -u transcriptor-bot.service -f`.
4. Comprueba que llega la transcripción y que no quedan audios temporales en
   `~/.local/share/transcriptor_bot/work`.

## Operación

```bash
# Estado del commit desplegado
cat ~/.local/share/transcriptor_bot/deployed-revision

# Backup consistente de SQLite (para el servicio antes)
systemctl --user stop transcriptor-bot.service
sqlite3 ~/.local/share/transcriptor_bot/transcriptor_bot.db \
  ".backup '$HOME/transcriptor_bot-$(date +%F).db'"
systemctl --user start transcriptor-bot.service

# Revalidar el modelo o reconstruir el Bot API
./deploy/bootstrap.sh --skip-bot-api
./deploy/bootstrap.sh --force-bot-api --skip-model
```

No copies `transcriptor_bot.db` con `cp` mientras el servicio está activo: WAL y
SHM pueden dejar el backup inconsistente. Usa `.backup` o detén el servicio.

## Actualizar y revertir

Para actualizar, cambia el checkout al commit deseado y ejecuta `deploy.sh`.
Para revertir, cambia manualmente al commit anterior y vuelve a desplegar; no
hay rollback automático ni se conservan releases antiguas:

```bash
cd ~/apps/transcriptor_bot
git switch --detach <commit-anterior>
./deploy/deploy.sh
```

## Problemas frecuentes

- **`nvcc` no encontrado**: instala el CUDA Toolkit (no solo el driver) y
  exporta `CUDA_HOME=/usr/local/cuda`; comprueba `nvcc --version`.
- **`nvidia-smi` falla o no hay `/dev/nvidia0`**: revisa el driver NVIDIA; en
  un contenedor hay que pasar la GPU al contenedor.
- **El Bot API no responde**: `journalctl --user -u telegram-bot-api.service`;
  confirma que el puerto 8081 está libre y que `api_id`/`api_hash` son válidos.
- **Conflicto de polling**: hay otra instancia usando el mismo token. Detén la
  otra instancia y reinicia el servicio.
- **Webhook registrado**: `./deploy/smoke-test.sh --delete-webhook`.
- **Error de escritura bajo `ProtectHome`**: revisa que
  `~/.local/share/transcriptor_bot` existe con modo `0700`; `deploy.sh` lo crea.
- **La release no arranca**: revisa `RELEASE_TMP`, el journal y que
  `runtime/bin/start-transcriptor-bot` apunte a una release existente.
- **Linger deshabilitado**: `sudo loginctl enable-linger cuwano`; sin esto los
  servicios no arrancan al reiniciar sin login.

## Seguridad

- No commitees `~/.config/transcriptor_bot/*.env`, tokens, modelos ni bases de
  datos; `.gitignore` cubre esos artefactos.
- El archivo de entorno debe ser `0600` y su directorio `0700`. Los scripts
  corrigen el modo y fallan si el propietario no es el usuario actual.
- El Bot API se enlaza solo a `127.0.0.1`; no abras el puerto 8081.
- Las unidades usan `NoNewPrivileges`, `PrivateTmp`, `ProtectSystem=strict`,
  `ProtectHome=read-only` y una lista explícita de rutas escribibles.
- No pegues el token en la línea de comandos: usa el prompt oculto de
  `bootstrap.sh`/`deploy.sh --configure` o el patrón `curl --config -`.

Documentación detallada de operación: [`deploy/README.md`](deploy/README.md).
