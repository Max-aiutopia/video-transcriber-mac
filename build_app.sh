#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="影片轉文字"
APP_BUNDLE="$ROOT/$APP_NAME.app"
MACOS_DIR="$APP_BUNDLE/Contents/MacOS"
VENDOR_DIR="$ROOT/vendor/ffmpeg-arm64"
FFMPEG_URL="https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/ffmpeg.zip"
FFPROBE_URL="https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/ffprobe.zip"

mkdir -p "$MACOS_DIR" "$VENDOR_DIR"

bundle_ffmpeg() {
  echo "==> 準備內建 ffmpeg (Apple Silicon)"
  local tool tmp_zip url
  for tool in ffmpeg ffprobe; do
    if [[ "$tool" == "ffmpeg" ]]; then
      url="$FFMPEG_URL"
    else
      url="$FFPROBE_URL"
    fi
    if [[ -x "$VENDOR_DIR/$tool" ]]; then
      echo "    使用快取：$VENDOR_DIR/$tool"
    else
      tmp_zip="$(mktemp -t "${tool}.XXXXXX.zip")"
      echo "    下載 $tool ..."
      curl -fsSL -o "$tmp_zip" "$url"
      unzip -o -j "$tmp_zip" -d "$VENDOR_DIR"
      rm -f "$tmp_zip"
      chmod +x "$VENDOR_DIR/$tool"
    fi
    cp "$VENDOR_DIR/$tool" "$MACOS_DIR/$tool"
    codesign --force --sign - "$MACOS_DIR/$tool" >/dev/null
  done
  "$MACOS_DIR/ffmpeg" -version | head -1
}

echo "==> 編譯 Swift GUI"
swiftc -O \
  -o "$MACOS_DIR/$APP_NAME" \
  "$ROOT/mac_app.swift" \
  -framework AppKit \
  -framework Foundation \
  -framework UniformTypeIdentifiers

bundle_ffmpeg

echo "==> 打包 MLX CLI (PyInstaller)"
cd "$ROOT"
python3 -m PyInstaller --noconfirm --clean transcriber-cli.spec
cp "$ROOT/dist/transcriber-cli" "$MACOS_DIR/transcriber-cli"
chmod +x "$MACOS_DIR/transcriber-cli"

echo "==> 簽署 App (adhoc)"
codesign --force --deep --sign - "$APP_BUNDLE"

echo "==> 完成：$APP_BUNDLE"
ls -lh "$MACOS_DIR"
du -sh "$APP_BUNDLE"