import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('media_snapshot', Path(__file__).resolve().parents[1] / 'media_snapshot.py')
media = importlib.util.module_from_spec(spec)
spec.loader.exec_module(media)


def payload(position=0, length=180000000):
    metadata = {'xesam:title': {'type': 's', 'data': 'Track'}}
    if length is not None:
        metadata['mpris:length'] = {'type': 'x', 'data': length}
    return {'data': [{'Position': {'type': 'x', 'data': position},
                      'Metadata': {'data': metadata},
                      'PlaybackStatus': {'data': 'Playing'}, 'Rate': {'data': 1.5}}]}


class TimingTests(unittest.TestCase):
    def test_repeat_is_read_without_track_change(self):
        before = media.parse(payload(179000000))
        after = media.parse(payload(250000))
        self.assertEqual(before['title'], after['title'])
        self.assertEqual(before['length'], after['length'])
        self.assertEqual(after['position'], 0.25)
        self.assertEqual(after['rate'], 1.5)

    def test_late_duration_and_missing_duration(self):
        self.assertEqual(media.parse(payload(length=None))['length'], 0)
        self.assertEqual(media.parse(payload(length=245000000))['length'], 245)

    def test_invalid_timing_is_not_a_duration(self):
        for value in (-1, float('nan'), float('inf'), True, '123'):
            self.assertEqual(media.parse(payload(length=value))['length'], 0)
            self.assertIsNone(media.parse(payload(position=value))['position'])

    def test_rejects_non_mpris_service(self):
        self.assertIsNone(media.snapshot('org.freedesktop.DBus'))


if __name__ == '__main__':
    unittest.main()
