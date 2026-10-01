# Video Transcriber for macOS（影片轉文字）

A native macOS app that turns a YouTube or Instagram Reel link, or a local video or audio file, into a transcript. Everything runs on your Mac with Whisper on Apple Silicon. The UI is in Traditional Chinese.

[中文說明在下面](#中文說明)

## What it does

- **Input:** paste a YouTube or Instagram Reel URL, pick a local file, or or drag a file or URL onto the window or the app icon.
- **Download:** [yt-dlp](https://github.com/yt-dlp/yt-dlp). For Reels that need a login, it can read cookies from Chrome, Safari, Firefox or Edge at run time. Nothing is stored by the app. It can also keep the video and re-encode it to H.264/AAC when QuickTime can't play the original codec.
- **Transcribe:** [mlx-whisper](https://github.com/ml-explore/mlx-examples), `whisper-large-v3-turbo` by default (base / small / medium also available). A high-precision mode switches to the full `whisper-large-v3` with a language prompt. The model downloads once on first use.
- **Output language:** Traditional Chinese, English, or the original language. Chinese output is converted with OpenCC `s2twp` (Taiwan wording). Cross-language output is translated in batches with `deep-translator`, falling back to one segment at a time.
- **Cleanup:** removes Whisper's repetition loops (for example "major major major…") with a repeated-phrase check and a compression-ratio test.
- **Output:** TXT and/or SRT, plus the MP4 if you kept it. Each job gets its own folder.
- **App:** native AppKit window, dark mode, live progress, and a cancel button.

## How it fits together

```
mac_app.swift  (AppKit GUI)
   │  runs the bundled CLI and parses its stdout:
   │    PROGRESS::<percent>::<message>
   │    HH:MM:SS  <log line>
   │    OUTPUT_DIR::<path>
   ▼
transcriber-cli  (mlx_cli.py packaged with PyInstaller)
   ├─ yt-dlp → audio (and optional video)
   ├─ ffmpeg → 16 kHz mono WAV
   ├─ mlx-whisper → segments → cleanup → OpenCC / translation
   └─ TXT / SRT writer
```

`build_app.sh` compiles the Swift GUI with `swiftc`, downloads a static arm64 ffmpeg/ffprobe build, packages `mlx_cli.py` with PyInstaller, copies everything into `影片轉文字.app`, and ad-hoc signs it. The finished app is self-contained and can be moved anywhere.

## Build

Requires an Apple Silicon Mac, Xcode command line tools and Python 3.11+.

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
./build_app.sh
```

To use the CLI without the app:

```bash
python mlx_cli.py --url "https://www.youtube.com/watch?v=..." --output-dir ~/Desktop/out --language zh --format txt --format srt
python mlx_cli.py --input-file talk.mp4 --output-dir ~/Desktop/out --model large-v3 --format srt
```

## Please use it responsibly

Only download and transcribe content you have the right to use, and follow YouTube's and Instagram's terms. This tool is meant for personal study, note-taking and transcribing your own material.

## How it was built

I designed the workflow and the UI, and tested it on my own videos. The code was written with AI coding tools (Codex and Claude Code). `mlx_cli.py` replaced an earlier faster-whisper version.

## 中文說明

Mac 本機 App：貼 YouTube／IG Reel 網址，或丟本機影片／音檔，自動下載並用 Whisper（Apple Silicon 的 MLX 版）轉成逐字稿，輸出 TXT／SRT，可選擇保留 MP4。中文會轉成台灣繁體用字，也能翻成英文或中文。整個流程都在自己電腦上跑，不需要 API key。IG 需要登入時，會在執行當下讀取你選的瀏覽器 Cookie，App 本身不存任何登入資料。

只下載、轉錄你有權使用的內容，並遵守 YouTube 與 Instagram 的使用條款。

## License

MIT
