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
import zlib
from pathlib import Path
from urllib.parse import urlsplit


MAX_BYTES = 1024 * 1024
MAX_PIXELS = 4096 * 4096
MAX_SIDE = 4096
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def curl_has_streaming_limit():
    """Older curl versions only checked Content-Length for --max-filesize."""
    try:
        version = subprocess.run(["curl", "--version"], capture_output=True, text=True,
                                 timeout=1, check=True).stdout.splitlines()[0]
        match = re.match(r"curl (\d+)\.(\d+)", version)
        return bool(match and (int(match[1]), int(match[2])) >= (8, 4))
    except (OSError, IndexError, subprocess.SubprocessError):
        return False


def png_rows(width, height, depth, color, interlace):
    """Yield scanline size, pixel count and pass start, including Adam7."""
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[color]
    passes = ((0, 0, 1, 1),) if not interlace else (
        (0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4),
        (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2),
    )
    for x, y, dx, dy in passes:
        columns = max(0, (width - x + dx - 1) // dx)
        rows = max(0, (height - y + dy - 1) // dy)
        if columns:
            for row in range(rows):
                yield 1 + (columns * channels * depth + 7) // 8, columns, row == 0


def palette_row(row, previous, depth, columns, entries):
    """Unfilter indexed samples and reject references outside the palette."""
    filtering = row[0]
    decoded = bytearray(row[1:])
    for i in range(len(decoded)):
        left = decoded[i - 1] if i else 0
        up = previous[i] if previous else 0
        corner = previous[i - 1] if previous and i else 0
        if filtering == 1:
            predictor = left
        elif filtering == 2:
            predictor = up
        elif filtering == 3:
            predictor = (left + up) // 2
        elif filtering == 4:
            p = left + up - corner
            a, b, c = abs(p - left), abs(p - up), abs(p - corner)
            predictor = left if a <= b and a <= c else up if b <= c else corner
        else:
            predictor = 0
        decoded[i] = (decoded[i] + predictor) & 255
    mask = (1 << depth) - 1
    for column in range(columns):
        bit = column * depth
        index = (decoded[bit // 8] >> (8 - depth - bit % 8)) & mask
        if index >= entries:
            return None
    return decoded


def valid_png_pixels(compressed, header, palette_entries):
    """Check only IDAT, retaining a scanline and (for indexing) its predecessor.

    The declared dimensions bound total expansion. Each inflate is capped at
    32769 bytes; never use an unbounded inflate or flush, or inflate metadata.
    """
    decoder = zlib.decompressobj()
    previous = None
    try:
        for size, columns, first in png_rows(*header):
            row = decoder.decompress(compressed, size)
            compressed = decoder.unconsumed_tail
            if len(row) != size or row[0] > 4:
                return False
            # A full palette covers every possible sample. Partial palettes
            # require undoing filters, with history reset at each Adam7 pass.
            if header[3] == 3 and palette_entries < 1 << header[2]:
                previous = palette_row(row, None if first else previous,
                                       header[2], columns, palette_entries)
                if previous is None:
                    return False
        # One extra byte detects expansion beyond the declared pixel layout.
        extra = decoder.decompress(compressed, 1)
        return (not extra and decoder.eof and not decoder.unused_data
                and not decoder.unconsumed_tail)
    except zlib.error:
        return False


def sanitize_png(data):
    """Return a bounded static PNG, or fail closed on invalid retained data.

    Only IHDR/PLTE/tRNS/IDAT/IEND can reach Qt. Discard every other ancillary
    chunk (text, ICC, EXIF, APNG, even unknown/private chunks) without parsing
    or decompressing its payload; still check its framing, type and CRC.
    Reject other formats: their metadata, frames or alternate image headers
    cannot safely be bounded by the former signature/dimension checks.
    """
    if not data.startswith(PNG_SIGNATURE) or len(data) > MAX_BYTES:
        return None
    offset = len(PNG_SIGNATURE)
    output = bytearray(PNG_SIGNATURE)
    header = None
    palette_entries = 0
    transparency = False
    idat_seen = idat_finished = False
    pixels = []
    while offset < len(data):
        if len(data) - offset < 12:
            return None
        length = int.from_bytes(data[offset:offset + 4], "big")
        tag = data[offset + 4:offset + 8]
        end = offset + 12 + length
        if (end > len(data) or not re.fullmatch(rb"[A-Za-z]{4}", tag)
                or tag[2] & 0x20):
            return None
        payload = data[offset + 8:end - 4]
        crc = int.from_bytes(data[end - 4:end], "big")
        if zlib.crc32(payload, zlib.crc32(tag)) != crc:
            return None
        if header is None and tag != b"IHDR":
            return None
        if idat_seen and tag != b"IDAT":
            idat_finished = True
        keep = True
        if tag == b"IHDR":
            if header is not None or length != 13:
                return None
            width = int.from_bytes(payload[:4], "big")
            height = int.from_bytes(payload[4:8], "big")
            depth, color, compression, filtering, interlace = payload[8:]
            depths = {0: (1, 2, 4, 8, 16), 2: (8, 16), 3: (1, 2, 4, 8),
                      4: (8, 16), 6: (8, 16)}
            if (not 0 < width <= MAX_SIDE or not 0 < height <= MAX_SIDE
                    or width * height > MAX_PIXELS or depth not in depths.get(color, ())
                    or compression != 0 or filtering != 0 or interlace not in (0, 1)):
                return None
            header = width, height, depth, color, interlace
        elif tag == b"PLTE":
            if (palette_entries or idat_seen or transparency or color in (0, 4)
                    or not 0 < length <= 768 or length % 3
                    or (color == 3 and length // 3 > 1 << depth)):
                return None
            palette_entries = length // 3
        elif tag == b"tRNS":
            if transparency or idat_seen:
                return None
            if color == 3:
                if not 0 < length <= palette_entries:
                    return None
            elif color in (0, 2):
                if length != (2 if color == 0 else 6):
                    return None
                if any(int.from_bytes(payload[i:i + 2], "big") >= 1 << depth
                       for i in range(0, length, 2)):
                    return None
            else:
                return None
            transparency = True
        elif tag == b"IDAT":
            if idat_finished or (color == 3 and not palette_entries):
                return None
            idat_seen = True
            pixels.append(payload)
        elif tag == b"IEND":
            if length or end != len(data) or not idat_seen:
                return None
            if not valid_png_pixels(b"".join(pixels), header, palette_entries):
                return None
            output.extend(data[offset:end])
            return bytes(output)
        elif not tag[0] & 0x20:
            return None  # Unknown critical chunks cannot be interpreted safely.
        else:
            keep = False
        if keep:
            output.extend(data[offset:end])
        offset = end
    return None  # Missing IEND, including a truncated download.


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
            sanitized = sanitize_png(artwork.read(MAX_BYTES + 1))
        if sanitized is None:
            return None
        # Publish only the sanitized bytes, never the downloaded source.
        with open(name, "wb") as artwork:
            artwork.write(sanitized)
        result = Path(name).with_suffix(".png")
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
