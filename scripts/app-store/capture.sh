#!/bin/bash
set -euo pipefail

# Select the real window interactively; never changes Vektor documents/settings.
capture_mode="window"
capture_delay=0
while [[ "${1:-}" == --* ]]; do
    case "$1" in
        --region)
            capture_mode="region"
            shift
            ;;
        --delay)
            if [[ ! "${2:-}" =~ ^([0-9]|[12][0-9]|30)$ ]]; then
                echo "--delay requires an integer number of seconds from 0 to 30." >&2
                exit 1
            fi
            capture_delay="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done
if [[ "$#" -ne 1 ]]; then
    echo "Usage: scripts/app-store/capture.sh [--region] [--delay 5] artifacts/app-store/raw/01-topic.png" >&2
    echo "Uses macOS window selection. Press Escape to cancel." >&2
    exit 1
fi
capture_path="$1"
if [[ "$capture_path" != *.png ]]; then
    echo "Capture filename must end in .png." >&2
    exit 1
fi
if [[ -e "$capture_path" ]]; then
    echo "Capture exists: $capture_path. Keep the original or choose a new filename." >&2
    exit 1
fi
mkdir -p "$(dirname "$capture_path")"
if [[ "$capture_delay" -gt 0 ]]; then
    echo "Selection starts in $capture_delay seconds. Refocus Vektor and reopen its popover now."
    sleep "$capture_delay"
fi
if [[ "$capture_mode" == "region" ]]; then
    echo "Drag around the real Vektor panel and its popover; include all results. Escape cancels."
    /usr/sbin/screencapture -i -s -t png "$capture_path"
else
    echo "Click the actual Vektor window; choose a wide/short Retina window. Escape cancels."
    /usr/sbin/screencapture -i -W -o -t png "$capture_path"
fi
if [[ ! -s "$capture_path" ]]; then
    echo "No capture created (selection cancelled or permission unavailable)." >&2
    exit 1
fi
echo "Saved actual window pixels to $capture_path. Run --check-captures and visually inspect before rendering."
