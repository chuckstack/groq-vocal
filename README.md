# groq-whisper.sh

Record audio and transcribe via Groq's Whisper API.

## Quick Start

```bash
./groq-whisper.sh
# Speak... recording stops after 3 seconds of silence
# Transcription prints to stdout
```

## Requirements

- `sox` - audio recording (`apt install sox libsox-fmt-mp3`)
- `curl` - API calls
- Groq API key

## Configuration

Create `~/.config/groq/whisper.conf`:

```ini
# Required
api_key = your-groq-api-key

# Optional
mic = alsa_input.usb-Blue_Microphones_Yeti_X-...
duration = 30
silence_duration = 3.0
silence_threshold = 0.2
start_prompt = 🎙️
model = whisper-large-v3-turbo
language = en
```

Set permissions: `chmod 600 ~/.config/groq/whisper.conf`

## Installation

Create a symlink to make it available in your PATH:

```bash
./groq-whisper.sh --install              # Installs to ~/.local/bin
./groq-whisper.sh --install /usr/local/bin  # Custom location
```

Then run from anywhere: `groq-whisper`

## Options

```
--file, -f <file>     Transcribe existing audio file
--mic, -m <device>    Use specific microphone
--duration, -d <sec>  Max recording duration (default: 30)
--verbose, -v         Show progress messages
--list-mics           List available microphones
--install [dir]       Create symlink (default: ~/.local/bin)
--help, -h            Show help
```

## Examples

```bash
# Record and transcribe
./groq-whisper.sh

# Transcribe existing file
./groq-whisper.sh --file recording.wav

# Quick 10-second max recording
./groq-whisper.sh -d 10

# List available microphones
./groq-whisper.sh --list-mics

# Debug mode
./groq-whisper.sh -v
```

## Neovim Integration

After installing, insert transcription at cursor:

```vim
:r !groq-whisper
```

Or add a keybinding in your config:

```lua
vim.keymap.set('n', '<leader>w', ':r !groq-whisper<CR>')
```

## How It Works

1. Records audio via sox (mono, 16kHz - optimal for Whisper)
2. Stops on silence detection or max duration
3. Sends audio to Groq's Whisper API
4. Returns transcription to stdout

## Configuration Options

| Option | Default | Description |
|--------|---------|-------------|
| `api_key` | - | Groq API key (required) |
| `mic` | system default | PulseAudio/PipeWire source name |
| `duration` | 30 | Max recording seconds |
| `silence_duration` | 3.0 | Seconds of silence before auto-stop |
| `silence_threshold` | 0.1 | Silence detection sensitivity (lower = more sensitive) |
| `start_prompt` | 🎙️ | Shown when recording starts |
| `model` | whisper-large-v3-turbo | Whisper model to use |
| `language` | en | ISO-639-1 language code |
