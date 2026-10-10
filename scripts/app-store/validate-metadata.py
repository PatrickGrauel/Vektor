#!/usr/bin/env python3
"""Validate Vektor's English Connect copy and generate pasteable fields. Stdlib only."""
import argparse
import json
from pathlib import Path
import re
import sys

LIMITS = {"name": 30, "subtitle": 30, "promotionalText": 170, "description": 4000, "whatsNew": 4000}
LABELS = {"name": "App name", "subtitle": "Subtitle", "promotionalText": "Promotional text", "keywords": "Keywords", "description": "Description"}


def words(text):
    # Conservative English-only duplicate check, including simple plurals.
    tokens = re.findall(r"[a-z0-9]+", text.lower())
    return [t[:-1] if len(t) > 3 and t.endswith("s") and not t.endswith(("ss", "ics")) else t for t in tokens]


def validate(data):
    errors = []
    if data.get("schemaVersion") != 1:
        errors.append("schemaVersion must be 1")
    if data.get("locale") != "en-US":
        errors.append("This validator's duplicate normalization supports en-US only")
    for field, limit in LIMITS.items():
        value = data.get(field)
        if field == "whatsNew" and value is None:
            continue
        if not isinstance(value, str) or not value.strip():
            errors.append(f"{field}: expected a nonempty string")
        elif len(value) > limit:
            errors.append(f"{field}: {len(value)} characters exceeds {limit}")
    if isinstance(data.get("name"), str) and len(data["name"]) < 2:
        errors.append("name: minimum 2 characters")
    keywords = data.get("keywords", "")
    if not isinstance(keywords, str):
        errors.append("keywords: expected a comma-separated string")
        keywords = ""
    if len(keywords.encode("utf-8")) > 100:
        errors.append("keywords: exceeds 100 UTF-8 bytes")
    if not re.fullmatch(r"[a-z0-9]+(?:,[a-z0-9]+)*", keywords):
        errors.append("keywords: use lowercase ASCII single words separated by commas, no spaces")
    if any(len(item) <= 2 for item in keywords.split(",")):
        errors.append("keywords: each term must exceed two characters")
    seen = {}
    for field in ("name", "subtitle", "keywords"):
        value = data.get(field)
        if not isinstance(value, str):
            continue
        for token in words(value):
            if token in seen:
                errors.append(f"indexed word {token!r} repeated in {seen[token]} and {field}")
            seen[token] = field
            if token in {"soulver", "numi", "apple", "app", "free"}:
                errors.append(f"indexed word {token!r}: competitor/trademark/filler/price term")
    categories = words(str(data.get("primaryCategory", "")) + " " + str(data.get("secondaryCategory", "")))
    for token in words(keywords):
        if token in categories:
            errors.append(f"keyword {token!r} repeats a category")
    if data.get("whatsNewStatus") == "not_available_for_first_version":
        if data.get("whatsNew") is not None:
            errors.append("First release: whatsNew must be null; Apple has no upload field")
    elif data.get("whatsNew") is None:
        errors.append("Updates require actual What's New copy and an updated status")
    launch = data.get("launchReleaseNotes", "")
    if not isinstance(launch, str) or len(launch) > 4000:
        errors.append("launchReleaseNotes: expected text within 4000 characters")
    notes = data.get("reviewNotes", "")
    if not isinstance(notes, str) or len(notes.encode("utf-8")) > 4000:
        errors.append("reviewNotes: expected text within 4000 UTF-8 bytes")
    return errors


def listing(data):
    text = "# Vektor — Mac App Store listing\n\n"
    text += f"Canonical copy generated from [metadata.json](app-store/metadata.json). Locale **{data['locale']}**; version **{data['version']}**. Apple requirements verified **11 October 2026**.\n\n"
    text += "Run `python3 scripts/app-store/validate-metadata.py --check-listing docs/app-store-listing.md` after changes. [Positioning and capture recipes](app-store/product-page.md), [preview storyboard](app-store/app-preview.md), [Apple sources](app-store/apple-specs.md), [code audit](app-store/code-audit.md), [production tooling](app-store/tooling.md).\n\n"
    for field, label in LABELS.items():
        value = data[field]
        count = len(value.encode("utf-8")) if field == "keywords" else len(value)
        limit = 100 if field == "keywords" else LIMITS[field]
        unit = "bytes" if field == "keywords" else "characters"
        text += f"## {label} — {count}/{limit} {unit}\n\n```text\n{value}\n```\n\n"
    if data.get("whatsNew") is None:
        value = data["launchReleaseNotes"]
        text += "## What's New — unavailable for the first release\n\nApple does not expose this field for version 1.0.0's initial release. Leave it absent. This launch blurb is for a changelog or release announcement, **not** a Connect upload:\n\n"
        text += f"```text\n{value}\n```\n\n{len(value)}/4000 characters. For a later update, write the actual changes in that build; do not reuse a launch announcement.\n\n"
    else:
        value = data["whatsNew"]
        text += f"## What's New — {len(value)}/4000 characters\n\n```text\n{value}\n```\n\n"
    text += f"## Private App Review notes — {len(data['reviewNotes'].encode('utf-8'))}/4000 bytes\n\n```text\n{data['reviewNotes']}\n```\n\n"
    text += "## Remaining Connect fields\n\nPrimary category: **Productivity**. Secondary: **Utilities**. Copyright: **© 2026 Patrick Grauel**. Minimum OS: **macOS 14.0** (from project.yml). Complete the current age-rating questionnaire; 4+ is a candidate, not a verified rating.\n\n"
    text += "Confirm real support and privacy destinations in the account. The earlier drafts disagree between vektor.app and GitHub Pages, and contain a placeholder email. Do not upload placeholders. Store price, territory availability, release timing and IAP state are not known from this repository. Keep public copy price-neutral until the final build and account configuration agree.\n\n"
    text += "Do not select Data Not Collected solely from the privacy manifest. Review the release SDKs and providers' retention/processing, and correct the hosted policy; see the code audit. This package does not publish to App Store Connect.\n"
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    root = Path(__file__).resolve().parents[2]
    parser.add_argument("metadata", nargs="?", type=Path, default=root / "docs/app-store/metadata.json")
    parser.add_argument("--write-listing", type=Path)
    parser.add_argument("--check-listing", type=Path)
    parser.add_argument("--export-dir", type=Path)
    args = parser.parse_args()
    try:
        data = json.loads(args.metadata.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            raise ValueError("Metadata must be a JSON object")
        errors = validate(data)
        if errors:
            for error in errors:
                print(f"ERROR: {error}", file=sys.stderr)
            return 1
        generated = listing(data)
        if args.check_listing and args.check_listing.read_text(encoding="utf-8") != generated:
            print("ERROR: listing differs from metadata; regenerate with --write-listing", file=sys.stderr)
            return 1
        if args.write_listing:
            args.write_listing.parent.mkdir(parents=True, exist_ok=True)
            args.write_listing.write_text(generated, encoding="utf-8")
        if args.export_dir:
            args.export_dir.mkdir(parents=True, exist_ok=True)
            for field in (*LABELS, "whatsNew", "reviewNotes"):
                if data.get(field) is not None:
                    (args.export_dir / f"{field}.txt").write_text(data[field], encoding="utf-8")
        for field in (*LABELS, "whatsNew"):
            value = data.get(field)
            if value is None:
                print(f"{field}: absent (first release)")
            else:
                unit = "bytes" if field == "keywords" else "characters"
                count = len(value.encode("utf-8")) if field == "keywords" else len(value)
                print(f"{field}: {count} {unit}")
        print("PASS: limits, ASCII keyword bytes, indexed-word deduplication and release-note state")
        return 0
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
