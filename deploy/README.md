# Despliegue de transcriptor_bot

Esta guía describe la instalación de producción en la cuenta `cuwano`, con
`systemd --user`, un servidor local de Telegram Bot API en loopback y long
polling. El objetivo es que el bot no exponga puertos entrantes y que todo el
estado persistente viva fuera del checkout.

## Arquitectura

```
Telegram  <-- long polling -->  telegram-bot-api.service (127.0.0.1:8081)
                                        ^
                                        | HTTP local
                                        |
                              transcriptor-bot.service (Elixir/ExGram)
                                        |
                                        | proceso nuevo por audio
                                        v
                              runtime/bin/transcriber (Rust + CUDA)
                                        |
                                        v
                              ffmpeg -> PCM 16 kHz -> whisper.cpp
```

Dos unidades independientes:

- `telegram-bot-api.service`: servidor oficial `telegram-bot-api` en modo
  `--local`, escuchando solo en `127.0.0.1:8081`.
- `transcriptor-bot.service`: release Elixir; requiere el Bot API y se reinicia
  si falla. Usa long polling; no se registra webhook.

## Rutas

| Ruta | Contenido | Modo |
| --- | --- | --- |
| `/home/cuwano/apps/transcriptor_bot` | checkout, `_build`, `runtime` | `0755` |
| `.../runtime/bin/transcriber` | CLI Rust instalado por `deploy.sh` | `0755` |
| `.../runtime/bin/transcribe-audio` | wrapper que fija modelo y entrada PCM | `0755` |
| `.../runtime/bin/start-transcriptor-bot` | lanzador generado hacia la release | `0755` |
| `/home/cuwano/.local/share/transcriptor_bot` | estado | `0700` |
| `.../transcriptor_bot.db` | SQLite (WAL) | `0600` |
| `.../models/ggml-large-v3.bin` | modelo F16 | `0600` |
| `.../models/ggml-silero-v6.2.0.bin` | modelo VAD | `0600` |
| `.../work` | PCM/audio temporal | `0700` |
| `.../telegram-bot-api` | datos del Bot API local | `0700` |
| `/home/cuwano/.config/transcriptor_bot/app.env` | token y configuración de la app | `0600` |
| `/home/cuwano/.config/transcriptor_bot/bot-api.env` | API ID/hash del Bot API | `0600` |
| `/home/cuwano/.config/systemd/user/*.service` | unidades | `0644` |

El lanzador estable evita que la unidad dependa del nombre exacto que Mix
genere para la release. `deploy.sh` lo reescribe en cada despliegue.

## Requisitos

- Cuenta `cuwano` con `systemd --user` y lingering.
- Driver NVIDIA + CUDA Toolkit; `nvcc` visible.
- `ffmpeg`/`ffprobe`.
- Rust 1.85+ y `libclang` (el bootstrap instala Rust 1.99.1 con rustup y
  `clang`/`libclang` con el gestor de paquetes si faltan).
- `api_id`/`api_hash` de <https://my.telegram.org>.
- Token de BotFather; modo privacidad desactivado si se usa en grupos.
- ~10 GB libres para dependencias, compilación, Bot API y modelo.

`bootstrap.sh` instala paquetes nativos con `sudo` en Debian/Ubuntu, Fedora,
Arch y openSUSE. No instala drivers ni CUDA Toolkit.

## Instalación inicial

```bash
sudo -iu cuwano
mkdir -p ~/apps
git clone --branch <rama> https://github.com/Ironjanowar/transcriptor_bot.git \
  ~/apps/transcriptor_bot
cd ~/apps/transcriptor_bot
./deploy/bootstrap.sh
```

`bootstrap.sh` es idempotente y se puede repetir. Opciones:

| Opción | Efecto |
| --- | --- |
| `--yes` | No confirmar instalación de paquetes ni lingering. |
| `--skip-system-packages` | Solo comprobar dependencias; no usar `sudo`. |
| `--skip-bot-api` | No compilar el Bot API. |
| `--force-bot-api` | Recompilar aunque exista el binario. |
| `--skip-model` | No descargar el modelo. |
| `--allow-missing-cuda` | Continuar sin `nvcc`; el build Rust fallará después. |
| `--configure` | Volver a pedir los secretos. |

Durante el bootstrap se piden `BOT_TOKEN`, `TELEGRAM_API_ID` y
`TELEGRAM_API_HASH` con entrada oculta. También se puede pasar cada valor por
variable de entorno para una instalación no interactiva; nunca se escribe en
el historial ni se imprime.

### Bot API local

El bootstrap compila su propio `telegram-bot-api` desde
`tdlib/telegram-bot-api` en `~/.local/src/telegram-bot-api`, fija el commit
`TELEGRAM_BOT_API_REF` (un commit completo de 40 caracteres), descarga ese
objeto exacto, verifica el hash sin fallback a una rama y compila con CMake en
`~/.local`. El binario queda en `~/.local/bin/telegram-bot-api`.

Antes de usar el servidor local, el bot debe estar desconectado del Bot API en
la nube. Hazlo una sola vez, sin dejar el token en el historial:

```bash
read -rsp 'BOT_TOKEN: ' BOT_TOKEN; echo
printf 'url = "https://api.telegram.org/bot%s/logOut"\n' "$BOT_TOKEN" | curl --config -
unset BOT_TOKEN
```

Detén cualquier otra instancia del bot antes de este paso. Dos pollers con el
mismo token compiten por las actualizaciones.

### Modelo

`bootstrap.sh` descarga `ggml-large-v3.bin` F16 desde
`ggerganov/whisper.cpp` y verifica:

- tamaño exacto: `3095033483` bytes;
- SHA-256: `64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2`.

Si existe un archivo parcial (`.part`), reanuda. Si el archivo final no coincide,
lo conserva como `.corrupt.<epoch>` y vuelve a descargar. Una segunda ejecución
con el modelo correcto no descarga nada.

También descarga Silero VAD v6.2.0 (`885098` bytes, SHA-256
`2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987`).
El despliegue verifica tamaño y SHA-256 de ambos modelos antes de instalar o
arrancar servicios.

### Lingering

Sin lingering, `systemd --user` no arranca los servicios al reiniciar sin una
sesión abierta:

```bash
loginctl show-user cuwano -p Linger
sudo loginctl enable-linger cuwano
```

El bootstrap lo comprueba y ofrece habilitarlo con `sudo`.

## Despliegue

```bash
cd ~/apps/transcriptor_bot
git fetch --all
git switch <rama>
git log -1 --oneline
./deploy/deploy.sh
```

`deploy.sh` no ejecuta `git pull` y no usa `sudo`. Despliega exactamente el
checkout desde el que se invoca. Si se invoca desde otro directorio, sincroniza
el árbol a `/home/cuwano/apps/transcriptor_bot` con `rsync`, excluyendo `.git`,
`_build`, `deps`, `transcriber/target` y `runtime` (los artefactos generados se
conservan y se sustituyen de forma controlada).

Pasos internos:

1. Valida el archivo de secretos y su modo.
2. Compila el CLI Rust en `transcriber/` con `cargo build --release`, `--locked`
   si hay `Cargo.lock` y `--features cuda` cuando la feature existe. Instala el
   binario como `runtime/bin/transcriber`.
3. Compila la release Elixir con `MIX_ENV=prod` y
   `mix compile --warnings-as-errors`; ejecuta `mix release --overwrite`.
4. Si el proyecto tiene tareas Ecto, ejecuta `ecto.create`/`ecto.migrate`. En
   este proyecto el esquema SQLite lo crea `TranscriptorBot.Store` con
   `CREATE TABLE IF NOT EXISTS` al arrancar; el deploy lo registra y no inventa
   migraciones.
5. Instala las unidades en `~/.config/systemd/user`, hace `daemon-reload` y
   habilita ambos servicios.
6. Reinicia primero el Bot API, espera a que `getMe` responda y después la
   aplicación. Si algo falla, muestra el journal y no hace rollback de versión.

Opciones:

```bash
./deploy/deploy.sh --build-only
./deploy/deploy.sh --skip-rust
./deploy/deploy.sh --skip-elixir
./deploy/deploy.sh --configure
```

`--build-only` compila y actualiza artefactos, pero no migra, no instala
unidades ni reinicia. Es útil para preparar una máquina antes de una ventana de
mantenimiento. Tampoco actualiza `deployed-revision`.

## Contrato de entorno

`deploy.sh` regenera dos archivos `0600`. `app.env`, visible solo para la
aplicación, contiene:

```dotenv
BOT_TOKEN=...
OWNER_TELEGRAM_USER_ID=14977303
DATABASE_PATH=/home/cuwano/.local/share/transcriptor_bot/transcriptor_bot.db
TRANSCRIBER_COMMAND=/home/cuwano/apps/transcriptor_bot/runtime/bin/transcribe-audio
WORK_DIR=/home/cuwano/.local/share/transcriptor_bot/work
TELEGRAM_API_BASE_URL=http://127.0.0.1:8081
```

`bot-api.env`, visible solo para el servidor local, contiene exclusivamente:

```dotenv
TELEGRAM_API_ID=...
TELEGRAM_API_HASH=...
```

Son los nombres de entorno soportados por upstream; las credenciales no se
incluyen en `ExecStart` ni aparecen en argv.

`Transcriber` ejecuta `TRANSCRIBER_COMMAND` con la ruta PCM como único
argumento. El wrapper generado ejecuta:

```
transcriber --model .../ggml-large-v3.bin --vad-model .../ggml-silero-v6.2.0.bin --input /ruta/audio.wav
```

El owner está fijado en `14977303`; `deploy.sh` rechaza otro valor. El token se
lee del archivo, nunca de la línea de comandos.

## Verificación

```bash
./deploy/verify.sh
./deploy/verify.sh --checksum
./deploy/smoke-test.sh
./deploy/check-assets.sh
```

- `verify.sh`: unidades habilitadas/activas, lingering, modos `0700`/`0600`,
  binarios, release, tamaño/SHA del modelo, `ffmpeg`, `nvidia-smi`, `getMe`,
  `getWebhookInfo`, binding de loopback e integridad de SQLite.
- `smoke-test.sh`: servicios, Bot API, ausencia de webhook, puerto, modelo, GPU,
  SQLite y reinicios. No llama a `getUpdates` para no consumir actualizaciones.
- `check-assets.sh`: `bash -n` de todos los scripts, `shellcheck` si está
  instalado, `systemd-analyze verify` en un `$HOME` falso y tests de shell.

Prueba de extremo a extremo manual:

1. Añade el bot a un grupo.
2. Como owner `14977303`, ejecuta `/allow` y `/enable`.
3. Envía una nota de voz.
4. `journalctl --user -u transcriptor-bot.service -f`.
5. Verifica la transcripción y que `work/` queda vacío.

## Operación

```bash
systemctl --user status telegram-bot-api.service transcriptor-bot.service
systemctl --user restart telegram-bot-api.service
systemctl --user restart transcriptor-bot.service
journalctl --user -u transcriptor-bot.service -f
journalctl --user -u telegram-bot-api.service -n 100 --no-pager
cat ~/.local/share/transcriptor_bot/deployed-revision
```

### Backup de SQLite

Detén la aplicación para que WAL y SHM no queden fuera del backup:

```bash
systemctl --user stop transcriptor-bot.service
mkdir -p ~/backups
sqlite3 ~/.local/share/transcriptor_bot/transcriptor_bot.db \
  ".backup '$HOME/backups/transcriptor_bot-$(date +%F-%H%M).db'"
systemctl --user start transcriptor-bot.service
```

No uses `cp` con el servicio activo.

### Modelo

```bash
./deploy/bootstrap.sh --skip-bot-api   # verifica y descarga si falta
ls -lh ~/.local/share/transcriptor_bot/models/ggml-large-v3.bin
```

### Bot API

```bash
./deploy/bootstrap.sh --force-bot-api --skip-model
~/.local/bin/telegram-bot-api --version
```

## Actualización y reversión

Actualizar es cambiar el checkout y desplegar:

```bash
cd ~/apps/transcriptor_bot
git fetch --all
git switch <rama>
git log -1 --oneline
./deploy/deploy.sh
```

Revertir es manual: cambia al commit anterior y vuelve a desplegar. No se
conservan releases antiguas ni se restaura automáticamente la versión previa.

```bash
git switch --detach <commit-anterior>
./deploy/deploy.sh
```

## Endurecimiento de las unidades

Ambas unidades usan:

- `NoNewPrivileges=yes`, `PrivateTmp=yes`, `ProtectSystem=strict`,
  `ProtectHome=read-only`, `ProtectKernelTunables=yes`,
  `ProtectKernelModules=yes`, `ProtectControlGroups=yes`,
  `RestrictSUIDSGID=yes`, `LockPersonality=yes`, `UMask=0077`.
- `ReadWritePaths=` limitado a `~/.local/share/transcriptor_bot` (o a su
  subdirectorio del Bot API).
- `Restart=on-failure`, `RestartSec` acotado, `StartLimitBurst=5` y
  `TimeoutStopSec`.

La unidad de la aplicación **no** usa `PrivateDevices`: CUDA necesita
`/dev/nvidia*`. La del Bot API sí lo usa. `RELEASE_TMP=%t/transcriptor-bot` da a
la release un directorio de runtime escribible aunque `ProtectHome=read-only`
haga el resto de `$HOME` de solo lectura. La caché de CUDA y la de Erlang se
redirigen a `~/.local/share/transcriptor_bot`.

No añadas `ProtectHome=strict` sin revisar `EnvironmentFile`, el binario y la
release: rompería el arranque.

## Diagnóstico

```bash
systemctl --user is-active telegram-bot-api.service transcriptor-bot.service
systemctl --user show -p NRestarts --value transcriptor-bot.service
journalctl --user -u transcriptor-bot.service -p warning -n 50 --no-pager
ss -ltnp | grep 8081
stat -c '%a %U %n' ~/.config/transcriptor_bot/app.env ~/.config/transcriptor_bot/bot-api.env \
  ~/.local/share/transcriptor_bot ~/.local/share/transcriptor_bot/models/ggml-large-v3.bin
```

Comprobaciones concretas:

- **Bot API no arranca**: `--api-id`/`--api-hash` inválidos, puerto ocupado o
  `~/.local/bin/telegram-bot-api` ausente. El journal lo indica.
- **`getMe` falla**: token inválido o Bot API caído. No pegues el token en
  `curl`; usa `./deploy/smoke-test.sh`.
- **Conflicto de polling**: otra instancia con el mismo token. Detén la otra y
  reinicia.
- **Webhook**: `./deploy/smoke-test.sh --delete-webhook` y reinicia la app.
- **Error de escritura**: revisa que el directorio de estado exista y sea
  `0700`; `ProtectHome=read-only` solo permite escribir en `ReadWritePaths`.
- **CUDA**: `nvcc --version`, `nvidia-smi`, `CUDA_HOME`, y que el build se haya
  hecho con `--features cuda`; el CLI sin CUDA puede compilar y fallar en
  runtime.
- **Linger**: `loginctl show-user cuwano -p Linger` debe ser `yes`.

## Seguridad

- No commitees los archivos `*.env`, tokens, bases SQLite, modelos ni logs.
- Mantén `~/.config/transcriptor_bot` en `0700` y ambos entornos en `0600`.
- El Bot API solo escucha en loopback. No publiques el puerto 8081.
- El owner es fijo; para cambiarlo hace falta editar el código y el contrato de
  despliegue, no solo el archivo de entorno.
- Los scripts evitan `source` del archivo de secretos: lo parsean como
  `KEY=value` para que una sustitución de comandos maliciosa no se ejecute.
- `verify.sh` y `smoke-test.sh` usan `curl --config -` para que el token no
  aparezca en `ps`.
