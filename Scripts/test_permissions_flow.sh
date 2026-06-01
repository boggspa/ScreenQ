#!/usr/bin/env bash
#
# test_permissions_flow.sh
#
# Resets the macOS TCC entries for Screen Q, rebuilds Debug for macOS,
# and launches the app so you can walk the on-screen permission flow
# from a clean slate.
#
# Usage:
#   Scripts/test_permissions_flow.sh           # reset + build + launch
#   Scripts/test_permissions_flow.sh --no-build  # skip rebuild
#   Scripts/test_permissions_flow.sh --reset-only
#
# After it launches Screen Q you should see (in order):
#   1. Permission row "Screen Recording" with a blue "Allow…" button.
#   2. macOS system prompt appears. Click "Allow" or "Don't Allow".
#      - "Don't Allow" → row changes to "Open System Settings" +
#         "Quit & Relaunch" once you flip the toggle in System Settings.
#      - "Allow" → row collapses to a green "Granted" badge after a
#         brief poll (1s) and HostMacView's red banner disappears.
#   3. Repeat for Accessibility.
#   4. The host card should never feel "stuck" or loop on a single
#      button. Disconnect / Reconnect cycles should not re-trigger the
#      prompt; quit and relaunch must.

set -euo pipefail

BUNDLE_ID="${SCREENQ_BUNDLE_ID:-com.chrisizatt.Screen-Q}"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="${PROJECT_DIR}/Screen Q.xcodeproj"
SCHEME="Screen Q"
CONFIG="Debug"

DO_BUILD=1
DO_LAUNCH=1

for arg in "$@"; do
    case "${arg}" in
    --no-build)    DO_BUILD=0 ;;
    --reset-only)  DO_BUILD=0; DO_LAUNCH=0 ;;
    -h|--help)
        sed -n '2,20p' "$0"
        exit 0
        ;;
    *)
        echo "Unknown argument: ${arg}" >&2
        exit 2
        ;;
    esac
done

echo "==> Resetting TCC entries for ${BUNDLE_ID}"
tccutil reset ScreenCapture "${BUNDLE_ID}" 2>/dev/null \
    && echo "    Screen Recording: reset" \
    || echo "    Screen Recording: nothing to reset"
tccutil reset Accessibility "${BUNDLE_ID}" 2>/dev/null \
    && echo "    Accessibility: reset" \
    || echo "    Accessibility: nothing to reset"

# Clear the persisted "we already asked" flags in the app's UserDefaults
# so the flow really starts from zero. (Safe to ignore if the app has
# never run.)
echo "==> Clearing persisted permission-request flags"
defaults delete "${BUNDLE_ID}" "ScreenQ.Permissions.ScreenRecording.RequestedBefore" 2>/dev/null \
    && echo "    Screen Recording: cleared" \
    || echo "    Screen Recording: not set"
defaults delete "${BUNDLE_ID}" "ScreenQ.Permissions.Accessibility.RequestedBefore" 2>/dev/null \
    && echo "    Accessibility: cleared" \
    || echo "    Accessibility: not set"

if [[ "${DO_BUILD}" -eq 1 ]]; then
    echo "==> Building ${SCHEME} (${CONFIG}, macOS)"
    xcodebuild \
        -project "${PROJECT}" \
        -scheme  "${SCHEME}" \
        -destination "generic/platform=macOS" \
        -configuration "${CONFIG}" \
        build \
        | tail -n 5
fi

if [[ "${DO_LAUNCH}" -eq 1 ]]; then
    APP_PATH="$(xcodebuild \
        -project "${PROJECT}" \
        -scheme  "${SCHEME}" \
        -destination "generic/platform=macOS" \
        -configuration "${CONFIG}" \
        -showBuildSettings 2>/dev/null \
        | awk -F' = ' '/CODESIGNING_FOLDER_PATH/ { print $2; exit }')"

    if [[ -z "${APP_PATH}" || ! -d "${APP_PATH}" ]]; then
        echo "Could not resolve built .app path; open Xcode and run manually." >&2
        exit 1
    fi

    echo "==> Killing any running ${SCHEME} so the next launch is from scratch"
    pkill -x "${SCHEME}" 2>/dev/null || true
    sleep 0.5

    echo "==> Launching ${APP_PATH}"
    open -a "${APP_PATH}"
    echo
    echo "Walk through the on-screen flow:"
    echo "  1. Click Allow… → choose Allow / Don't Allow at the system prompt."
    echo "  2. Toggle System Settings if needed (Open System Settings button)."
    echo "  3. Quit & Relaunch to pick up the change for Screen Recording."
    echo "  4. Repeat for Accessibility."
fi
