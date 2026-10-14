"""Exercise the real fetcher against a local TLS server with hostile responses."""

import http.server
import importlib.util
import os
from pathlib import Path
import signal
import socketserver
import struct
import subprocess
import tempfile
import threading
import unittest
from unittest import mock
from urllib.parse import unquote, urlsplit
import zlib


HELPER = Path(__file__).resolve().parents[1] / "fetch_album_art.py"
SPEC = importlib.util.spec_from_file_location("album_art", HELPER)
album_art = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(album_art)
SIGNATURE = b"\x89PNG\r\n\x1a\n"


def chunk(tag, payload=b""):
    return (struct.pack(">I", len(payload)) + tag + payload
            + struct.pack(">I", zlib.crc32(tag + payload)))


def header(width=1, height=1, depth=8, color=4, compression=0, filtering=0, interlace=0):
    return struct.pack(">IIBBBBB", width, height, depth, color,
                       compression, filtering, interlace)


def png(ihdr=None, compressed=None, before=b"", after=b""):
    return (SIGNATURE + chunk(b"IHDR", header() if ihdr is None else ihdr)
            + before + chunk(b"IDAT", zlib.compress(b"\0\xff\xff")
                             if compressed is None else compressed)
            + after + chunk(b"IEND"))


PNG = png()
IDAT = zlib.compress(b"\0\xff\xff")


def chunks(data):
    """Independently inspect the bytes actually published to the cache."""
    assert data[:8] == SIGNATURE
    result = []
    offset = 8
    while offset < len(data):
        length = struct.unpack_from(">I", data, offset)[0]
        tag = data[offset + 4:offset + 8]
        payload = data[offset + 8:offset + 8 + length]
        crc = struct.unpack_from(">I", data, offset + 8 + length)[0]
        assert zlib.crc32(tag + payload) == crc
        result.append((tag, payload))
        offset += 12 + length
    assert offset == len(data)
    return result


# 192 MiB of aggregate advertised metadata expansion, under the 1 MiB wire
# limit. Compress a single 1 MiB value once; never inflate these chunks in tests
# or send them to Qt. Repeated ICC chunks must also disappear, regardless of
# whether a metadata decoder would accept their contents or multiplicity.
PACKED_METADATA = zlib.compress(b"x" * (1024 * 1024))
METADATA = b"".join(
    chunk(tag, prefix + PACKED_METADATA)
    for _ in range(64)
    for tag, prefix in ((b"zTXt", b"note\0\0"),
                        (b"iTXt", b"note\0\x01\0en\0label\0"),
                        (b"iCCP", b"profile\0\0"))
)
ANCILLARY = b"".join(chunk(tag, b"discard me") for tag in (
    b"tEXt", b"eXIf", b"gAMA", b"cHRM", b"sRGB", b"sBIT", b"pHYs",
    b"bKGD", b"hIST", b"sPLT", b"tIME", b"vpAg",
))
ANIMATION = (chunk(b"acTL", struct.pack(">II", 100000, 0))
             + chunk(b"fcTL", struct.pack(">IIIIIHHBB", 0, 1, 1, 0, 0, 1, 1, 0, 0)))
FRAME_DATA = chunk(b"fdAT", struct.pack(">I", 1) + PACKED_METADATA)

# Inputs the old signature-only gates admitted: GIF logical-screen dimensions
# do not bound frame dimensions/count, JPEG can carry more headers/metadata,
# and a WebP extended canvas does not validate its embedded frames/bitstream.
GIF = (b"GIF89a\x01\0\x01\0\0\0\0"
       + b"," + struct.pack("<HHHHB", 0, 0, 65535, 65535, 0) + b";" * 32)
JPEG = (b"\xff\xd8\xff\xe2\x00\x10ICC_PROFILE\0\x01\x01"
        + b"\xff\xc0\x00\x0b\x08\x00\x01\x00\x01\x01\x01\x11\x00"
        + b"\xff\xc0\x00\x0b\x08\xff\xff\xff\xff\x01\x01\x11\x00\xff\xd9")
WEBP_BODY = (b"WEBPVP8X" + struct.pack("<I", 10) + b"\x02" + b"\0" * 9
             + b"ANIM" + struct.pack("<I", 6) + b"\0" * 6
             + b"ANMF" + struct.pack("<I", 16) + b"\xff" * 16)
WEBP = b"RIFF" + struct.pack("<I", len(WEBP_BODY)) + WEBP_BODY
SVG = b'<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"/>'
RESPONSES = {
    "/metadata": png(before=METADATA + ANCILLARY),
    "/metadata-after": png(after=METADATA),
    "/animation": png(before=ANIMATION, after=FRAME_DATA),
    "/gif": GIF, "/jpeg": JPEG, "/webp": WEBP, "/svg": SVG,
    "/bad-crc": PNG[:-1] + bytes([PNG[-1] ^ 1]),
    "/bad-metadata-crc": png(before=chunk(b"zTXt", b"note\0\0bad")[:-1] + b"\0"),
    "/truncated": PNG[:-1],
    "/trailing": PNG + b"trailing bytes",
    "/pixel-overflow": png(compressed=zlib.compress(b"\0\xff\xffextra")),
    "/dimensions": png(ihdr=header(width=100000)),
}


class SanitizerTest(unittest.TestCase):
    def test_valid_png_and_transparency_preserved(self):
        variants = [PNG]
        for color, payload in ((0, b"\0\x7f"), (2, b"\0\xff\0\0")):
            variants.append(png(ihdr=header(color=color), compressed=zlib.compress(payload),
                                before=chunk(b"tRNS", b"\0\x7f" if color == 0
                                             else b"\0\xff\0\0\0\0")))
        variants.append(png(ihdr=header(color=3, depth=1),
                            compressed=zlib.compress(b"\0\x80"),
                            before=chunk(b"PLTE", b"\xff\0\0\0\xff\0")
                            + chunk(b"tRNS", b"\0\xff")))
        for image in variants:
            with self.subTest(image=image):
                self.assertEqual(album_art.sanitize_png(image), image)

    def test_strips_all_metadata_and_animation_without_inflating_metadata(self):
        self.assertLess(len(RESPONSES["/metadata"]), album_art.MAX_BYTES)
        factory = zlib.decompressobj
        calls = []

        class PixelDecoder:
            def __init__(self):
                self.decoder = factory()

            def decompress(self, data, limit):
                calls.append((data, limit))
                return self.decoder.decompress(data, limit)

            def __getattr__(self, name):
                return getattr(self.decoder, name)

        with mock.patch.object(album_art.zlib, "decompressobj", PixelDecoder), \
                mock.patch.object(album_art.zlib, "decompress", side_effect=AssertionError):
            for path in ("/metadata", "/metadata-after", "/animation"):
                self.assertEqual(album_art.sanitize_png(RESPONSES[path]), PNG)
            # Even invalid compressed metadata is opaque and discarded.
            self.assertEqual(album_art.sanitize_png(png(before=chunk(
                b"iCCP", b"profile\0\0not a zlib stream"))), PNG)
        self.assertTrue(calls)
        for data, limit in calls:
            self.assertIn(data, (IDAT, b""))
            self.assertGreater(limit, 0)
            self.assertLessEqual(limit, 3)

    def test_rejects_chunk_framing_crc_and_unknown_critical_chunks(self):
        invalid = [
            PNG[:cut] for cut in (0, 7, 8, 9, 11, 15, 20, len(PNG) - 1)
        ] + [
            PNG + b"x", PNG + PNG, png()[:-12],
            SIGNATURE + struct.pack(">I", 0xffffffff) + b"IHDR" + PNG[16:],
            png(before=chunk(b"ABCD", b"unknown critical")),
            png(before=chunk(b"abca", b"reserved bit set")),
            png(before=chunk(b"a1Ca", b"invalid chunk name")),
            png(before=chunk(b"zTXt", b"note\0\0bad")[:-1] + b"\0"),
        ]
        # Corrupt CRCs in each retained critical chunk, and an ignored chunk.
        for offset in (8, 33, len(PNG) - 12):
            broken = bytearray(PNG)
            broken[offset + 8] ^= 1
            invalid.append(bytes(broken))
        for image in invalid:
            with self.subTest(image=image[:40], length=len(image)):
                self.assertIsNone(album_art.sanitize_png(image))

    def test_rejects_invalid_header_fields_with_correct_crcs(self):
        fields = ({"width": 0}, {"height": 0}, {"width": 4097}, {"height": 4097},
                  {"width": 0xffffffff}, {"color": 1}, {"color": 5}, {"color": 7},
                  {"depth": 0}, {"depth": 3}, {"depth": 32},
                  {"color": 2, "depth": 4}, {"color": 3, "depth": 16},
                  {"color": 4, "depth": 1}, {"color": 6, "depth": 2},
                  {"compression": 1}, {"filtering": 1}, {"interlace": 2})
        for values in fields:
            with self.subTest(values=values):
                self.assertIsNone(album_art.sanitize_png(png(ihdr=header(**values))))
        for payload in (header()[:-1], header() + b"\0"):
            self.assertIsNone(album_art.sanitize_png(png(ihdr=payload)))
        with mock.patch.object(album_art, "MAX_PIXELS", 3):
            self.assertIsNone(album_art.sanitize_png(png(ihdr=header(width=2, height=2))))
        self.assertIsNone(album_art.sanitize_png(PNG + b"\0" * album_art.MAX_BYTES))

    def test_critical_order_and_palette_transparency_constraints(self):
        h = chunk(b"IHDR", header())
        d = chunk(b"IDAT", IDAT)
        end = chunk(b"IEND")
        palette = chunk(b"PLTE", b"\0\0\0")
        indexed = chunk(b"IHDR", header(color=3, depth=1))
        gray = chunk(b"IHDR", header(color=0))
        invalid = [
            d + h + end, h + h + d + end, h + end,
            h + d + chunk(b"tEXt", b"note\0text") + d + end,
            h + d + palette + end, indexed + d + end,
            gray + palette + d + end,
            indexed + palette + palette + d + end,
            indexed + chunk(b"PLTE") + d + end,
            indexed + chunk(b"PLTE", b"\0" * 4) + d + end,
            indexed + chunk(b"PLTE", b"\0" * 9) + d + end,
            h + chunk(b"PLTE", b"\0" * 771) + d + end,
            indexed + chunk(b"tRNS", b"\0") + palette + d + end,
            indexed + palette + chunk(b"tRNS", b"\0\0") + d + end,
            indexed + palette + chunk(b"tRNS") + d + end,
            indexed + palette + chunk(b"tRNS", b"\0") * 2 + d + end,
            indexed + palette + d + chunk(b"tRNS", b"\0") + end,
            h + chunk(b"tRNS", b"\0") + d + end,
            gray + chunk(b"tRNS", b"\0") + d + end,
            gray + chunk(b"tRNS", b"\x01\0") + d + end,
            h + d + chunk(b"IEND", b"extra"), h + d + end + end,
        ]
        for image in invalid:
            with self.subTest(image=image[:50]):
                self.assertIsNone(album_art.sanitize_png(SIGNATURE + image))

    def test_pixel_stream_is_exact_bounded_and_complete(self):
        bad_streams = (b"", b"not zlib", IDAT[:-1], IDAT + b"trailing", IDAT + IDAT,
                       IDAT[:-1] + bytes([IDAT[-1] ^ 1]),
                       zlib.compress(b"\0\xff"), zlib.compress(b"\0\xff\xffextra"),
                       zlib.compress(b"\x05\xff\xff"),
                       zlib.compress(b"\0" * 65536))
        for compressed in bad_streams:
            with self.subTest(compressed=compressed[:30]):
                self.assertIsNone(album_art.sanitize_png(png(compressed=compressed)))
        # Many consecutive IDAT chunks, including empty chunks, form ONE stream.
        split = (SIGNATURE + chunk(b"IHDR", header()) + chunk(b"IDAT")
                 + b"".join(chunk(b"IDAT", bytes([value])) for value in IDAT)
                 + chunk(b"IDAT") + chunk(b"IEND"))
        self.assertEqual(album_art.sanitize_png(split), split)

    def test_indexed_pixels_cannot_reference_missing_palette_entries(self):
        palette = chunk(b"PLTE", b"\xff\0\0\0\xff\0")
        invalid_rows = (b"\0\x02\0", b"\x01\x01\x01",
                        b"\0\x01\0\x02\x01\0",
                        b"\0\x01\x01\x03\x02\0",
                        b"\0\0\x01\x04\x01\x01")
        for raw in invalid_rows:
            with self.subTest(raw=raw):
                image = png(ihdr=header(width=2, height=len(raw) // 3, color=3),
                            compressed=zlib.compress(raw), before=palette)
                self.assertIsNone(album_art.sanitize_png(image))
        # Sub and Up filters reconstruct legal indexes 1,0 then 1,1.
        image = png(ihdr=header(width=2, height=2, color=3),
                    compressed=zlib.compress(b"\x01\x01\xff\x02\0\x01"), before=palette)
        self.assertEqual(album_art.sanitize_png(image), image)
        # Ignore padding bits in the last byte of a sub-byte scanline.
        for depth, sample, valid in ((2, 0x7f, True), (2, 0xbf, False),
                                     (4, 0x1f, True), (4, 0x2f, False)):
            image = png(ihdr=header(color=3, depth=depth),
                        compressed=zlib.compress(bytes([0, sample])), before=palette)
            if valid:
                self.assertEqual(album_art.sanitize_png(image), image)
            else:
                self.assertIsNone(album_art.sanitize_png(image))

    def test_all_legal_color_depths_filters_and_adam7_passes(self):
        depths = {0: (1, 2, 4, 8, 16), 2: (8, 16), 3: (1, 2, 4, 8),
                  4: (8, 16), 6: (8, 16)}
        channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}
        for color, values in depths.items():
            for depth in values:
                for filtering in range(5):
                    with self.subTest(color=color, depth=depth, filtering=filtering):
                        # Zero samples keep filtered palette indexes in range.
                        row = bytes([filtering]) + b"\0" * ((3 * channels[color] * depth + 7) // 8)
                        image = png(ihdr=header(width=3, height=2, color=color, depth=depth),
                                    compressed=zlib.compress(row * 2),
                                    before=chunk(b"PLTE", b"\0\0\0") if color == 3 else b"")
                        self.assertEqual(album_art.sanitize_png(image), image)
        # Independent Adam7 layout for an 8x8 grayscale image: 1x1, 1x1,
        # 2x1, 2x2, 4x2, 4x4, 8x4, each scanline plus its filter byte.
        raw = b"".join((b"\0" + b"\x7f" * width) * height
                       for width, height in ((1, 1), (1, 1), (2, 1), (2, 2),
                                             (4, 2), (4, 4), (8, 4)))
        image = png(ihdr=header(width=8, height=8, color=0, interlace=1),
                    compressed=zlib.compress(raw))
        self.assertEqual(album_art.sanitize_png(image), image)
        self.assertIsNone(album_art.sanitize_png(png(
            ihdr=header(width=8, height=8, color=0, interlace=1),
            compressed=zlib.compress(raw + b"extra"))))
        tiny = png(ihdr=header(interlace=1))
        self.assertEqual(album_art.sanitize_png(tiny), tiny)

    def test_indexed_adam7_resets_filter_history_for_each_pass(self):
        raw = b"".join(b"\x02" + b"\x01" * width
                       + (b"\0" + b"\x01" * width) * (height - 1)
                       for width, height in ((1, 1), (1, 1), (2, 1), (2, 2),
                                             (4, 2), (4, 4), (8, 4)))
        image = png(ihdr=header(width=8, height=8, color=3, interlace=1),
                    before=chunk(b"PLTE", b"\0\0\0\xff\xff\xff"),
                    compressed=zlib.compress(raw))
        self.assertEqual(album_art.sanitize_png(image), image)

    def test_maximum_side_and_scanline_sizes_remain_supported(self):
        for ihdr, raw in ((header(width=4096, depth=16, color=6), b"\0" * 32769),
                          (header(height=4096, color=0), b"\0\x7f" * 4096)):
            with self.subTest(header=ihdr):
                image = png(ihdr=ihdr, compressed=zlib.compress(raw))
                self.assertEqual(album_art.sanitize_png(image), image)

    def test_rejects_other_formats_despite_small_first_headers(self):
        for image in (GIF, JPEG, WEBP, SVG, b"<?xml version='1.0'?>" + SVG):
            with self.subTest(image=image[:30]):
                self.assertIsNone(album_art.sanitize_png(image))


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/redirect-http":
            self.send_response(302)
            self.send_header("Location", "http://localhost:1/art")
            self.end_headers()
            return
        if self.path == "/redirect-https":
            self.send_response(302)
            self.send_header("Location", "/art")
            self.end_headers()
            return
        if self.path == "/chunked":
            self.send_response(200)
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            try:
                for _ in range(18):
                    self.wfile.write(b"10000\r\n" + b"x" * 65536 + b"\r\n")
                self.wfile.write(b"0\r\n\r\n")
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        if self.path == "/slow":
            import time
            time.sleep(8)
            body = PNG
        elif self.path == "/large":
            body = PNG + b"x" * 1048576
        elif self.path == "/bad":
            body = b"not an image"
        else:
            body = RESPONSES.get(self.path, PNG)
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *_args):
        pass


class FetchTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import ssl
        cls.temp = tempfile.TemporaryDirectory()
        temp = Path(cls.temp.name)
        cls.cert = temp / "cert.pem"
        key = temp / "key.pem"
        subprocess.run([
            "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", str(key), "-out", str(cls.cert), "-days", "1",
            "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost",
        ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cls.server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Handler)
        cls.server.daemon_threads = True
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cls.cert, key)
        cls.server.socket = context.wrap_socket(cls.server.socket, server_side=True)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = f"https://localhost:{cls.server.server_address[1]}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.temp.cleanup()

    def run_fetch(self, url, timeout=9):
        env = os.environ.copy()
        for name in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"):
            env.pop(name, None)
        env["CURL_CA_BUNDLE"] = str(self.cert)
        env["TMPDIR"] = self.temp.name
        return subprocess.run(["python3", str(HELPER), url], env=env, capture_output=True,
                              text=True, timeout=timeout)

    def test_small_image_and_https_redirect(self):
        for suffix in ("/art", "/redirect-https"):
            result = self.run_fetch(self.base + suffix)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(result.stdout.strip().startswith("file:///"))
            local = Path(unquote(urlsplit(result.stdout.strip()).path))
            self.assertEqual(local.read_bytes(), PNG)
            self.assertLessEqual(local.stat().st_size, 1048576)
            self.assertEqual(local.parent.stat().st_mode & 0o077, 0)
            self.assertEqual(local.stat().st_mode & 0o077, 0)

    def test_cached_payload_contains_only_static_pixels_not_compressed_metadata(self):
        for suffix in ("/metadata", "/metadata-after", "/animation"):
            with self.subTest(suffix=suffix):
                result = self.run_fetch(self.base + suffix)
                self.assertEqual(result.returncode, 0, result.stderr)
                local = Path(unquote(urlsplit(result.stdout.strip()).path))
                self.assertEqual(local.suffix, ".png")
                cached = local.read_bytes()
                self.assertEqual(cached, PNG)
                self.assertEqual([tag for tag, _ in chunks(cached)],
                                 [b"IHDR", b"IDAT", b"IEND"])
                self.assertNotIn(PACKED_METADATA, cached)
                self.assertEqual(zlib.decompress(dict(chunks(cached))[b"IDAT"]), b"\0\xff\xff")
                # The private cache also has no leftover original .part payload.
                self.assertEqual(list(local.parent.glob("pending-*.part")), [])

    def test_https_rejects_malformed_png_and_other_formats_without_publishing(self):
        cache = Path(self.temp.name) / f"omaglimpse-art-{os.getuid()}"
        for suffix in ("/gif", "/jpeg", "/webp", "/svg", "/bad-crc",
                       "/bad-metadata-crc", "/truncated", "/trailing", "/pixel-overflow"):
            with self.subTest(suffix=suffix):
                existing = set(cache.iterdir()) if cache.exists() else set()
                result = self.run_fetch(self.base + suffix)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertEqual(set(cache.iterdir()), existing)

    def test_cache_remains_bounded_after_sanitized_downloads(self):
        cache = Path(self.temp.name) / f"omaglimpse-art-{os.getuid()}"
        cache.mkdir(mode=0o700, exist_ok=True)
        for index in range(40):
            local = cache / f"existing-{index}.png"
            local.write_bytes(PNG)
            os.utime(local, (index, index))
        stale = cache / "pending-stale.part"
        stale.write_bytes(b"unfinished download")
        os.utime(stale, (0, 0))
        result = self.run_fetch(self.base + "/metadata")
        self.assertEqual(result.returncode, 0, result.stderr)
        local = Path(unquote(urlsplit(result.stdout.strip()).path))
        self.assertEqual(local.read_bytes(), PNG)
        self.assertLessEqual(len(list(cache.glob("*.png"))), 32)
        self.assertFalse(stale.exists())
        self.assertEqual(list(cache.glob("pending-*.part")), [])

    def test_rejects_oversized_chunked_and_invalid_images(self):
        for suffix in ("/large", "/chunked", "/bad", "/dimensions"):
            with self.subTest(suffix=suffix):
                result = self.run_fetch(self.base + suffix)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")

    def test_rejects_non_https_redirect_and_malformed_urls(self):
        for url in (self.base + "/redirect-http", "http://localhost/art",
                    "https://localhost:bad/art", "https://user:pass@localhost/art",
                    "https://localhost/\n--output=/tmp/evil"):
            with self.subTest(url=url):
                result = self.run_fetch(url)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")

    def test_slow_response_hits_six_second_deadline(self):
        import time
        start = time.monotonic()
        result = self.run_fetch(self.base + "/slow")
        elapsed = time.monotonic() - start
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertLess(elapsed, 7.5)

    def test_killing_helper_does_not_leave_curl_running(self):
        import time
        for stop_signal in (signal.SIGTERM, signal.SIGKILL):
            with self.subTest(signal=stop_signal):
                env = os.environ.copy()
                for name in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"):
                    env.pop(name, None)
                env["CURL_CA_BUNDLE"] = str(self.cert)
                env["TMPDIR"] = self.temp.name
                helper = subprocess.Popen(["python3", str(HELPER), self.base + "/slow"],
                                          env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                child_file = Path(f"/proc/{helper.pid}/task/{helper.pid}/children")
                child_pid = None
                try:
                    for _ in range(100):
                        if child_file.exists():
                            children = child_file.read_text().split()
                            if children:
                                child_pid = int(children[0])
                                break
                        time.sleep(0.02)
                    self.assertIsNotNone(child_pid, "curl did not start")
                    helper.send_signal(stop_signal)
                    helper.wait(timeout=2)
                    child_stat = Path(f"/proc/{child_pid}/stat")
                    for _ in range(100):
                        if not child_stat.exists() or child_stat.read_text().split()[2] == "Z":
                            break
                        time.sleep(0.02)
                    else:
                        self.fail("orphan curl is still running")
                    self.assertEqual(helper.stdout.read(), b"")
                finally:
                    if helper.poll() is None:
                        helper.kill()
                        helper.wait()
                    helper.stdout.close()
                    helper.stderr.close()


if __name__ == "__main__":
    unittest.main()
