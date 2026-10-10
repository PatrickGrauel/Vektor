#!/usr/bin/env python3
"""Check a Mac App Preview's ffprobe data against the chosen H.264/AAC profile."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
from fractions import Fraction


def probe(file):
    binary = shutil.which("ffprobe")
    if binary is None:
        raise RuntimeError("ffprobe is required (install ffmpeg from a trusted package source)")
    result = subprocess.run([binary, "-v", "error", "-show_streams", "-show_format", "-of", "json", str(file)], capture_output=True, text=True, check=True)
    return json.loads(result.stdout)


def check(data, size_bytes, source=False):
    errors, warnings = [], []
    streams = data.get("streams", [])
    video = [s for s in streams if s.get("codec_type") == "video"]
    audio = [s for s in streams if s.get("codec_type") == "audio"]
    duration = float(data.get("format", {}).get("duration", 0))
    if not 15 <= duration <= 30:
        errors.append(f"container duration {duration:.3f}s outside 15–30s")
    if len(video) != 1:
        errors.append("Exactly one video track is required by this production profile")
        return errors, warnings
    track = video[0]
    video_duration = float(track.get("duration", duration))
    if not 15 <= video_duration <= 30:
        errors.append(f"video duration {video_duration:.3f}s outside 15–30s")
    if abs(video_duration - duration) > 0.1:
        errors.append("Video/container durations differ by more than 0.1s")
    if (track.get("width"), track.get("height")) != (1920, 1080):
        errors.append("Mac preview must be 1920x1080; export does not stretch or crop footage")
    rotation = float(track.get("tags", {}).get("rotate", 0))
    rotations = [s.get("rotation", 0) for s in track.get("side_data_list", [])]
    if rotation != 0 or any(float(r) != 0 for r in rotations):
        errors.append("Rotation metadata must be zero for landscape Mac footage")
    if track.get("sample_aspect_ratio") not in ("1:1", None):
        errors.append("Expected square pixels; normalize display geometry in the editor")
    if track.get("field_order") != "progressive":
        errors.append("Video must be progressive; verify/export a progressive timeline")
    for field in ("color_primaries", "color_transfer", "color_space"):
        value = track.get(field)
        if value not in (None, "unknown", "bt709"):
            errors.append(f"Expected BT.709 SDR master; {field}={value!r} requires actual color conversion in the editor")
    if any(track.get(field) in (None, "unknown") for field in ("color_primaries", "color_transfer", "color_space")):
        warnings.append("Missing SDR/BT.709 tags; verify the editor timeline color space before encoding")
    if source:
        return errors, warnings
    if size_bytes > 500_000_000:
        errors.append("File exceeds conservative decimal 500 MB maximum")
    if track.get("codec_name") != "h264":
        errors.append("Expected H.264 for this production profile (Apple also permits ProRes)")
    if track.get("profile") != "High" or not 0 < int(track.get("level", 0)) <= 40:
        errors.append("Expected High Profile at or below Level 4.0")
    if track.get("pix_fmt") != "yuv420p":
        errors.append("Expected 8-bit yuv420p")
    average = Fraction(track.get("avg_frame_rate", "0/1"))
    nominal = Fraction(track.get("r_frame_rate", "0/1"))
    if not 0 < average <= 30 or not 0 < nominal <= 30:
        errors.append("Frame rate must be positive and at most 30 fps")
    if average != nominal or average != 30:
        errors.append("This kit exports constant 30 fps; average/nominal rates must both be 30")
    if len(audio) != 1:
        errors.append("Expected one stereo AAC audio track in this production profile")
    else:
        sound = audio[0]
        if sound.get("codec_name") != "aac" or sound.get("channels") != 2:
            errors.append("Audio must be stereo AAC")
        if int(sound.get("sample_rate", 0)) not in (44100, 48000):
            errors.append("Audio sample rate must be 44.1 or 48 kHz")
        audio_rate = int(sound.get("bit_rate", 0))
        if not 240_000 <= audio_rate <= 272_000:
            # Encoded silence often needs fewer bits even with -b:a 256k.
            warnings.append(f"Audio reports {audio_rate} bps; encoder must be set to AAC 256 kbps (silence may compress lower)")
        sound_duration = float(sound.get("duration", video_duration))
        if abs(sound_duration - video_duration) > 0.1:
            errors.append("Audio/video durations differ by more than 0.1s")
    bitrate = int(track.get("bit_rate", 0))
    if not 10_000_000 <= bitrate <= 12_000_000:
        warnings.append(f"Video reports {bitrate} bps; Apple's target is 10–12 Mbps, not a guaranteed rate for static UI")
    if len(streams) != len(video) + len(audio):
        errors.append("Unexpected subtitle/data/extra tracks; export only enabled video and audio")
    formats = set(data.get("format", {}).get("format_name", "").split(","))
    if not formats.intersection({"mov", "mp4", "m4v"}):
        errors.append("Expected MOV/M4V/MP4 container")
    return errors, warnings


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("video", type=Path)
    parser.add_argument("--source", action="store_true", help="Check edited timeline dimensions/duration before encoding")
    args = parser.parse_args()
    try:
        if not args.source and args.video.suffix.lower() not in {".mov", ".mp4", ".m4v"}:
            raise ValueError("Use .mov, .mp4 or .m4v")
        errors, warnings = check(probe(args.video), args.video.stat().st_size, args.source)
        for item in warnings:
            print(f"REVIEW: {item}")
        for item in errors:
            print(f"ERROR: {item}", file=sys.stderr)
        if errors:
            return 1
        print("PASS: source geometry/duration/progressive/SDR checks" if args.source else "PASS: checked local Mac preview profile; inspect visuals/audio and Connect processing separately")
        return 0
    except (OSError, RuntimeError, ValueError, TypeError, ZeroDivisionError, subprocess.CalledProcessError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
