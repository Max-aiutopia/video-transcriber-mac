# -*- mode: python ; coding: utf-8 -*-
from PyInstaller.utils.hooks import collect_all, collect_submodules

hiddenimports = [
    "mlx._reprlib_fix",
    "mlx.core",
    "mlx.nn",
    "mlx.utils",
    "mlx_whisper",
    "mlx_whisper.audio",
    "mlx_whisper.decoding",
    "mlx_whisper.load_models",
    "mlx_whisper.timing",
    "mlx_whisper.tokenizer",
    "mlx_whisper.transcribe",
    "mlx_whisper.whisper",
    "opencc",
    "deep_translator",
    "yt_dlp",
    "huggingface_hub",
    "huggingface_hub.errors",
    "tqdm",
]
hiddenimports += collect_submodules("mlx")
hiddenimports += collect_submodules("mlx_whisper")

datas = []
binaries = []
for pkg in ("mlx", "mlx_whisper", "yt_dlp"):
    tmp_ret = collect_all(pkg)
    datas += tmp_ret[0]
    binaries += tmp_ret[1]
    hiddenimports += tmp_ret[2]

a = Analysis(
    ["mlx_cli.py"],
    pathex=[],
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=["tkinter", "matplotlib", "pandas", "notebook", "IPython"],
    noarchive=False,
    optimize=0,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.datas,
    [],
    name="transcriber-cli",
    debug=False,
    bootloader_ignore_signals=False,
    strip=True,
    upx=False,
    upx_exclude=[],
    runtime_tmpdir=None,
    console=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch="arm64",
    codesign_identity=None,
    entitlements_file=None,
)