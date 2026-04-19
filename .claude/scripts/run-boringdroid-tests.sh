#!/bin/bash
#
# run-boringdroid-tests.sh — Build and run BoringdroidSystemUI UiAutomator tests on the
# currently-connected emulator. Used as the final check in dispatch verify_completion.
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
# Build the main plugin + test APKs via Soong. Boringdroid apps ship through
# Android.bp, not Gradle — using Gradle here would require Maven-coord test
# libs that aren't in the AOSP tree. `m BoringdroidSystemUITests` builds the
# instrumentation APK with AOSP-hosted `androidx.test.*` modules.
# ──────────────────────────────────────────────
echo "[$(ts)] Building BoringdroidSystemUI + BoringdroidSystemUITests via Soong..."
if ! (cd "$WORK_DIR" && source build/envsetup.sh >/dev/null 2>&1 \
        && lunch "${BORINGDROID_LUNCH_TARGET:-boringdroid_x86_64-userdebug}" >/dev/null 2>&1 \
        && m BoringdroidSystemUI BoringdroidSystemUITests \
            > "${LOG_DIR}/soong-test-${TIMESTAMP}.log" 2>&1); then
    echo "[$(ts)] ✗ Soong build failed — see ${LOG_DIR}/soong-test-${TIMESTAMP}.log"
    tail -40 "${LOG_DIR}/soong-test-${TIMESTAMP}.log"
    exit 1
fi

PRODUCT_OUT="${WORK_DIR}/out/target/product/boringdroid_x86_64"
APP_APK="${PRODUCT_OUT}/system_ext/priv-app/BoringdroidSystemUI/BoringdroidSystemUI.apk"
[ -s "$APP_APK" ] || APP_APK="${PRODUCT_OUT}/system/priv-app/BoringdroidSystemUI/BoringdroidSystemUI.apk"
[ -s "$APP_APK" ] || APP_APK="${PRODUCT_OUT}/system/app/BoringdroidSystemUI/BoringdroidSystemUI.apk"
TEST_APK=$(find "${PRODUCT_OUT}" -name "BoringdroidSystemUITests.apk" 2>/dev/null | head -1)
if [ ! -s "$APP_APK" ] || [ ! -s "$TEST_APK" ]; then
    echo "[$(ts)] ✗ Expected APK outputs missing (app=${APP_APK}, test=${TEST_APK})"
    exit 1
fi

# ──────────────────────────────────────────────
# Install APKs. Even though the plugin ships on the OS image, a prior cycle
# may have overlaid /data/app with a stale build via `adb install`. Re-pushing
# the freshly-built plugin APK guarantees we test current source.
# ──────────────────────────────────────────────
echo "[$(ts)] Installing plugin APK (${APP_APK##*/})..."
# -d allows downgrading past versionCode; a previous cycle may have used Gradle's
# debug versionCode (130) while Soong's is the manifest's value (typically 34).
adb install -r -t -d "$APP_APK" > /dev/null 2>&1 || {
    # If install still fails, uninstall any /data overlay and retry.
    adb shell pm uninstall --user 0 "$PKG" > /dev/null 2>&1 || true
    adb install -r -t -d "$APP_APK" > /dev/null 2>&1 || {
        echo "[$(ts)] ⚠ Failed to install plugin APK — relying on image-baked copy"; }
}
echo "[$(ts)] Installing test APK (${TEST_APK##*/})..."
adb install -r -t "$TEST_APK" > /dev/null || {
    echo "[$(ts)] ✗ Failed to install test APK"; exit 1; }

# Re-enable in case a prior bad run left SystemUIOverlay in disabledComponents,
# clear the plugin's data, and force-restart SystemUI so it loads the freshly-
# installed plugin APK instead of the already-running old class bytes.
adb shell pm enable "${PKG}/.SystemUIOverlay" > /dev/null 2>&1 || true
adb shell pm clear "$PKG" > /dev/null 2>&1 || true
echo "[$(ts)] Restarting SystemUI to pick up new plugin..."
adb shell killall com.android.systemui > /dev/null 2>&1 || true
# Wait for SystemUI to respawn and the plugin to attach.
sleep 5
n=0
while ! adb shell dumpsys window windows 2>/dev/null | grep -qE "BoringdroidTaskbar|NavigationBar0" && (( n < 20 )); do
    sleep 1; n=$((n+1))
done

# Clear logcat so a failure capture below only shows test-run lines.
adb logcat -c > /dev/null 2>&1 || true

# Drop root before instrumentation — `cmd notification post` fails with
# NameNotFoundException when adb is uid=0 (no installed package for root).
adb unroot > /dev/null 2>&1 || true
adb wait-for-device > /dev/null 2>&1 || true

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
