#!/usr/bin/env bash
#
# groq-whisper.sh - Record audio and transcribe via Groq Whisper API
#
# Usage:
#   groq-whisper.sh              # Record until Ctrl+C, transcribe, print result
#   groq-whisper.sh --file x.wav # Transcribe existing file
#   groq-whisper.sh --list-mics  # List available microphones
#   groq-whisper.sh --mic "alsa_input.usb-Blue_Microphones..."  # Use specific mic
#
# Requires:
#   - sox (apt install sox libsox-fmt-mp3)
#   - curl
#   - GROQ_API_KEY environment variable

set -euo pipefail

# Configuration defaults
MODEL="whisper-large-v3-turbo"
LANGUAGE="en"
TEMP_DIR="${TMPDIR:-/tmp}"
AUDIO_FILE="${TEMP_DIR}/groq-whisper-$$.wav"
MIC_DEVICE=""
GROQ_API_KEY="${GROQ_API_KEY:-}"
MAX_DURATION="60"
SILENCE_DURATION="3.0"      # Seconds of silence before auto-stop
SILENCE_THRESHOLD="0.2"     # Percentage threshold for silence detection
START_PROMPT="🎙️"           # Shown when recording starts
VERBOSE=false

CONFIG_FILE="${HOME}/.config/groq/whisper.conf"

# Load config file if it exists
if [[ -f "$CONFIG_FILE" ]]; then
    while IFS='=' read -r key value; do
        # Skip comments and empty lines
        [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
        # Trim whitespace
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)
        case "$key" in
            api_key)           GROQ_API_KEY="$value" ;;
            mic)               MIC_DEVICE="$value" ;;
            duration)          MAX_DURATION="$value" ;;
            silence_duration)  SILENCE_DURATION="$value" ;;
            silence_threshold) SILENCE_THRESHOLD="$value" ;;
            start_prompt)      START_PROMPT="$value" ;;
            model)             MODEL="$value" ;;
            language)          LANGUAGE="$value" ;;
        esac
    done < "$CONFIG_FILE"
fi

export GROQ_API_KEY

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

cleanup() {
    [[ -f "$AUDIO_FILE" ]] && rm -f "$AUDIO_FILE"
}
trap cleanup EXIT

log() {
    [[ "$VERBOSE" == true ]] && echo -e "${GREEN}[groq-whisper]${NC} $*" >&2
    return 0
}

error() {
    echo -e "${RED}[error]${NC} $*" >&2
    exit 1
}

check_deps() {
    log "Checking dependencies..."
    command -v sox >/dev/null 2>&1 || error "sox not found. Install: apt install sox libsox-fmt-mp3"
    command -v curl >/dev/null 2>&1 || error "curl not found"
    if [[ -z "${GROQ_API_KEY:-}" ]]; then
        error "GROQ_API_KEY environment variable not set"
    fi
    log "Dependencies OK"
}

list_mics() {
    log "Available microphones (PulseAudio/PipeWire):"
    echo ""
    if command -v pactl >/dev/null 2>&1; then
        pactl list sources short | grep -v '\.monitor' | while read -r id name rest; do
            echo "  $name"
        done
    else
        error "pactl not found - cannot list microphones"
    fi
    echo ""
    log "Set mic with: --mic <name> or export GROQ_WHISPER_MIC=<name>"
}

find_best_path() {
    # Check common bin directories in order of preference
    # User-writable first, then system directories
    local candidates=(
        "$HOME/.local/bin"
        "$HOME/bin"
        "$HOME/.bin"
        "/usr/local/bin"
    )

    for dir in "${candidates[@]}"; do
        if [[ ":$PATH:" == *":$dir:"* ]]; then
            echo "$dir"
            return 0
        fi
    done

    # None in PATH, return default
    echo "$HOME/.local/bin"
    return 1
}

install_symlink() {
    local install_dir="$1"
    local script_path
    script_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    local use_sudo=false

    # Auto-detect best path if not specified
    if [[ -z "$install_dir" ]]; then
        install_dir=$(find_best_path)
        if [[ $? -eq 0 ]]; then
            echo "Found $install_dir in PATH"
        else
            echo "No common bin directory in PATH, using $install_dir"
        fi
    fi

    local link_path="${install_dir}/groq-whisper"

    # Check if we need sudo
    if [[ -d "$install_dir" && ! -w "$install_dir" ]]; then
        echo "Note: $install_dir requires sudo"
        use_sudo=true
    elif [[ ! -d "$install_dir" && ! -w "$(dirname "$install_dir")" ]]; then
        echo "Note: Creating $install_dir requires sudo"
        use_sudo=true
    fi

    # Create directory if needed
    if [[ ! -d "$install_dir" ]]; then
        echo "Creating $install_dir..."
        if [[ "$use_sudo" == true ]]; then
            sudo mkdir -p "$install_dir"
        else
            mkdir -p "$install_dir"
        fi
    fi

    # Check if already exists
    if [[ -L "$link_path" ]]; then
        echo "Updating existing symlink..."
        if [[ "$use_sudo" == true ]]; then
            sudo rm "$link_path"
        else
            rm "$link_path"
        fi
    elif [[ -e "$link_path" ]]; then
        error "$link_path already exists and is not a symlink"
    fi

    if [[ "$use_sudo" == true ]]; then
        sudo ln -s "$script_path" "$link_path"
    else
        ln -s "$script_path" "$link_path"
    fi
    echo "Created symlink: $link_path -> $script_path"

    # Check if in PATH
    if [[ ":$PATH:" != *":$install_dir:"* ]]; then
        echo ""
        echo "Note: $install_dir is not in your PATH."
        echo "Add to your shell config:"
        echo "  export PATH=\"$install_dir:\$PATH\""
    else
        echo ""
        echo "You can now run: groq-whisper"
    fi
}

record_audio() {
    local output_file="$1"

    # Set up PulseAudio source if mic specified
    if [[ -n "$MIC_DEVICE" ]]; then
        log "Using microphone: $MIC_DEVICE"
        pactl set-default-source "$MIC_DEVICE" 2>/dev/null || \
            error "Failed to set microphone: $MIC_DEVICE"
    fi

    # Tell sox to use pulseaudio
    export AUDIODEV="default"

    log "Recording for up to ${MAX_DURATION}s (stops on ${SILENCE_DURATION}s silence)..."

    # Record mono 16kHz audio (optimal for Whisper)
    # Use timeout for max duration, silence effect for auto-stop
    # silence params:
    #   "1 0.3 $threshold" = wait for sound above threshold for 0.3s before starting
    #   "1 $duration $threshold" = stop after duration seconds of silence below threshold
    set +e  # Don't exit on error (timeout/Ctrl+C causes non-zero exit)
    timeout "$MAX_DURATION" rec -q -c 1 -r 16000 -t wav "$output_file" \
        silence 1 0.3 "${SILENCE_THRESHOLD}%" \
        1 "$SILENCE_DURATION" "${SILENCE_THRESHOLD}%" 2>/dev/null &
    local rec_pid=$!

    # Wait for sox to initialize and create the file
    while [[ ! -f "$output_file" ]] && kill -0 "$rec_pid" 2>/dev/null; do
        sleep 0.05
    done

    # Show start prompt once sox is ready
    echo -e "$START_PROMPT" >&2

    # Wait for recording to finish
    wait "$rec_pid" 2>/dev/null || true
    set -e

    # Check if we got audio
    if [[ ! -f "$output_file" ]]; then
        error "No audio file created. Check your microphone."
    fi

    if [[ ! -s "$output_file" ]]; then
        error "Audio file is empty. Try: --list-mics to check available devices"
    fi

    log "Recording saved ($(du -h "$output_file" | cut -f1))"
}

transcribe() {
    local audio_file="$1"

    [[ ! -f "$audio_file" ]] && error "Audio file not found: $audio_file"

    log "Transcribing via Groq ($MODEL)..."

    local response
    response=$(curl -s -X POST "https://api.groq.com/openai/v1/audio/transcriptions" \
        -H "Authorization: Bearer ${GROQ_API_KEY}" \
        -F "file=@${audio_file}" \
        -F "model=${MODEL}" \
        -F "language=${LANGUAGE}" \
        -F "response_format=json")

    # Check for errors
    if echo "$response" | grep -q '"error"'; then
        local err_msg
        err_msg=$(echo "$response" | grep -o '"message":"[^"]*"' | cut -d'"' -f4)
        error "API error: ${err_msg:-$response}"
    fi

    # Extract text from response
    local text
    text=$(echo "$response" | grep -o '"text":"[^"]*"' | cut -d'"' -f4)

    if [[ -z "$text" ]]; then
        error "No transcription returned. Response: $response"
    fi

    echo "$text"
}

main() {
    local input_file=""

    # Parse arguments first (some don't need deps)
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --file|-f)
                input_file="$2"
                shift 2
                ;;
            --mic|-m)
                MIC_DEVICE="$2"
                shift 2
                ;;
            --duration|-d)
                MAX_DURATION="$2"
                shift 2
                ;;
            --verbose|-v)
                VERBOSE=true
                shift
                ;;
            --list-mics)
                list_mics
                exit 0
                ;;
            --install)
                install_symlink "${2:-}"
                exit 0
                ;;
            --help|-h)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Record audio and transcribe via Groq Whisper API."
                echo "Stops on 3s silence or max duration (default 30s)."
                echo ""
                echo "Options:"
                echo "  --file, -f <file>     Transcribe existing audio file"
                echo "  --mic, -m <device>    Use specific microphone (see --list-mics)"
                echo "  --duration, -d <sec>  Max recording duration (default: 30)"
                echo "  --verbose, -v         Show progress messages"
                echo "  --list-mics           List available microphones"
                echo "  --install [dir]       Create symlink (default: ~/.local/bin)"
                echo "  --help, -h            Show this help"
                echo ""
                echo "Config file: ~/.config/groq/whisper.conf"
                echo "  api_key           = your-groq-api-key"
                echo "  mic               = alsa_input.usb-..."
                echo "  duration          = 30"
                echo "  silence_duration  = 3.0"
                echo "  silence_threshold = 0.1"
                echo "  start_prompt      = 🎙️"
                echo "  model             = whisper-large-v3-turbo"
                echo "  language          = en"
                echo ""
                echo "Environment: GROQ_API_KEY overrides config file"
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                ;;
        esac
    done

    # Now check deps (after parsing, so --list-mics and --help work without API key)
    check_deps

    if [[ -n "$input_file" ]]; then
        # Transcribe existing file
        transcribe "$input_file"
    else
        # Record then transcribe
        record_audio "$AUDIO_FILE"
        transcribe "$AUDIO_FILE"
    fi
}

main "$@"
