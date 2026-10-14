#!/usr/bin/env python3
"""Read a bounded, fresh MPRIS timing snapshot (seconds, not microseconds)."""
import json
import math
import resource
import subprocess
import sys
import tempfile


def seconds(value):
    if not isinstance(value, dict) or value.get('type') not in ('x', 't'):
        return None
    raw = value.get('data')
    if isinstance(raw, bool) or not isinstance(raw, (int, float)) or not math.isfinite(raw) or raw < 0:
        return None
    return raw / 1_000_000


def parse(payload):
    properties = payload['data'][0]
    metadata = properties.get('Metadata', {}).get('data', {})
    position = seconds(properties.get('Position'))
    length = seconds(metadata.get('mpris:length'))
    rate = properties.get('Rate', {}).get('data', 1)
    if not isinstance(rate, (int, float)) or not math.isfinite(rate) or rate < 0:
        rate = 1
    return dict(position=position, length=length if length and length > 0 else 0,
                title=str(metadata.get('xesam:title', {}).get('data', ''))[:4096],
                trackId=str(metadata.get('mpris:trackid', {}).get('data', ''))[:4096],
                rate=rate, playing=properties.get('PlaybackStatus', {}).get('data') == 'Playing')


def snapshot(service):
    if not service.startswith('org.mpris.MediaPlayer2.') or len(service) > 255:
        return None
    # A foreign player can return arbitrarily large metadata. Bound busctl's
    # output before loading JSON, and its lifetime even if the player hangs.
    with tempfile.TemporaryFile() as output:
        def limits():
            resource.setrlimit(resource.RLIMIT_FSIZE, (65536, 65536))
        result = subprocess.run(['busctl', '--user', '--json=short', '--timeout=1',
                                 'call', service, '/org/mpris/MediaPlayer2',
                                 'org.freedesktop.DBus.Properties', 'GetAll', 's',
                                 'org.mpris.MediaPlayer2.Player'],
                                stdin=subprocess.DEVNULL, stdout=output,
                                stderr=subprocess.DEVNULL, timeout=2, preexec_fn=limits)
        if result.returncode:
            return None
        output.seek(0)
        return parse(json.load(output))


if __name__ == '__main__':
    try:
        result = snapshot(sys.argv[1]) if len(sys.argv) == 2 else None
        if result is not None:
            print(json.dumps(result, allow_nan=False))
            sys.exit(0)
    except (OSError, ValueError, KeyError, IndexError, TypeError, AttributeError, subprocess.TimeoutExpired):
        pass
    sys.exit(1)
