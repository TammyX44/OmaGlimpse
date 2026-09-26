#!/usr/bin/env python3
"""Fetch MPRIS HTTPS artwork without exposing a network URL to Qt Image."""

import ctypes
import os
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib.parse import urlsplit


MAX_BYTES = 1024 * 1024
MAX_PIXELS = 4096 * 4096
MAX_SIDE = 4096


def curl_has_streaming_limit():
    """Older curl versions only checked Content-Length for --max-filesize."""
    try:
        version = subprocess.run(["curl", "--version"], capture_output=True, text=True,
                                 timeout=1, check=True).stdout.splitlines()[0]
        match = re.match(r"curl (\d+)\.(\d+)", version)
        return bool(match and (int(match[1]), int(match[2])) >= (8, 4))
    except (OSError, IndexError, subprocess.SubprocessError):
        return False


def image_kind(data):
    """Accept small raster formats with bounded declared dimensions."""
    if data.startswith(b"\x89PNG\r\n\x1a\n") and len(data) >= 24:
        if data[12:16] != b"IHDR" or int.from_bytes(data[8:12], "big") != 13:
            return None
        width = int.from_bytes(data[16:20], "big")
        height = int.from_bytes(data[20:24], "big")
        kind = "png"
    elif data[:6] in (b"GIF87a", b"GIF89a") and len(data) >= 10:
        width = int.from_bytes(data[6:8], "little")
        height = int.from_bytes(data[8:10], "little")
        kind = "gif"
    elif data.startswith(b"\xff\xd8"):
        offset = 2
        width = height = 0
        while offset + 4 <= len(data):
            if data[offset] != 0xff:
                break
            marker = data[offset + 1]
            offset += 2
            if marker in (0xd8, 0xd9) or 0xd0 <= marker <= 0xd7:
                continue
            if marker == 0xda:
                break
            length = int.from_bytes(data[offset:offset + 2], "big")
            if length < 2 or offset + length > len(data):
                break
            if marker in (0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7,
                          0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf) and length >= 7:
                height = int.from_bytes(data[offset + 3:offset + 5], "big")
                width = int.from_bytes(data[offset + 5:offset + 7], "big")
                break
            offset += length
        kind = "jpg"
    elif data.startswith(b"RIFF") and data[8:12] == b"WEBP" and len(data) >= 30:
        tag = data[12:16]
        if tag == b"VP8X":
            width = 1 + int.from_bytes(data[24:27], "little")
            height = 1 + int.from_bytes(data[27:30], "little")
        elif tag == b"VP8L" and data[20] == 0x2f:
            bits = int.from_bytes(data[21:25], "little")
            width = (bits & 0x3fff) + 1
            height = ((bits >> 14) & 0x3fff) + 1
        elif tag == b"VP8 " and data[23:26] == b"\x9d\x01\x2a":
            width = int.from_bytes(data[26:28], "little") & 0x3fff
            height = int.from_bytes(data[28:30], "little") & 0x3fff
        else:
            return None
        kind = "webp"
    else:
        return None

    if not (0 < width <= MAX_SIDE and 0 < height <= MAX_SIDE
            and width * height <= MAX_PIXELS):
        return None
    return kind


def private_cache_dir():
    base = Path(tempfile.gettempdir()) / f"omaglimpse-art-{os.getuid()}"
    try:
        base.mkdir(mode=0o700)
    except FileExistsError:
        pass
    info = base.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError("unsafe artwork cache directory")
    return base


def prune_cache(base):
    # A hard-killed helper can leave its unfinished private file behind.
    for path in base.glob("pending-*.part"):
        if time.time() - path.stat().st_mtime > 30:
            path.unlink(missing_ok=True)
    files = sorted((p for p in base.iterdir() if p.suffix in (".png", ".jpg", ".gif", ".webp")),
                   key=lambda p: p.stat().st_mtime, reverse=True)
    for path in files[32:]:
        path.unlink(missing_ok=True)


def fetch(url):
    if not curl_has_streaming_limit():
        return None
    if len(url) > 8192 or any(ord(char) < 32 or ord(char) == 127 for char in url):
        return None
    try:
        parsed = urlsplit(url)
        if parsed.scheme.lower() != "https" or not parsed.hostname or parsed.username or parsed.password:
            return None
        parsed.port  # Reject malformed ports before starting curl.
    except ValueError:
        return None

    base = private_cache_dir()
    prune_cache(base)
    fd, name = tempfile.mkstemp(prefix="pending-", suffix=".part", dir=base)
    os.close(fd)
    process = None

    def stop(_signum, _frame):
        if process is not None and process.poll() is None:
            process.terminate()
        raise InterruptedError

    previous = signal.signal(signal.SIGTERM, stop)
    try:
        parent_pid = os.getpid()

        def terminate_curl_with_parent():
            # Quickshell may destroy the helper immediately after stopping it.
            # Keep curl tied to this process even if that becomes SIGKILL.
            libc = ctypes.CDLL(None, use_errno=True)
            if libc.prctl(1, signal.SIGTERM, 0, 0, 0) != 0 or os.getppid() != parent_pid:
                os._exit(1)

        process = subprocess.Popen([
            "curl", "--silent", "--show-error", "--fail", "--location",
            "--max-redirs", "3", "--proto", "=https", "--proto-redir", "=https",
            "--max-filesize", str(MAX_BYTES), "--max-time", "6",
            "--connect-timeout", "3", "--output", name, "--url", url,
        ], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            preexec_fn=terminate_curl_with_parent)
        if process.wait(timeout=7) != 0:
            return None
        if not 0 < os.stat(name).st_size <= MAX_BYTES:
            return None
        with open(name, "rb") as artwork:
            kind = image_kind(artwork.read(MAX_BYTES + 1))
        if not kind:
            return None
        result = Path(name).with_suffix("." + kind)
        os.replace(name, result)
        prune_cache(base)
        return result.as_uri()
    except (OSError, ValueError, subprocess.TimeoutExpired, InterruptedError):
        if process is not None and process.poll() is None:
            process.kill()
            process.wait()
        return None
    finally:
        signal.signal(signal.SIGTERM, previous)
        Path(name).unlink(missing_ok=True)


if __name__ == "__main__":
    if len(sys.argv) == 2:
        result = fetch(sys.argv[1])
        if result:
            print(result)
            sys.exit(0)
    sys.exit(1)
