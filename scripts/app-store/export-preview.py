#!/usr/bin/env python3
"""Encode an edited 1080p timeline as Vektor's conservative Mac App Preview profile."""
import argparse
import importlib.util
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="Edited screen-capture timeline, 1920x1080, 15–30 seconds")
    parser.add_argument("output", type=Path, help="New .mp4 destination; never overwrites")
    args = parser.parse_args()
    try:
        ffmpeg = shutil.which("ffmpeg")
        if ffmpeg is None:
            raise RuntimeError("ffmpeg is required (install from a trusted package source)")
        if args.output.suffix.lower() != ".mp4":
            raise ValueError("This exporter writes .mp4")
        if args.output.exists():
            raise ValueError("Output exists; choose a new path")
        spec = importlib.util.spec_from_file_location("preview_validator", Path(__file__).with_name("validate-preview.py"))
        validator = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(validator)
        data = validator.probe(args.source)
        errors, warnings = validator.check(data, args.source.stat().st_size, source=True)
        for item in warnings:
            print(f"REVIEW: {item}")
        if errors:
            raise ValueError("; ".join(errors))
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="vektor-preview-", dir=args.output.parent) as temp:
            encoded = Path(temp) / "preview.mp4"
            subprocess.run([
                ffmpeg, "-hide_banner", "-nostdin", "-n", "-i", str(args.source),
                "-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=48000",
                "-map", "0:v:0", "-map", "1:a:0", "-map_metadata", "-1", "-sn", "-dn",
                "-vf", "setsar=1", "-r", "30", "-fps_mode", "cfr",
                "-c:v", "libx264", "-preset", "slow", "-profile:v", "high", "-level:v", "4.0",
                "-pix_fmt", "yuv420p", "-field_order", "progressive",
                "-b:v", "11M", "-maxrate", "12M", "-bufsize", "24M", "-g", "60",
                "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
                "-c:a", "aac", "-b:a", "256k", "-ar", "48000", "-ac", "2",
                "-shortest", "-movflags", "+faststart", str(encoded)
            ], check=True)
            errors, warnings = validator.check(validator.probe(encoded), encoded.stat().st_size)
            for item in warnings:
                print(f"REVIEW: {item}")
            if errors:
                raise ValueError("Encoded file failed: " + "; ".join(errors))
            # Exclusive destination creation keeps an intervening file safe.
            with args.output.open("xb") as target, encoded.open("rb") as source:
                shutil.copyfileobj(source, target)
        print(f"Created {args.output}; no source audio retained, stereo silence added. Watch the full file before upload.")
        return 0
    except (OSError, RuntimeError, ValueError, TypeError, subprocess.CalledProcessError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
