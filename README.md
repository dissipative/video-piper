# Video Piper

Video Piper is a tiny, single-script batch transcoder named after the fictional startup from _Silicon Valley_. It targets macOS on Apple Silicon and helps you re-encode whole seasons of TV into modern formats with a single command.

## Requirements
- `ffmpeg` and `ffprobe` (`brew install ffmpeg` on macOS)

## Usage
```bash
./encode.sh "/path/to/Season 1" \
  --encoder cpu-x265 \
  --audio 1,2 \
  --audio-mode copy \
  --subs 1,2,3
```

Use `--subs` to pick specific subtitle tracks (1-based indices) instead of keeping every subtitle stream.

Run `./encode.sh --help` for the full list of options.
