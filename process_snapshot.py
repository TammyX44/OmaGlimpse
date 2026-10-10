#!/usr/bin/env python3
"""One bounded /proc snapshot; interval calculations belong to ProcessModel.js.

Only stat is read per PID, keeping name, starttime, CPU ticks and RSS in the
same kernel record. No cmdline/environment data or child CPU is collected.
The caller also enforces a three-second timeout with a kill-after deadline.
"""

import json
import os
from pathlib import Path
import sys
import time


MAX_PROCESSES = 16384
MAX_OUTPUT_BYTES = 8 * 1024 * 1024
MAX_FILE_BYTES = 65536
MAX_SECONDS = 2.0


def read_bounded(path):
    with path.open("rb") as stream:
        data = stream.read(MAX_FILE_BYTES + 1)
    if len(data) > MAX_FILE_BYTES:
        raise ValueError("proc record exceeds size limit")
    return data.decode("utf-8", errors="replace")


def parse_stat(raw, expected_pid, page_size):
    # comm may contain spaces, newlines, and parentheses. The final ')' is
    # the terminator; fields after it are fixed numeric/state fields.
    opening, closing = raw.find("("), raw.rfind(")")
    if opening < 1 or closing <= opening or raw[:opening].strip() != str(expected_pid):
        raise ValueError("invalid process stat")
    fields = raw[closing + 1:].split()
    if len(fields) < 22:
        raise ValueError("truncated process stat")
    user, system, start_time, rss = (int(fields[index]) for index in (11, 12, 19, 21))
    if min(user, system, start_time) < 0:
        raise ValueError("negative process counter")
    name = raw[opening + 1:closing]
    name = "".join(" " if ord(char) < 32 or ord(char) == 127 else char for char in name)[:256]
    return {"pid": str(expected_pid), "startTime": str(start_time), "name": name,
            "cpuTicks": user + system, "rssBytes": max(0, rss) * page_size}


def collect(proc_root=Path("/proc")):
    started = time.monotonic()
    memory_total = None
    for line in read_bounded(proc_root / "meminfo").splitlines():
        fields = line.split()
        if fields and fields[0] == "MemTotal:" and len(fields) == 3 and fields[2] == "kB":
            memory_total = int(fields[1]) * 1024
            break
    if not memory_total or memory_total < 0:
        raise ValueError("unable to read total memory")
    clock_ticks = os.sysconf("SC_CLK_TCK")
    page_size = os.sysconf("SC_PAGE_SIZE")
    if clock_ticks <= 0 or page_size <= 0:
        raise ValueError("invalid system units")
    processes, scanned = [], 0
    with os.scandir(proc_root) as entries:
        for entry in entries:
            if time.monotonic() - started > MAX_SECONDS:
                raise ValueError("process snapshot exceeded time limit")
            if not entry.name.isascii() or not entry.name.isdecimal():
                continue
            scanned += 1
            if scanned > MAX_PROCESSES:
                raise ValueError("process snapshot exceeded process limit")
            try:
                processes.append(parse_stat(read_bounded(Path(entry.path) / "stat"),
                                            int(entry.name), page_size))
            except (OSError, ValueError):
                # A PID can exit or become unreadable during enumeration.
                continue
    return {"version": 1, "sampledAt": started, "clockTicks": clock_ticks,
            "memoryTotalBytes": memory_total, "processes": processes}


def encode_snapshot(snapshot):
    output = json.dumps(snapshot, ensure_ascii=True, separators=(",", ":"))
    if len(output) > MAX_OUTPUT_BYTES:
        raise ValueError("process snapshot exceeded output limit")
    return output


def main():
    try:
        output = encode_snapshot(collect())
    except (OSError, ValueError) as error:
        print("Unable to read process data: " + str(error), file=sys.stderr)
        return 1
    print(output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
