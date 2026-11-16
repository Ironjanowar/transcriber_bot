# Whisper transcriber

A single-shot CLI that reads a normalized 16 kHz mono 16-bit PCM WAV file and writes only the cleaned transcript to stdout. Model files are external and are never included in the binary.

## Build

CPU development build:

```sh
cargo build --release
```

Production NVIDIA build (requires the CUDA toolkit, including `nvcc`, plus CMake and a C/C++ toolchain):

```sh
cargo build --release --features cuda
```

The `cuda` crate feature forwards to `whisper-rs/cuda`; CUDA is not enabled for default local tests.

## Run

A compatible external whisper.cpp Silero VAD model is required; VAD cannot be disabled:

```sh
./target/release/transcriptor-whisper \
  --model /path/to/ggml-large-v3.bin \
  --vad-model /path/to/ggml-silero-v6.2.0.bin \
  --input /path/to/audio.wav
```

The transcriber uses automatic language selection (`language = None`) and transcription mode (translation disabled). It does not enable Whisper's detect-only `detect_language` mode.

Errors and whisper.cpp diagnostics go to stderr and return a nonzero exit status. Audio and transcript content are not logged.
