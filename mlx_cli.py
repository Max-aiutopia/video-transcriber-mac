#!/usr/bin/env python3
"""
Self-contained CLI for 影片轉文字.app using mlx-whisper (Apple Silicon optimized).

This replaces the old faster-whisper + external venv approach.
It produces the same stdout protocol so the existing Swift GUI continues to work:

- PROGRESS::percent::message
- HH:MM:SS  log message
- OUTPUT_DIR::/absolute/path/to/job

Usage examples (same as before):
  python mlx_cli.py --input-file video.mp4 --output-dir ~/Desktop/out --model large-v3 --format srt --format txt
  python mlx_cli.py --url "https://..." --download-video --cookies chrome --language zh ...
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import List, Optional
from urllib.parse import unquote, urlparse

if getattr(sys, "frozen", False):
    APP_DIR = Path(sys.executable).resolve().parent
else:
    APP_DIR = Path(__file__).resolve().parent

DOWNLOAD_DIR = APP_DIR / "downloads"
DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)


def configure_runtime_environment() -> None:
    """Ensure bundled ffmpeg is visible to mlx_whisper and subprocess calls."""
    app_dir = str(APP_DIR)
    current_path = os.environ.get("PATH", "")
    path_entries = current_path.split(":")
    if app_dir not in path_entries:
        os.environ["PATH"] = f"{app_dir}:{current_path}" if current_path else app_dir


configure_runtime_environment()

LANGUAGE_NAMES = {
    "zh": "中文",
    "en": "英文",
    "ja": "日文",
    "ko": "韓文",
    "es": "西班牙文",
    "fr": "法文",
    "de": "德文",
    "it": "義大利文",
    "pt": "葡萄牙文",
    "vi": "越南文",
    "th": "泰文",
    "id": "印尼文",
}

CATEGORY_DIRS = {
    "video": "影片",
    "txt": "文字 TXT",
    "srt": "字幕 SRT",
}

def progress(percent: int, message: str) -> None:
    print(f"PROGRESS::{percent}::{message}", flush=True)

def log(message: str) -> None:
    print(f"{time.strftime('%H:%M:%S')}  {message}", flush=True)

def safe_name(name: str) -> str:
    name = re.sub(r"[^\w\-. \u4e00-\u9fff]+", "_", name, flags=re.UNICODE).strip()
    return name[:90] or "transcript"

def unique_path(path: Path) -> Path:
    if not path.exists():
        return path
    for index in range(2, 1000):
        candidate = path.with_name(f"{path.stem} {index}{path.suffix}")
        if not candidate.exists():
            return candidate
    raise RuntimeError(f"無法建立不重複檔名：{path.name}")

def unique_dir(path: Path) -> Path:
    if not path.exists():
        path.mkdir(parents=True, exist_ok=False)
        return path
    for index in range(2, 1000):
        candidate = path.with_name(f"{path.name} {index}")
        if not candidate.exists():
            candidate.mkdir(parents=True, exist_ok=False)
            return candidate
    raise RuntimeError(f"無法建立不重複資料夾：{path.name}")

def output_folder(output_dir: Path, title: str) -> Path:
    return unique_dir(output_dir / safe_name(title))

def classified_file(job_dir: Path, category: str, title: str, suffix: str) -> Path:
    category_dir = job_dir / CATEGORY_DIRS[category]
    category_dir.mkdir(parents=True, exist_ok=True)
    return unique_path(category_dir / f"{safe_name(title)}.{suffix}")

def bundled_tool_paths(tool_name: str) -> List[Path]:
    names = [tool_name]
    if tool_name == "ffmpeg":
        names.append("ffmpeg-arm64")
    elif tool_name == "ffprobe":
        names.append("ffprobe-arm64")
    candidates = []
    for name in names:
        candidates.append(APP_DIR / name)
        candidates.append(APP_DIR.parent / "Resources" / name)
    return candidates


def resolve_tool(tool_name: str, *, required: bool = True) -> Optional[str]:
    for candidate in bundled_tool_paths(tool_name):
        if candidate.exists() and os.access(candidate, os.X_OK):
            return str(candidate)
    for candidate in (
        shutil.which(tool_name),
        f"/opt/homebrew/bin/{tool_name}",
        f"/usr/local/bin/{tool_name}",
    ):
        if candidate and Path(candidate).exists():
            return candidate
    if required:
        raise RuntimeError(
            f"找不到 {tool_name}。"
            "請重新安裝 App，或執行：brew install ffmpeg"
        )
    return None


def ffmpeg_path() -> str:
    return resolve_tool("ffmpeg", required=True)


def ffprobe_path() -> Optional[str]:
    return resolve_tool("ffprobe", required=False)

def probe_codecs(video_path: Path) -> tuple[str, str]:
    probe = ffprobe_path()
    if not probe:
        return "", ""
    try:
        result = subprocess.run(
            [probe, "-v", "error", "-show_entries", "stream=codec_type,codec_name",
             "-of", "default=noprint_wrappers=1", str(video_path)],
            text=True, capture_output=True, check=True,
        )
    except subprocess.CalledProcessError:
        return "", ""
    video_codec = ""
    audio_codec = ""
    current_type = ""
    for line in result.stdout.splitlines():
        if line.startswith("codec_type="):
            current_type = line.split("=", 1)[1].strip()
        elif line.startswith("codec_name="):
            name = line.split("=", 1)[1].strip()
            if current_type == "video" and not video_codec:
                video_codec = name
            elif current_type == "audio" and not audio_codec:
                audio_codec = name
    return video_codec, audio_codec

def ensure_quicktime_compatible(video_path: Path) -> Path:
    video_codec, audio_codec = probe_codecs(video_path)
    needs_video_transcode = video_codec not in {"h264", "avc1"}
    needs_audio_transcode = audio_codec not in {"aac", "mp4a"}
    needs_container = video_path.suffix.lower() != ".mp4"

    if not (needs_video_transcode or needs_audio_transcode or needs_container):
        log("影片已是 QuickTime 相容格式，套用 faststart")
        fixed = video_path.with_name(video_path.stem + ".fix.mp4")
        cmd = [ffmpeg_path(), "-y", "-i", str(video_path), "-c", "copy", "-movflags", "+faststart", str(fixed)]
        run_command(cmd, APP_DIR)
        video_path.unlink(missing_ok=True)
        fixed.rename(video_path.with_suffix(".mp4"))
        return video_path.with_suffix(".mp4")

    log("影片 codec 不相容 QuickTime，正在轉成 H.264 + AAC")
    progress(28, "正在轉成 QuickTime 相容格式")
    fixed = video_path.with_name(video_path.stem + ".fix.mp4")
    video_args = ["-c:v", "copy"] if not needs_video_transcode else [
        "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-pix_fmt", "yuv420p", "-profile:v", "high", "-level", "4.0",
    ]
    audio_args = ["-c:a", "copy"] if not needs_audio_transcode else ["-c:a", "aac", "-b:a", "192k"]
    cmd = [ffmpeg_path(), "-y", "-i", str(video_path), *video_args, *audio_args, "-movflags", "+faststart", str(fixed)]
    run_command(cmd, APP_DIR)
    video_path.unlink(missing_ok=True)
    final_path = video_path.with_suffix(".mp4")
    fixed.rename(final_path)
    return final_path

def format_timestamp(seconds: float) -> str:
    milliseconds = int(round(seconds * 1000))
    hours, milliseconds = divmod(milliseconds, 3_600_000)
    minutes, milliseconds = divmod(milliseconds, 60_000)
    secs, milliseconds = divmod(milliseconds, 1000)
    return f"{hours:02}:{minutes:02}:{secs:02},{milliseconds:03}"

def write_srt(path: Path, segments: List[dict]) -> None:
    with path.open("w", encoding="utf-8") as f:
        for index, segment in enumerate(segments, 1):
            f.write(f"{index}\n")
            f.write(f"{format_timestamp(segment['start'])} --> {format_timestamp(segment['end'])}\n")
            f.write(segment["text"].strip() + "\n\n")

def write_txt(path: Path, segments: List[dict]) -> None:
    text = "\n".join(segment["text"].strip() for segment in segments if segment["text"].strip())
    path.write_text(text + "\n", encoding="utf-8")

def run_command(cmd: List[str], cwd: Path) -> None:
    env = os.environ.copy()
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + env.get("PATH", "")
    result = subprocess.run(cmd, cwd=str(cwd), env=env, text=True, capture_output=True)
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "指令執行失敗"
        raise RuntimeError(detail)

def should_delegate_to_yt_dlp() -> bool:
    """PyInstaller + yt-dlp may re-invoke sys.executable without our CLI flags."""
    if not getattr(sys, "frozen", False):
        return False
    if any(arg == "--output-dir" or arg.startswith("--output-dir=") for arg in sys.argv[1:]):
        return False
    return True


def run_yt_dlp(opts: dict, urls: List[str], cookies_browser: str = "") -> None:
    import yt_dlp

    ydl_opts = dict(opts)
    if getattr(sys, "frozen", False):
        ydl_opts.setdefault("ffmpeg_location", str(APP_DIR))
    if cookies_browser:
        ydl_opts["cookiesfrombrowser"] = (cookies_browser,)

    try:
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            exit_code = ydl.download(urls)
            if exit_code != 0:
                raise RuntimeError("yt-dlp 下載失敗")
    except yt_dlp.utils.DownloadError as exc:
        raise RuntimeError(str(exc)) from exc

def local_path_from_url(url: str) -> Optional[Path]:
    value = url.strip()
    if not value:
        return None
    if value.startswith("file://"):
        parsed = urlparse(value)
        return Path(unquote(parsed.path)).expanduser()
    if re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*://", value):
        return None
    if value.startswith(("/", "~", "./", "../")):
        return Path(value).expanduser()
    candidate = Path(value).expanduser()
    if candidate.exists():
        return candidate
    return None

def validate_url(url: str) -> None:
    parsed = urlparse(url)
    host = parsed.netloc.lower()
    if host.startswith("www."):
        host = host[4:]
    if host not in {"instagram.com", "instagr.am"}:
        return
    parts = [part for part in parsed.path.split("/") if part]
    if parts and parts[0] in {"reel", "p", "tv"}:
        return
    raise RuntimeError(
        "Instagram 請貼單支 Reel / 貼文連結，不要貼帳號首頁。"
        "請打開那支 Reel，按分享或複製連結；網址通常像 https://www.instagram.com/reel/..."
    )

def download_audio(url: str, cookies_browser: str, work_dir: Path) -> Path:
    progress(12, "正在下載影片音訊")
    log("正在下載影片音訊")
    output_template = str(work_dir / "%(title).120B.%(ext)s")
    run_yt_dlp(
        {
            "format": "ba/b",
            "extractaudio": True,
            "audioformat": "mp3",
            "audioquality": "0",
            "noplaylist": True,
            "outtmpl": output_template,
        },
        [url],
        cookies_browser,
    )
    audio_exts = {".mp3", ".m4a", ".webm", ".opus", ".ogg", ".wav", ".aac", ".flac"}
    audio_files = sorted(
        (p for p in work_dir.iterdir() if p.is_file() and p.suffix.lower() in audio_exts),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    if not audio_files:
        raise RuntimeError("找不到下載後的音訊檔")
    progress(32, "音訊下載完成")
    return audio_files[0]

def download_video(url: str, cookies_browser: str, job_dir: Path) -> Path:
    progress(10, "正在下載 MP4 影片")
    log("正在下載 MP4 影片 (H.264 1080p / QuickTime 相容)")
    output_template = str(job_dir / "%(title).120B.%(ext)s")
    format_selector = (
        "bv*[vcodec~='^(avc1|h264)'][height<=1080]+ba[acodec~='^(mp4a|aac)']"
        "/bv*[ext=mp4][height<=1080]+ba[ext=m4a]"
        "/b[ext=mp4][height<=1080]"
        "/bv*[height<=1080]+ba"
        "/b[height<=1080]"
        "/b"
    )
    run_yt_dlp(
        {
            "format": format_selector,
            "merge_output_format": "mp4",
            "noplaylist": True,
            "outtmpl": output_template,
        },
        [url],
        cookies_browser,
    )
    video_files = sorted(job_dir.glob("*.mp4"), key=lambda p: p.stat().st_mtime, reverse=True)
    if not video_files:
        video_files = sorted(job_dir.glob("*.*"), key=lambda p: p.stat().st_mtime, reverse=True)
    if not video_files:
        raise RuntimeError("找不到下載後的影片檔")
    progress(25, "影片下載完成，檢查格式")
    final_path = ensure_quicktime_compatible(video_files[0])
    progress(35, "影片格式已驗證完成")
    return final_path

def prepare_audio(source_path: Path, work_dir: Path) -> Path:
    if is_audio_file(source_path):
        progress(45, "偵測到音訊檔，直接轉錄")
        log(f"偵測到音訊檔，略過擷取：{source_path.name}")
        progress(50, "音訊準備完成")
        return source_path

    progress(42, "正在擷取音訊")
    log("正在從影片擷取音訊")
    audio_path = work_dir / "audio.wav"
    cmd = [
        ffmpeg_path(), "-y", "-i", str(source_path),
        "-vn", "-ac", "1", "-ar", "16000", str(audio_path),
    ]
    run_command(cmd, APP_DIR)
    progress(50, "音訊擷取完成")
    return audio_path

# ===================== MLX Whisper integration (NEW) =====================

HIGH_PRECISION_REPO = "mlx-community/whisper-large-v3-mlx"


def get_mlx_repo(model_size: str, *, high_precision: bool = False) -> str:
    """Map UI model names to mlx-community repos (Apple Silicon optimized)."""
    if high_precision:
        return HIGH_PRECISION_REPO

    m = model_size.lower().strip()
    mapping = {
        "large-v3": "mlx-community/whisper-large-v3-turbo",
        "large": "mlx-community/whisper-large-v3-turbo",
        "medium": "mlx-community/whisper-medium-mlx",
        "small": "mlx-community/whisper-small-mlx",
        "base": "mlx-community/whisper-base-mlx",
        "tiny": "mlx-community/whisper-tiny-mlx",
    }
    return mapping.get(m, "mlx-community/whisper-large-v3-turbo")


def language_hint(output_language: str) -> Optional[str]:
    if output_language == "zh":
        return "zh"
    if output_language == "en":
        return "en"
    return None


def initial_prompt_for(output_language: str, high_precision: bool) -> Optional[str]:
    if not high_precision:
        return None
    if output_language == "zh":
        return "以下是繁體中文的逐字稿，請準確轉錄每個字詞與標點符號。"
    if output_language == "en":
        return "The following is an accurate English transcript with proper nouns and punctuation."
    return "以下是完整且精確的逐字稿，請保留專有名詞與標點符號。"


AUDIO_EXTENSIONS = {".mp3", ".wav", ".m4a", ".aac", ".flac", ".ogg", ".opus", ".wma"}


def is_audio_file(path: Path) -> bool:
    return path.suffix.lower() in AUDIO_EXTENSIONS

def ensure_model_repo(repo_id: str) -> str:
    """Download MLX Whisper model if needed and report progress to the GUI."""
    from huggingface_hub import snapshot_download
    from huggingface_hub.errors import LocalEntryNotFoundError
    from tqdm.auto import tqdm as BaseTqdm

    class SilentTqdm(BaseTqdm):
        def __init__(self, *args, **kwargs):
            kwargs["disable"] = True
            super().__init__(*args, **kwargs)

    class ModelDownloadTqdm(BaseTqdm):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, **kwargs)
            self._last_reported = -1

        def update(self, n=1):
            super().update(n)
            if not self.total:
                return
            pct = int(self.n * 100 / self.total)
            if pct == self._last_reported:
                return
            self._last_reported = pct
            overall = min(64, 55 + int(pct * 9 / 100))
            label = (self.desc or "模型檔案").strip()
            progress(overall, f"正在下載模型 {pct}%（{label}）")

    try:
        local_path = snapshot_download(repo_id, local_files_only=True, tqdm_class=SilentTqdm)
        log("模型已在快取中，略過下載")
        progress(64, "模型已就緒")
        return local_path
    except (LocalEntryNotFoundError, OSError, ValueError):
        pass

    log("首次使用，正在從 Hugging Face 下載模型，請保持網路連線…")
    progress(56, "正在下載模型 0%")
    local_path = snapshot_download(repo_id, tqdm_class=ModelDownloadTqdm)
    progress(64, "模型下載完成")
    log("模型下載完成")
    return local_path


def refine_chinese_text(text: str, converter) -> str:
    text = converter.convert(text.strip())
    text = re.sub(r"[ \t]{2,}", " ", text)
    text = re.sub(r"([，。！？；：、])[ \t]+", r"\1", text)
    return text


_REPEAT_WORD = re.compile(r"(\b[\w'-]+\b)(?:\s+\1){6,}", re.IGNORECASE)
_REPEAT_PHRASE = re.compile(r"([^.!?]{4,80}?)(?:\s*,\s*\1){1,}", re.IGNORECASE)


def _compression_ratio(text: str) -> float:
    import zlib

    payload = text.encode("utf-8")
    if not payload:
        return 0.0
    compressed = zlib.compress(payload)
    return len(payload) / max(len(compressed), 1)


def clean_hallucinated_text(text: str) -> str:
    """Remove Whisper repetition loops like 'major major major...'."""
    cleaned = text.strip()
    if not cleaned:
        return ""

    prev = None
    while prev != cleaned:
        prev = cleaned
        cleaned = _REPEAT_WORD.sub(r"\1", cleaned)
        cleaned = _REPEAT_PHRASE.sub(r"\1", cleaned)

    words = cleaned.split()
    if len(words) >= 12:
        for index in range(len(words) - 7):
            window = words[index : index + 8]
            if len({word.lower() for word in window}) == 1:
                cleaned = " ".join(words[:index]).strip()
                break

    if _compression_ratio(cleaned) > 3.0 and len(cleaned) > 120:
        parts = re.split(r"(?<=[.!?])\s+", cleaned)
        trimmed = [part for part in parts if _compression_ratio(part) <= 2.8]
        if trimmed:
            cleaned = " ".join(trimmed).strip()

    return cleaned


def sanitize_segments(segments: List[dict]) -> List[dict]:
    cleaned_segments: List[dict] = []
    cleaned_count = 0
    dropped_count = 0
    for segment in segments:
        original = segment["text"]
        text = clean_hallucinated_text(original)
        if not text:
            dropped_count += 1
            continue
        if text != original:
            cleaned_count += 1
        cleaned_segments.append({**segment, "text": text})
    if cleaned_count or dropped_count:
        log(f"已清除疑似幻覺內容（修正 {cleaned_count} 段、移除 {dropped_count} 段）")
    return cleaned_segments


def transcribe(
    audio_path: Path,
    output_language: str,
    model_size: str,
    *,
    high_precision: bool = False,
) -> tuple[List[dict], str]:
    """
    Use mlx-whisper (much faster on Apple Silicon than the old CPU faster-whisper).
    """
    repo = get_mlx_repo(model_size, high_precision=high_precision)
    mode_label = "高精度" if high_precision else model_size
    progress(55, f"正在準備 MLX Whisper 模型 ({mode_label})")
    log(f"正在準備 MLX Whisper 模型：{repo}")
    if high_precision:
        log("高精度模式：使用 Large-v3 完整模型 + FP32 推論，速度較慢但錯字更少")

    model_path = ensure_model_repo(repo)
    progress(65, "正在載入模型到記憶體")
    log("正在載入模型，請稍候…")

    import mlx_whisper

    # translate 對英文原片容易多餘且更易觸發重複幻覺；英文輸出仍先轉錄原文。
    task = "transcribe"
    hinted_language = language_hint(output_language)
    os.environ["TQDM_DISABLE"] = "1"
    transcribe_kwargs = {
        "path_or_hf_repo": model_path,
        "verbose": False,
        "task": task,
        "temperature": (0.0, 0.2, 0.4) if high_precision else (0.0, 0.2, 0.4),
        "compression_ratio_threshold": 2.0 if high_precision else 2.2,
        "logprob_threshold": -0.8 if high_precision else -0.9,
        "no_speech_threshold": 0.5 if high_precision else 0.55,
        "condition_on_previous_text": False,
        "initial_prompt": initial_prompt_for(output_language, high_precision),
        "fp16": not high_precision,
    }
    if hinted_language:
        transcribe_kwargs["language"] = hinted_language

    result = mlx_whisper.transcribe(str(audio_path), **transcribe_kwargs)

    detected = result.get("language", "unknown")
    pretty_language = LANGUAGE_NAMES.get(detected.split("-")[0], detected)
    log(f"偵測到原影片語言：{pretty_language}")

    raw_segments = result.get("segments", [])
    segments = [
        {"start": seg["start"], "end": seg["end"], "text": seg["text"].strip()}
        for seg in raw_segments if seg.get("text", "").strip()
    ]
    segments = sanitize_segments(segments)

    if not segments:
        raise RuntimeError("沒有偵測到可轉錄的語音內容")

    progress(78, "轉錄完成")
    return segments, detected

# ===================== End MLX integration =====================

def translate_segments(
    segments: List[dict],
    detected_language: str,
    output_language: str,
    *,
    high_precision: bool = False,
) -> List[dict]:
    if output_language == "original":
        if high_precision and detected_language.startswith("zh"):
            from opencc import OpenCC

            progress(88, "高精度：正在潤飾中文原文")
            log("高精度模式：將原文潤飾為繁體中文用字")
            converter = OpenCC("s2twp")
            refined = [
                {**segment, "text": refine_chinese_text(segment["text"], converter)}
                for segment in segments
            ]
            progress(92, "原文潤飾完成")
            return refined
        progress(90, "使用原文輸出")
        return segments
    if output_language == "en":
        progress(90, "英文輸出完成")
        if detected_language.startswith("en"):
            log("使用英文原文輸出")
        else:
            log("正在翻譯成英文")
            from deep_translator import GoogleTranslator

            translator = GoogleTranslator(source="auto", target="en")
            translated = []
            for segment in segments:
                text = segment["text"].strip()
                if not text:
                    translated.append(segment)
                    continue
                translated.append({**segment, "text": translator.translate(text)})
            segments = translated
        return segments

    from opencc import OpenCC
    converter = OpenCC("s2twp")

    if detected_language.startswith("zh"):
        progress(84, "正在轉成繁體中文")
        log("正在轉成繁體中文")
        if high_precision:
            converted = [
                {**segment, "text": refine_chinese_text(segment["text"], converter)}
                for segment in segments
            ]
        else:
            converted = [{**segment, "text": converter.convert(segment["text"])} for segment in segments]
        progress(92, "繁體中文處理完成")
        return converted

    progress(84, "正在翻譯成繁體中文")
    log("正在翻譯成繁體中文")
    from deep_translator import GoogleTranslator

    translator = GoogleTranslator(source="auto", target="zh-TW")
    translated = []
    batch: List[str] = []
    batch_indices: List[int] = []
    max_batch_chars = 4500

    def flush_batch() -> None:
        if not batch:
            return
        joined = "\n".join(batch)
        try:
            result = translator.translate(joined)
        except Exception:
            result = joined
        parts = result.split("\n")
        if len(parts) != len(batch):
            parts = [translator.translate(text) for text in batch]
        for index, translated_text in zip(batch_indices, parts):
            translated[index] = {
                **segments[index],
                "text": converter.convert(translated_text.strip()),
            }
        batch.clear()
        batch_indices.clear()

    for index, segment in enumerate(segments):
        text = segment["text"].strip()
        if not text:
            translated.append(segment)
            continue
        translated.append(segment)
        projected = sum(len(item) for item in batch) + len(text) + len(batch)
        if batch and projected > max_batch_chars:
            flush_batch()
        batch.append(text)
        batch_indices.append(index)
    flush_batch()
    progress(92, "繁體中文翻譯完成")
    return translated

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Download and transcribe videos using MLX Whisper.")
    parser.add_argument("--url")
    parser.add_argument("--input-file")
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--language", choices=["zh", "en", "original"], default="zh")
    parser.add_argument("--model", choices=["base", "small", "medium", "large", "large-v3"], default="large-v3")
    parser.add_argument("--cookies", default="")
    parser.add_argument("--download-video", action="store_true")
    parser.add_argument("--high-precision", action="store_true")
    parser.add_argument("--format", dest="formats", action="append", choices=["txt", "srt"], default=[])
    return parser.parse_args()

def main() -> int:
    args = parse_args()
    if not args.url and not args.input_file:
        log("發生錯誤：請提供影片網址或本機檔案")
        return 1
    if args.url and args.input_file:
        log("發生錯誤：影片網址和本機檔案請擇一使用")
        return 1
    if args.url:
        local_path = local_path_from_url(args.url)
        if local_path is not None:
            log(f"偵測到本機檔案路徑，改用本機檔案：{local_path.name}")
            args.input_file = str(local_path)
            args.url = None
            args.download_video = False
        else:
            try:
                validate_url(args.url)
            except Exception as exc:
                log(f"發生錯誤：{exc}")
                return 1

    output_dir = Path(args.output_dir).expanduser()
    output_dir.mkdir(parents=True, exist_ok=True)
    job_dir: Optional[Path] = None
    video_path: Optional[Path] = None
    title = "transcript"

    try:
        progress(3, "開始處理")
        if args.high_precision:
            log("開始處理 (MLX Whisper 後端 / 高精度模式)")
        else:
            log("開始處理 (MLX Whisper 後端)")

        with tempfile.TemporaryDirectory(prefix="video_transcriber_", dir=str(DOWNLOAD_DIR)) as temp_name:
            work_dir = Path(temp_name)
            input_file: Optional[Path] = None

            if args.input_file:
                input_file = Path(args.input_file).expanduser()
                if not input_file.exists():
                    raise RuntimeError(f"找不到本機檔案：{input_file}")
                title = safe_name(input_file.stem)
                job_dir = output_folder(output_dir, title)
                log(f"使用本機檔案：{input_file.name}")
            elif args.download_video:
                video_path = download_video(args.url, args.cookies, work_dir)
                title = safe_name(video_path.stem)
                job_dir = output_folder(output_dir, title)
                video_dest = classified_file(job_dir, "video", title, video_path.suffix.lstrip(".") or "mp4")
                shutil.move(str(video_path), str(video_dest))
                video_path = video_dest
                log(f"影片已儲存：{video_path.relative_to(job_dir)}")

            if args.formats:
                if video_path:
                    audio_path = prepare_audio(video_path, work_dir)
                elif input_file:
                    audio_path = prepare_audio(input_file, work_dir)
                else:
                    audio_path = download_audio(args.url, args.cookies, work_dir)
                    title = safe_name(audio_path.stem)
                    job_dir = output_folder(output_dir, title)

                if job_dir is None:
                    job_dir = output_folder(output_dir, title)

                segments, detected_language = transcribe(
                    audio_path,
                    args.language,
                    args.model,
                    high_precision=args.high_precision,
                )
                segments = translate_segments(
                    segments,
                    detected_language,
                    args.language,
                    high_precision=args.high_precision,
                )

                progress(95, "正在寫入輸出檔")
                if "txt" in args.formats:
                    txt_path = classified_file(job_dir, "txt", title, "txt")
                    write_txt(txt_path, segments)
                    log(f"TXT 已儲存：{txt_path.relative_to(job_dir)}")
                if "srt" in args.formats:
                    srt_path = classified_file(job_dir, "srt", title, "srt")
                    write_srt(srt_path, segments)
                    log(f"SRT 已儲存：{srt_path.relative_to(job_dir)}")

        if job_dir is None:
            job_dir = output_folder(output_dir, title)
        print(f"OUTPUT_DIR::{job_dir}", flush=True)
        progress(100, "完成")
        log("完成")
        return 0
    except Exception as exc:
        log(f"發生錯誤：{exc}")
        return 1

if __name__ == "__main__":
    import multiprocessing

    multiprocessing.freeze_support()
    if should_delegate_to_yt_dlp():
        from yt_dlp import main as ytdlp_main

        raise SystemExit(ytdlp_main())
    raise SystemExit(main())
