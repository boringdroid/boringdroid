#!/bin/bash
#
# run-boringdroid-settings-tests.sh — Build and run BoringdroidSettings UiAutomator tests on the
# currently-connected emulator. Mirrors run-boringdroid-tests.sh (which covers BoringdroidSystemUI)
# so any change touching vendor/boringdroid/apps/BoringdroidSettings has a corresponding
# instrumentation verify.
#
# Exit codes:
#   0  — tests passed
#   1  — build / install / setup failed
#   2  — one or more tests failed (crash captured)

set -o pipefail
# Don't use -u: AOSP's build/envsetup.sh references unbound variables as part
# of its normal initialization and would crash under `set -u`.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(cd "${SCRIPT_DIR}" && while [[ "$PWD" != "/" ]]; do
    if [[ -f "$PWD/build/envsetup.sh" ]]; then echo "$PWD"; exit 0; fi
    cd ..
done)"
LOG_DIR="${BORINGDROID_TEST_LOG_DIR:-/tmp/boringdroid-dispatch}"
mkdir -p "$LOG_DIR"

PKG="com.boringdroid.settings"
TEST_PKG="${PKG}.test"
RUNNER="${TEST_PKG}/androidx.test.runner.AndroidJUnitRunner"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
TEST_LOG="${LOG_DIR}/settings-instrumentation-${TIMESTAMP}.log"
FAILURE_SCREENSHOT="${LOG_DIR}/settings-test-failure-${TIMESTAMP}.png"
FAILURE_LOGCAT="${LOG_DIR}/settings-test-failure-logcat-${TIMESTAMP}.log"

ts() { date '+%H:%M:%S'; }

# ──────────────────────────────────────────────
# Preconditions
# ──────────────────────────────────────────────
if ! adb get-state 2>/dev/null | grep -q "device"; then
    echo "[$(ts)] ✗ No adb device connected — cannot run instrumentation tests"
    exit 1
fi

if [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" != "1" ]; then
    echo "[$(ts)] ✗ Emulator has not finished booting"
    exit 1
fi

# ──────────────────────────────────────────────
# Build the app + test APKs via Soong.
# ──────────────────────────────────────────────
echo "[$(ts)] Building BoringdroidSettings + BoringdroidSettingsTests via Soong..."
if ! (cd "$WORK_DIR" && source build/envsetup.sh >/dev/null 2>&1 \
        && lunch "${BORINGDROID_LUNCH_TARGET:-boringdroid_x86_64-userdebug}" >/dev/null 2>&1 \
        && m BoringdroidSettings BoringdroidSettingsTests \
            > "${LOG_DIR}/soong-settings-test-${TIMESTAMP}.log" 2>&1); then
    echo "[$(ts)] ✗ Soong build failed — see ${LOG_DIR}/soong-settings-test-${TIMESTAMP}.log"
    tail -40 "${LOG_DIR}/soong-settings-test-${TIMESTAMP}.log"
    exit 1
fi

PRODUCT_OUT="${WORK_DIR}/out/target/product/boringdroid_x86_64"
APP_APK=$(find "${PRODUCT_OUT}" -name "BoringdroidSettings.apk" 2>/dev/null | head -1)
TEST_APK=$(find "${PRODUCT_OUT}" -name "BoringdroidSettingsTests.apk" 2>/dev/null | head -1)
if [ ! -s "$APP_APK" ] || [ ! -s "$TEST_APK" ]; then
    echo "[$(ts)] ✗ Expected APK outputs missing (app=${APP_APK}, test=${TEST_APK})"
    exit 1
fi

# ──────────────────────────────────────────────
# Install APKs. BoringdroidSettings is platform-signed and ships on the system image;
# we install over the image copy to make sure we're testing this commit's bytes.
# ──────────────────────────────────────────────
echo "[$(ts)] Installing app APK (${APP_APK##*/})..."
adb install -r -t -d "$APP_APK" > /dev/null 2>&1 || {
    adb shell pm uninstall --user 0 "$PKG" > /dev/null 2>&1 || true
    adb install -r -t -d "$APP_APK" > /dev/null 2>&1 || {
        echo "[$(ts)] ⚠ Failed to install app APK — relying on image-baked copy"; }
}
echo "[$(ts)] Installing test APK (${TEST_APK##*/})..."
adb install -r -t "$TEST_APK" > /dev/null || {
    echo "[$(ts)] ✗ Failed to install test APK"; exit 1; }

# Clear app data so per-app windowing-mode state from a prior run doesn't leak.
adb shell pm clear "$PKG" > /dev/null 2>&1 || true

# Clear logcat so a failure capture below only shows test-run lines.
adb logcat -c > /dev/null 2>&1 || true

# Drop root before instrumentation.
adb unroot > /dev/null 2>&1 || true
adb wait-for-device > /dev/null 2>&1 || true

# ──────────────────────────────────────────────
# Run instrumentation
# ──────────────────────────────────────────────
echo "[$(ts)] Running instrumentation: ${RUNNER}"
adb shell am instrument -w -r "$RUNNER" 2>&1 | tee "$TEST_LOG"

# am instrument exit code is unreliable; parse the output instead.
FAILED_STATUS=$(grep -cE "^INSTRUMENTATION_STATUS_CODE: -2\\b" "$TEST_LOG" || true)
PASSED_LINES=$(grep -cE "^INSTRUMENTATION_STATUS_CODE: 0\\b" "$TEST_LOG" || true)
PROCESS_CRASH=$(grep -cE "INSTRUMENTATION_RESULT: shortMsg=Process crashed" "$TEST_LOG" || true)

if (( FAILED_STATUS > 0 )) || (( PROCESS_CRASH > 0 )) || grep -q "FAILURES!!!" "$TEST_LOG"; then
    echo ""
    echo "[$(ts)] ✗ Instrumentation tests FAILED (failed=${FAILED_STATUS}, crashes=${PROCESS_CRASH}, passed=${PASSED_LINES})"
    echo "[$(ts)] Capturing screenshot + logcat for diagnosis..."
    adb exec-out screencap -p > "$FAILURE_SCREENSHOT" 2>/dev/null || true
    adb logcat -d > "$FAILURE_LOGCAT" 2>/dev/null || true
    echo "[$(ts)]   Screenshot: ${FAILURE_SCREENSHOT}"
    echo "[$(ts)]   Logcat:     ${FAILURE_LOGCAT}"
    echo "[$(ts)]   Test log:   ${TEST_LOG}"
    echo ""
    echo "[$(ts)] Failing tests:"
    awk '/^INSTRUMENTATION_STATUS: class=/{cls=$0}
         /^INSTRUMENTATION_STATUS: test=/{tst=$0}
         /^INSTRUMENTATION_STATUS: stack=/{flag=1}
         flag{print}
         /^INSTRUMENTATION_STATUS_CODE: -2/{print cls; print tst; flag=0; print "---"}' \
        "$TEST_LOG" | head -80
    exit 2
fi

echo ""
echo "[$(ts)] ✓ All instrumentation tests passed (passed=${PASSED_LINES})"
echo "[$(ts)]   Test log: ${TEST_LOG}"
exit 0
