use anyhow::{Context, Result, bail};
use clap::Parser;
use hound::{SampleFormat, WavReader};
use std::path::{Path, PathBuf};
use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters};

/// Transcribe a normalized 16 kHz mono PCM WAV file with whisper.cpp.
#[derive(Debug, Parser, PartialEq, Eq)]
#[command(version, about)]
pub struct Cli {
    /// Path to an external whisper.cpp GGML model (for example large-v3 F16).
    #[arg(long, value_name = "FILE")]
    pub model: PathBuf,

    /// Path to a 16 kHz mono 16-bit PCM WAV file.
    #[arg(long, value_name = "FILE")]
    pub input: PathBuf,

    /// Path to a compatible whisper.cpp Silero VAD model. VAD is always enabled.
    #[arg(long, value_name = "FILE")]
    pub vad_model: PathBuf,
}

pub fn clean_transcript<'a>(segments: impl IntoIterator<Item = &'a str>) -> String {
    segments
        .into_iter()
        .flat_map(str::split_whitespace)
        .collect::<Vec<_>>()
        .join(" ")
}

pub fn read_pcm_wav(path: &Path) -> Result<Vec<f32>> {
    let mut reader = WavReader::open(path)
        .with_context(|| format!("failed to open WAV file {}", path.display()))?;
    let spec = reader.spec();

    if spec.channels != 1 {
        bail!("input WAV must be mono (found {} channels)", spec.channels);
    }
    if spec.sample_rate != 16_000 {
        bail!(
            "input WAV must have a 16 kHz sample rate (found {} Hz)",
            spec.sample_rate
        );
    }
    if spec.sample_format != SampleFormat::Int || spec.bits_per_sample != 16 {
        bail!(
            "input WAV must contain 16-bit integer PCM (found {:?}, {} bits)",
            spec.sample_format,
            spec.bits_per_sample
        );
    }

    reader
        .samples::<i16>()
        .map(|sample| {
            sample
                .context("failed to decode PCM sample")
                .map(|value| f32::from(value) / 32_768.0)
        })
        .collect()
}

fn transcription_params(vad_model: &Path, threads: i32) -> FullParams<'static, 'static> {
    let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
    params.set_n_threads(threads);
    params.set_translate(false);
    params.set_language(None);
    params.set_no_timestamps(true);
    params.set_print_special(false);
    params.set_print_progress(false);
    params.set_print_realtime(false);
    params.set_print_timestamps(false);
    params.set_vad_model_path(Some(vad_model.to_string_lossy().as_ref()));
    params.enable_vad(true);
    params
}

pub fn transcribe(cli: &Cli) -> Result<String> {
    let samples = read_pcm_wav(&cli.input)?;
    let context = WhisperContext::new_with_params(&cli.model, WhisperContextParameters::default())
        .with_context(|| format!("failed to load Whisper model {}", cli.model.display()))?;
    let mut state = context
        .create_state()
        .context("failed to create Whisper state")?;

    let threads = std::thread::available_parallelism()
        .map(|count| count.get())
        .unwrap_or(1)
        .min(i32::MAX as usize) as i32;
    let params = transcription_params(&cli.vad_model, threads);

    state
        .full(params, &samples)
        .context("Whisper transcription failed")?;

    let segments = state
        .as_iter()
        .map(|segment| segment.to_str().context("Whisper returned invalid text"))
        .collect::<Result<Vec<_>>>()?;
    Ok(clean_transcript(segments))
}

#[cfg(test)]
mod tests {
    use super::{Cli, clean_transcript, read_pcm_wav, transcription_params};
    use clap::Parser;
    use hound::{SampleFormat, WavSpec, WavWriter};
    use std::fs;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicUsize, Ordering};

    static NEXT_WAV: AtomicUsize = AtomicUsize::new(0);

    fn write_wav(spec: WavSpec, samples: &[i16]) -> PathBuf {
        let id = NEXT_WAV.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "transcriptor-whisper-{}-{id}.wav",
            std::process::id()
        ));
        let mut writer = WavWriter::create(&path, spec).expect("create test WAV");
        for sample in samples {
            writer.write_sample(*sample).expect("write test sample");
        }
        writer.finalize().expect("finalize test WAV");
        path
    }

    #[test]
    fn rejects_a_missing_vad_model_path_argument() {
        let error = Cli::try_parse_from([
            "transcriptor-whisper",
            "--model",
            "/models/ggml-large-v3.bin",
            "--input",
            "/tmp/audio.wav",
        ])
        .expect_err("VAD model must be required");

        assert!(error.to_string().contains("--vad-model"));
    }

    #[test]
    fn rejects_a_missing_model_path_argument() {
        let error = Cli::try_parse_from(["transcriptor-whisper", "--input", "/tmp/audio.wav"])
            .expect_err("model must be required");

        assert!(error.to_string().contains("--model"));
    }

    #[test]
    fn parses_a_required_vad_model_path() {
        let cli = Cli::try_parse_from([
            "transcriptor-whisper",
            "--model",
            "/models/ggml-large-v3.bin",
            "--input",
            "/tmp/audio.wav",
            "--vad-model",
            "/models/ggml-silero-v6.2.0.bin",
        ])
        .expect("valid arguments");

        assert_eq!(
            cli.vad_model,
            PathBuf::from("/models/ggml-silero-v6.2.0.bin")
        );
    }

    #[test]
    fn configures_automatic_transcription_without_translation_and_with_vad() {
        let vad_model = PathBuf::from("/models/ggml-silero-v6.2.0.bin");
        let params = transcription_params(&vad_model, 4);
        let debug = format!("{params:?}");

        assert!(debug.contains("language: 0x0"), "{debug}");
        assert!(debug.contains("detect_language: false"), "{debug}");
        assert!(debug.contains("translate: false"), "{debug}");
        assert!(debug.contains("vad: true"), "{debug}");
        assert!(!debug.contains("vad_model_path: 0x0"), "{debug}");
    }

    #[test]
    fn cleans_segment_whitespace_without_adding_metadata() {
        let transcript = clean_transcript(["  Hello,   world. ", "\nThis is\tWhisper.  ", "   "]);

        assert_eq!(transcript, "Hello, world. This is Whisper.");
    }

    #[test]
    fn reads_mono_16_khz_16_bit_pcm_as_normalized_floats() {
        let path = write_wav(
            WavSpec {
                channels: 1,
                sample_rate: 16_000,
                bits_per_sample: 16,
                sample_format: SampleFormat::Int,
            },
            &[-32_768, 0, 16_384, 32_767],
        );

        let samples = read_pcm_wav(&path).expect("valid normalized WAV");
        fs::remove_file(path).expect("remove test WAV");

        assert_eq!(samples, vec![-1.0, 0.0, 0.5, 32_767.0 / 32_768.0]);
    }

    #[test]
    fn rejects_wav_with_wrong_sample_rate() {
        let path = write_wav(
            WavSpec {
                channels: 1,
                sample_rate: 44_100,
                bits_per_sample: 16,
                sample_format: SampleFormat::Int,
            },
            &[0],
        );

        let error = read_pcm_wav(&path).expect_err("44.1 kHz must be rejected");
        fs::remove_file(path).expect("remove test WAV");

        assert!(error.to_string().contains("16 kHz"));
    }

    #[test]
    fn rejects_stereo_wav() {
        let path = write_wav(
            WavSpec {
                channels: 2,
                sample_rate: 16_000,
                bits_per_sample: 16,
                sample_format: SampleFormat::Int,
            },
            &[0, 0],
        );

        let error = read_pcm_wav(&path).expect_err("stereo must be rejected");
        fs::remove_file(path).expect("remove test WAV");

        assert!(error.to_string().contains("mono"));
    }

    #[test]
    fn empty_segments_produce_an_empty_transcript() {
        assert_eq!(clean_transcript([" ", "\n\t"]), "");
    }
}
