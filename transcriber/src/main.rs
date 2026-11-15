use anyhow::Result;
use clap::Parser;
use transcriptor_whisper::{Cli, transcribe};

fn main() -> Result<()> {
    let cli = Cli::parse();
    let transcript = transcribe(&cli)?;
    println!("{transcript}");
    Ok(())
}
