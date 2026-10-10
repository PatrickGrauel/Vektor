#!/usr/bin/env python3
"""Boundary/negative tests for Connect copy and ffprobe validation; no app/network/encoder required."""
import copy
import importlib.util
import json
from pathlib import Path
import sys
import unittest

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


def load(filename, name):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


metadata = load("validate-metadata.py", "metadata_checker")
preview = load("validate-preview.py", "preview_checker")


def valid_probe():
    # Probe-data fixture only; never used to create or represent actual footage.
    return {
        "format": {"duration": "24.000", "format_name": "mov,mp4,m4a,3gp,3g2,mj2"},
        "streams": [
            {"codec_type": "video", "codec_name": "h264", "profile": "High", "level": 40,
             "width": 1920, "height": 1080, "duration": "24.000", "pix_fmt": "yuv420p",
             "field_order": "progressive", "avg_frame_rate": "30/1", "r_frame_rate": "30/1",
             "sample_aspect_ratio": "1:1", "bit_rate": "11000000", "color_primaries": "bt709",
             "color_transfer": "bt709", "color_space": "bt709"},
            {"codec_type": "audio", "codec_name": "aac", "channels": 2, "sample_rate": "48000",
             "duration": "24.000", "bit_rate": "256000"}
        ]
    }


class MetadataChecks(unittest.TestCase):
    def setUp(self):
        self.data = json.loads((ROOT / "docs/app-store/metadata.json").read_text())

    def test_production_copy_and_generated_listing_agree(self):
        self.assertEqual(metadata.validate(self.data), [])
        self.assertEqual(metadata.listing(self.data), (ROOT / "docs/app-store-listing.md").read_text())

    def test_rejects_field_overflow(self):
        for field, limit in metadata.LIMITS.items():
            with self.subTest(field=field):
                changed = copy.deepcopy(self.data)
                changed[field] = "x" * (limit + 1)
                self.assertTrue(any("exceeds" in e for e in metadata.validate(changed)))

    def test_keywords_limit_is_bytes_not_characters(self):
        self.data["keywords"] = "é" * 51
        self.assertTrue(any("100 UTF-8 bytes" in e for e in metadata.validate(self.data)))

    def test_duplicate_case_plural_and_cross_field_words(self):
        for changed in ({"keywords": "calculator"}, {"subtitle": "Calculator"}, {"keywords": "unit,units"}):
            with self.subTest(changed=changed):
                data = self.data | changed
                self.assertTrue(any("repeated" in e for e in metadata.validate(data)))

    def test_competitor_category_and_whitespace_keywords_rejected(self):
        for keyword in ("soulver", "numi", "productivity", "unit converter"):
            with self.subTest(keyword=keyword):
                self.assertTrue(metadata.validate(self.data | {"keywords": keyword}))

    def test_first_release_notes_cannot_be_uploaded(self):
        self.assertIsNone(self.data["whatsNew"])
        self.assertTrue(metadata.validate(self.data | {"whatsNew": "Initial release."}))

    def test_update_needs_real_release_notes(self):
        data = self.data | {"version": "1.0.1", "whatsNewStatus": "update"}
        self.assertTrue(metadata.validate(data))
        self.assertEqual(metadata.validate(data | {"whatsNew": "Corrected the saved-sheet pin behavior."}), [])


class PreviewChecks(unittest.TestCase):
    def test_chosen_healthy_profile(self):
        self.assertEqual(preview.check(valid_probe(), 40_000_000), ([], []))

    def test_wrong_retina_geometry_is_not_silently_resized(self):
        data = valid_probe()
        data["streams"][0]["width"] = 2880
        self.assertTrue(preview.check(data, 40_000_000, source=True)[0])

    def test_short_video_cannot_hide_behind_long_audio(self):
        data = valid_probe()
        data["streams"][0]["duration"] = "10.000"
        self.assertTrue(preview.check(data, 40_000_000)[0])

    def test_duration_endpoints_and_maximum_file_size(self):
        for seconds in (15, 30):
            data = valid_probe()
            data["format"]["duration"] = str(seconds)
            for stream in data["streams"]:
                stream["duration"] = str(seconds)
            self.assertEqual(preview.check(data, 500_000_000), ([], []))
        self.assertTrue(preview.check(valid_probe(), 500_000_001)[0])

    def test_source_rotation_non_square_hdr_and_interlace_rejected(self):
        for changed in ({"tags": {"rotate": "90"}}, {"side_data_list": [{"rotation": -90}]},
                        {"sample_aspect_ratio": "4:3"}, {"color_transfer": "smpte2084"},
                        {"color_primaries": "bt2020"}, {"field_order": "tt"}):
            with self.subTest(changed=changed):
                data = valid_probe()
                data["streams"][0].update(changed)
                self.assertTrue(preview.check(data, 40_000_000, source=True)[0])

    def test_frame_rate_codec_and_extra_tracks_rejected(self):
        for changed in ({"r_frame_rate": "60/1"}, {"avg_frame_rate": "30000/1001"},
                        {"codec_name": "hevc"}, {"level": 41}):
            with self.subTest(changed=changed):
                data = valid_probe()
                data["streams"][0].update(changed)
                self.assertTrue(preview.check(data, 40_000_000)[0])
        data = valid_probe()
        data["streams"].append({"codec_type": "subtitle"})
        self.assertTrue(preview.check(data, 40_000_000)[0])

    def test_audio_alignment_channels_sample_rate_rejected(self):
        for changed in ({"channels": 1}, {"duration": "23.000"}, {"sample_rate": "22050"}):
            with self.subTest(changed=changed):
                data = valid_probe()
                data["streams"][1].update(changed)
                self.assertTrue(preview.check(data, 40_000_000)[0])

    def test_low_static_and_silent_bitrates_need_review(self):
        data = valid_probe()
        data["streams"][0]["bit_rate"] = "900000"
        data["streams"][1]["bit_rate"] = "2000"
        errors, warnings = preview.check(data, 40_000_000)
        self.assertEqual(errors, [])
        self.assertEqual(len(warnings), 2)


if __name__ == "__main__":
    unittest.main()
