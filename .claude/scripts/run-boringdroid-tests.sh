#!/bin/bash
#
# run-boringdroid-tests.sh — Build and run BoringdroidSystemUI UiAutomator tests on the
# currently-connected emulator. Used as the final check in dispatch verify_completion.
#
# Exit codes:
#   0  — tests passed
#   1  — build / install / setup failed
#   2  — one or more tests failed (crash captured)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(cd "${SCRIPT_DIR}" && while [[ "$PWD" != "/" ]]; do
    if [[ -f "$PWD/build/envsetup.sh" ]]; then echo "$PWD"; exit 0; fi
    cd ..
done)"
APP_DIR="${WORK_DIR}/vendor/boringdroid/apps/BoringdroidSystemUI"
LOG_DIR="${BORINGDROID_TEST_LOG_DIR:-/tmp/boringdroid-dispatch}"
mkdir -p "$LOG_DIR"

PKG="com.boringdroid.systemui"
TEST_PKG="${PKG}.test"
RUNNER="${TEST_PKG}/androidx.test.runner.AndroidJUnitRunner"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
TEST_LOG="${LOG_DIR}/instrumentation-${TIMESTAMP}.log"
FAILURE_SCREENSHOT="${LOG_DIR}/test-failure-${TIMESTAMP}.png"
FAILURE_LOGCAT="${LOG_DIR}/test-failure-logcat-${TIMESTAMP}.log"

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
# Build the androidTest APK
# ──────────────────────────────────────────────
echo "[$(ts)] Building androidTest APK in ${APP_DIR}..."
if ! (cd "$APP_DIR" && ./gradlew :app:assembleDebug :app:assembleDebugAndroidTest \
        > "${LOG_DIR}/gradle-test-${TIMESTAMP}.log" 2>&1); then
    echo "[$(ts)] ✗ Gradle build failed — see ${LOG_DIR}/gradle-test-${TIMESTAMP}.log"
    tail -40 "${LOG_DIR}/gradle-test-${TIMESTAMP}.log"
    exit 1
fi

APP_APK="${APP_DIR}/app/build/outputs/apk/debug/app-debug.apk"
TEST_APK="${APP_DIR}/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk"
if [ ! -s "$APP_APK" ] || [ ! -s "$TEST_APK" ]; then
    echo "[$(ts)] ✗ Expected APK outputs missing (${APP_APK}, ${TEST_APK})"
    exit 1
fi

# ──────────────────────────────────────────────
# Install APKs (the app APK so the test APK's signature matches the target)
# ──────────────────────────────────────────────
echo "[$(ts)] Installing app + test APKs..."
adb install -r -t "$APP_APK" > /dev/null || {
    echo "[$(ts)] ✗ Failed to install app APK"; exit 1; }
adb install -r -t "$TEST_APK" > /dev/null || {
    echo "[$(ts)] ✗ Failed to install test APK"; exit 1; }

# Clear the plugin's state so each run starts fresh.
adb shell pm clear "$PKG" > /dev/null 2>&1 || true

# Clear logcat so a failure capture below only shows test-run lines.
adb logcat -c > /dev/null 2>&1 || true

# ──────────────────────────────────────────────
# Run instrumentation
# ──────────────────────────────────────────────
echo "[$(ts)] Running instrumentation: ${RUNNER}"
adb shell am instrument -w -r "$RUNNER" 2>&1 | tee "$TEST_LOG"

# am instrument exit code is unreliable; parse the output instead.
# A passing session ends with "INSTRUMENTATION_CODE: -1" (yes, -1 means success for am instrument).
# Failures appear as "INSTRUMENTATION_STATUS_CODE: -2" or the word "FAILURES!!!".
FAILED_TESTS=$(grep -cE "^INSTRUMENTATION_STATUS_CODE: -[12]\\b|FAILURES!!!" "$TEST_LOG" || true)
PASSED_LINES=$(grep -cE "^INSTRUMENTATION_STATUS_CODE: 0\\b" "$TEST_LOG" || true)
PROCESS_CRASH=$(grep -cE "INSTRUMENTATION_RESULT: shortMsg=Process crashed" "$TEST_LOG" || true)
FAILED_STATUS=$(grep -cE "^INSTRUMENTATION_STATUS_CODE: -2\\b" "$TEST_LOG" || true)

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
