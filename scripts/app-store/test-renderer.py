#!/usr/bin/env python3
"""Native composer integration tests; fixtures are synthetic and never uploadable."""

import json
import hashlib
import pathlib
import struct
import subprocess
import tempfile
import unittest
import zlib


SCRIPT = pathlib.Path(__file__).resolve().parent / "render.sh"


def png_fixture(path, width=2600, height=1200):
    """An intentionally artificial RGBA color grid, not a fabricated app UI."""
    def chunk(kind, payload):
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)
    # Alternating orange/navy strips verify an actual image gets composited.
    row = b"\0" + b"".join(bytes((14, 21, 33, 255) if (x // 100) % 2 else (194, 97, 31, 180)) for x in range(width))
    data = b"\x89PNG\r\n\x1a\n"
    data += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    data += chunk(b"IDAT", zlib.compress(row * height))
    data += chunk(b"IEND", b"")
    path.write_bytes(data)


class RendererTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="vektor-renderer-SYNTHETIC-TEST-")
        self.root = pathlib.Path(self.temp.name)
        self.raw = self.root / "SYNTHETIC-VERIFICATION-ONLY.png"
        png_fixture(self.raw)
        self.manifest = {
            "schemaVersion": 1,
            "canvas": {"width": 2880, "height": 1800},
            "style": {"background": "#F7F4EE", "ink": "#0E1521", "muted": "#7C766A", "accent": "#C2611F"},
            "frames": [{
                "id": "01-synthetic-test", "headline": "SYNTHETIC VERIFICATION ONLY", "subline": "Not app UI. Never upload this test image.",
                "capture": self.raw.name, "captureKind": "window", "appearance": "light",
                "expectedCapture": {"minWidth": 1800, "minHeight": 1000},
                "sourceTextSizePx": 26, "typedContent": "SYNTHETIC TEST GRID", "captureNotes": "Intentionally artificial RGBA grid.",
            }],
        }
        self.path = self.root / "test-manifest.json"

    def tearDown(self):
        self.temp.cleanup()

    def run_tool(self, *arguments):
        self.path.write_text(json.dumps(self.manifest))
        return subprocess.run([str(SCRIPT), "--manifest", str(self.path), *arguments], capture_output=True, text=True)

    def test_native_opaque_rgb_output_and_report(self):
        output = self.root / "finished-SYNTHETIC-ONLY"
        result = self.run_tool("--output", str(output))
        self.assertEqual(result.returncode, 0, result.stderr)
        image = (output / "01-synthetic-test.png").read_bytes()
        width, height, depth, color_type, *_ = struct.unpack(">IIBBBBB", image[16:29])
        self.assertEqual((width, height, depth, color_type), (2880, 1800, 8, 2))  # PNG RGB, no alpha.
        report = json.loads((output / "build-report.json").read_text())
        self.assertEqual(len(report["frames"]), 1)
        self.assertFalse(report["frames"][0]["alpha"])
        self.assertAlmostEqual(report["frames"][0]["scale"], 1190 / 1200)
        self.assertEqual(report["frames"][0]["rawSHA256"], hashlib.sha256(self.raw.read_bytes()).hexdigest())
        self.assertEqual(report["frames"][0]["outputSHA256"], hashlib.sha256(image).hexdigest())
        self.assertEqual(report["manifestSHA256"], hashlib.sha256(self.path.read_bytes()).hexdigest())
        self.assertTrue((output / "contact-sheet-review-only.png").exists())

    def test_validate_allows_pending_real_capture_but_render_refuses(self):
        self.manifest["frames"][0]["capture"] = "missing-real-capture.png"
        check = self.run_tool("--validate")
        self.assertEqual(check.returncode, 0, check.stderr)
        self.assertIn("PENDING CAPTURE", check.stdout)
        output = self.root / "must-not-exist"
        render = self.run_tool("--output", str(output))
        self.assertNotEqual(render.returncode, 0)
        self.assertIn("missing real capture", render.stderr)
        self.assertFalse(output.exists())

    def test_preflight_rejects_all_frames_before_any_export(self):
        second = dict(self.manifest["frames"][0], id="02-missing", capture="missing.png")
        self.manifest["frames"].append(second)
        output = self.root / "must-not-exist"
        result = self.run_tool("--output", str(output))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(output.exists())

    def test_output_cannot_overwrite_raw_directory(self):
        result = self.run_tool("--output", str(self.root))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("separate finished output", result.stderr)

    def test_rejects_mock_capture_duplicate_order_and_overflow_copy(self):
        self.manifest["frames"][0]["captureKind"] = "mock"
        self.assertNotEqual(self.run_tool("--validate").returncode, 0)
        self.manifest["frames"][0]["captureKind"] = "window"
        self.manifest["frames"].append(dict(self.manifest["frames"][0]))
        self.assertNotEqual(self.run_tool("--validate").returncode, 0)
        self.manifest["frames"].pop()
        self.manifest["frames"][0]["headline"] = "Too long " * 100
        result = self.run_tool("--validate")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("headline must fit", result.stderr)

    def test_rejects_tiny_or_unreadable_capture(self):
        png_fixture(self.raw, 1000, 600)
        result = self.run_tool("--check-captures")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("below", result.stderr)
        png_fixture(self.raw, 2880, 1800)
        result = self.run_tool("--check-captures")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("below 24 px", result.stderr)

    def test_capture_helper_refuses_overwrite_or_invalid_delay_without_capture(self):
        helper = SCRIPT.parent / "capture.sh"
        existing = subprocess.run([str(helper), "--region", str(self.raw)], capture_output=True, text=True)
        self.assertNotEqual(existing.returncode, 0)
        self.assertIn("Capture exists", existing.stderr)
        invalid = subprocess.run([str(helper), "--delay", "99", str(self.root / "unused.png")], capture_output=True, text=True)
        self.assertNotEqual(invalid.returncode, 0)
        self.assertIn("0 to 30", invalid.stderr)
        self.assertFalse((self.root / "unused.png").exists())


if __name__ == "__main__":
    unittest.main()
