"""Exercise the real fetcher against a local TLS server with hostile responses."""

import base64
import http.server
import os
from pathlib import Path
import signal
import socketserver
import subprocess
import tempfile
import threading
import unittest


HELPER = Path(__file__).resolve().parents[1] / "fetch_album_art.py"
PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9kMzAAAAAASUVORK5CYII="
)


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
        elif self.path == "/dimensions":
            body = PNG[:16] + (100000).to_bytes(4, "big") + PNG[20:]
        else:
            body = PNG
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
            from urllib.parse import urlsplit, unquote
            local = Path(unquote(urlsplit(result.stdout.strip()).path))
            self.assertEqual(local.read_bytes(), PNG)
            self.assertLessEqual(local.stat().st_size, 1048576)
            self.assertEqual(local.parent.stat().st_mode & 0o077, 0)

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
