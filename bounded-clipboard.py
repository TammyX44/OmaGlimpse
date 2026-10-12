#!/usr/bin/env python3
"""Explicit, bounded Wayland text paste. Never invoke this to probe availability.

Both MIME discovery and content collection share a monotonic two-second deadline.
No clipboard contents or subprocess diagnostics are written to stderr. The only
stdout is one bounded UTF-8 JSON response; failed/partial reads expose no text.
"""

import argparse
import ctypes
import json
import os
import selectors
import signal
import subprocess
import sys
import time


MAX_BYTES = 16 * 1024
MAX_RESPONSE_BYTES = 2 * MAX_BYTES + 128
TIMEOUT = 2.0
_cancelled = False


class PasteError(Exception):
    pass


def cancel(_signum, _frame):
    # Do not raise inside Popen: cancellation between fork and assignment could
    # otherwise lose the only handle to the new child's process group.
    global _cancelled
    _cancelled = True


def check_deadline(deadline):
    if _cancelled:
        raise PasteError("cancelled")
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise PasteError("timeout")
    return remaining


def kill_group(process):
    # Include descendants even when the wl-paste group leader already exited.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=0.2)
    except subprocess.TimeoutExpired:
        pass


def provider_worker(parent, status_fd, arguments):
    """Own the provider group even if the outer helper is forcibly killed.

    This supervisor and wl-paste share a session/group. Linux parent-death TERM
    kills that entire group, including descendants which ignore TERM. The outer
    helper never relies on a provider honoring a cancellation signal.
    """
    def kill_owned_group(_signum=None, _frame=None):
        os.killpg(os.getpgrp(), signal.SIGKILL)

    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(signum, kill_owned_group)
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(1, signal.SIGTERM, 0, 0, 0) != 0:
        return 127
    if os.getppid() != parent:
        kill_owned_group()
    try:
        provider = subprocess.Popen(
            ["wl-paste", *arguments], stdin=subprocess.DEVNULL,
            stdout=sys.stdout.buffer, stderr=subprocess.DEVNULL,
        )
    except OSError:
        status = 127
    else:
        status = provider.wait()
    # Report a bounded status separately from clipboard stdout. Stay alive
    # after the leader exits: descendants may still own stdout, and parent-death
    # cleanup must remain armed until the outer helper kills this whole group.
    os.write(status_fd, (str(status) + "\n").encode("ascii"))
    os.close(status_fd)
    os.close(sys.stdout.fileno())
    while True:
        signal.pause()


def collect(arguments, deadline):
    check_deadline(deadline)
    status_read, status_write = os.pipe2(os.O_CLOEXEC | os.O_NONBLOCK)
    try:
        process = subprocess.Popen(
            [sys.executable, os.path.abspath(__file__), "--worker", str(os.getpid()), str(status_write), *arguments],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            start_new_session=True, pass_fds=(status_write,),
        )
    except OSError:
        os.close(status_read)
        raise PasteError("unavailable") from None
    finally:
        os.close(status_write)
    data = bytearray()
    try:
        os.set_blocking(process.stdout.fileno(), False)
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ, "stdout")
            selector.register(status_read, selectors.EVENT_READ, "status")
            eof = False
            status_data = bytearray()
            provider_status = None
            while True:
                remaining = check_deadline(deadline)
                if eof and provider_status is not None:
                    if provider_status == 127:
                        raise PasteError("unavailable")
                    if provider_status != 0:
                        raise PasteError("failed")
                    return bytes(data)
                for key, _events in selector.select(min(0.05, remaining)):
                    if key.data == "status":
                        chunk = os.read(status_read, 17 - len(status_data))
                        status_data.extend(chunk)
                        if len(status_data) > 16:
                            raise PasteError("failed")
                        if b"\n" in status_data:
                            try:
                                provider_status = int(status_data.decode("ascii").strip())
                            except (UnicodeError, ValueError):
                                raise PasteError("failed") from None
                            selector.unregister(status_read)
                        elif not chunk:
                            raise PasteError("failed")
                        continue
                    try:
                        chunk = os.read(process.stdout.fileno(), min(4096, MAX_BYTES + 1 - len(data)))
                    except BlockingIOError:
                        continue
                    if not chunk:
                        eof = True
                        selector.unregister(process.stdout)
                    else:
                        data.extend(chunk)
                        if len(data) > MAX_BYTES:
                            raise PasteError("oversize")
    finally:
        kill_group(process)
        process.stdout.close()
        os.close(status_read)


def plain_type(raw):
    try:
        offered = raw.decode("ascii", "strict").splitlines()
    except UnicodeError:
        raise PasteError("wrong-kind") from None
    # Request an exact MIME, never wl-paste's generic "text" conversion (which
    # can select HTML, URI lists or other non-plain payloads).
    for preferred in ("text/plain;charset=utf-8", "utf8_string", "text/plain"):
        for mime in offered:
            if mime.lower() == preferred:
                return mime
    raise PasteError("wrong-kind")


def normalize_single_line(text, maximum):
    # Unicode line/paragraph separators, CRLF and tabs become a single space;
    # remove remaining control codes, including NUL and terminal escapes.
    result = []
    previous_cr = False
    for char in text:
        if char == "\n" and previous_cr:
            previous_cr = False
            continue
        previous_cr = char == "\r"
        code = ord(char)
        if char in "\r\n\t\v\f\x85\u2028\u2029":
            char = " "
        elif code < 32 or 127 <= code < 160:
            continue
        if len(result) >= maximum:
            break
        result.append(char)
    return "".join(result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--max-length", type=int, default=MAX_BYTES)
    args = parser.parse_args()
    if not 0 <= args.max_length <= MAX_BYTES:
        parser.error("--max-length must be between 0 and 16384")
    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(signum, cancel)
    # On Linux, parent termination also requests cancellation. Normal QML
    # cancellation sends TERM; this additionally covers its parent disappearing.
    parent = os.getppid()
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        libc.prctl(1, signal.SIGTERM, 0, 0, 0)  # PR_SET_PDEATHSIG
        if os.getppid() != parent:
            cancel(None, None)
    except (AttributeError, OSError):
        pass
    deadline = time.monotonic() + TIMEOUT
    try:
        mime = plain_type(collect(["--list-types"], deadline))
        raw = collect(["--no-newline", "--type", mime], deadline)
        try:
            decoded = raw.decode("utf-8", "strict")
        except UnicodeError:
            raise PasteError("invalid-utf8") from None
        text = normalize_single_line(decoded, args.max_length)
        check_deadline(deadline)
        result = {"version": 1, "ok": True, "text": text}
        status = 0
    except PasteError as error:
        result = {"version": 1, "ok": False, "error": str(error)}
        status = 1
    encoded = (json.dumps(result, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
    if len(encoded) > MAX_RESPONSE_BYTES:
        encoded = b'{"version":1,"ok":false,"error":"oversize"}\n'
        status = 1
    try:
        sys.stdout.buffer.write(encoded)
        sys.stdout.buffer.flush()
    except BrokenPipeError:
        return 1
    return status


if __name__ == "__main__":
    if len(sys.argv) >= 4 and sys.argv[1] == "--worker":
        sys.exit(provider_worker(int(sys.argv[2]), int(sys.argv[3]), sys.argv[4:]))
    sys.exit(main())
