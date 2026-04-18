#!/bin/bash
#
# boringdroid-dispatch.sh — Automated dispatch system for Boringdroid development
#
# Runs a loop of Claude Code subagents. Each subagent:
#   1. Reads the latest boringdroid-handoff-N.md
#   2. Does real work (edit, build, boot emulator, exercise the feature, check logs)
#   3. Writes boringdroid-handoff-(N+1).md with progress
#   4. Exits
#
# The loop continues until a subagent writes STATUS: COMPLETE and
# verification confirms the boringdroid_x86_64-userdebug emulator boots and
# the current task's acceptance criteria are met.
#
# Usage:
#   ./boringdroid-dispatch.sh                                 # Continue from latest handoff
#   ./boringdroid-dispatch.sh "Fix taskbar flicker on rotate" # Fresh start with initial idea
#   BORINGDROID_MAX_BUDGET=30 ./boringdroid-dispatch.sh       # Custom budget per cycle
#
# Environment variables:
#   BORINGDROID_MAX_RETRIES  - Retries per cycle on error (default: 3)
#   BORINGDROID_RETRY_WAIT   - Seconds to wait between retries (default: 300)
#   BORINGDROID_MAX_BUDGET   - Max USD per subagent run (default: 20)
#   BORINGDROID_MAX_CYCLES   - Max total cycles before giving up (default: 50)
#   BORINGDROID_MODEL        - Claude model to use (default: opus)
#   BORINGDROID_LUNCH_TARGET - lunch target (default: boringdroid_x86_64-userdebug)

set -euo pipefail

# Derive WORK_DIR (AOSP root) by walking up from script location until we find build/envsetup.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(cd "${SCRIPT_DIR}" && while [[ "$PWD" != "/" ]]; do
    if [[ -f "$PWD/build/envsetup.sh" ]]; then echo "$PWD"; exit 0; fi
    cd ..
done
echo "${SCRIPT_DIR}/../.." )"
HANDOFF_PREFIX="boringdroid-handoff"
LOG_DIR="/tmp/boringdroid-dispatch"

MAX_RETRIES=${BORINGDROID_MAX_RETRIES:-3}
RETRY_WAIT=${BORINGDROID_RETRY_WAIT:-300}
MAX_BUDGET=${BORINGDROID_MAX_BUDGET:-20}
MAX_CYCLES=${BORINGDROID_MAX_CYCLES:-50}
MODEL=${BORINGDROID_MODEL:-opus}
LUNCH_TARGET=${BORINGDROID_LUNCH_TARGET:-boringdroid_x86_64-userdebug}

mkdir -p "$LOG_DIR"

# ──────────────────────────────────────────────
# Find the highest-numbered handoff-N.md
# ──────────────────────────────────────────────
find_latest_handoff() {
    local latest=0
    for f in "${WORK_DIR}/${HANDOFF_PREFIX}"-*.md; do
        [[ -f "$f" ]] || continue
        local num
        num=$(basename "$f" .md | sed "s/${HANDOFF_PREFIX}-//")
        if [[ "$num" =~ ^[0-9]+$ ]] && (( num > latest )); then
            latest=$num
        fi
    done
    echo "$latest"
}

# ──────────────────────────────────────────────
# Build the prompt for a subagent
# ──────────────────────────────────────────────
build_prompt() {
    local current=$1
    local next=$2
    local input_file="${WORK_DIR}/${HANDOFF_PREFIX}-${current}.md"
    local output_file="${HANDOFF_PREFIX}-${next}.md"
    local user_idea="${3:-}"

    cat <<PROMPT_HEADER
You are a subagent working on Boringdroid — an AOSP-extending project (currently tracking AOSP 14) that ships a minimal freeform/multi-window patchset, a custom taskbar (BoringdroidSystemUI), a Settings hook (BoringdroidSettings), and a forked Launcher3, all targeted at the boringdroid_x86_64 emulator build.

## Layout of this AOSP checkout
- \`boringdroid/\` — project meta (README, ARCHITECTURE, CONTRIBUTING, CLAUDE.md, \`.claude/\`).
- \`vendor/boringdroid/\` — product makefile \`boringdroid.mk\`, overlays, RRO.
- \`vendor/boringdroid/apps/BoringdroidSystemUI/\` — SystemUI plugin (taskbar, nav bar injection); has its own Gradle setup for IDE iteration; consumes sysui_shared.jar from SystemUI.
- \`vendor/boringdroid/apps/BoringdroidSettings/\` — Settings app hooked in via EXTRA_SETTINGS (toggles PC mode and BoringdroidSystemUI).
- \`vendor/boringdroid/apps/Launcher3/\` — forked launcher.
- \`device/generic/boringdroid_x86_64/\` — emulator target derived from sdk_phone_x86_64.
- \`frameworks/base/\` (forked) — framework-level patches: freeform default, window bounds/mode persistence, SystemUI plugin hook enablement.

You are part of an automated dispatch pipeline. You will:
1. Read context (previous handoff or CLAUDE.md for fresh starts)
2. Do real, concrete work (edit code, build, boot the emulator, exercise the feature, check logs)
3. Write a new handoff document recording your progress
4. Exit

PROMPT_HEADER

    if [[ -f "$input_file" ]]; then
        echo ""
        echo "## Input"
        echo "Read this file first: ${HANDOFF_PREFIX}-${current}.md"
        echo "It contains context from the previous cycle: what was done, current state, rules, and build commands."
        echo ""
        if [[ -n "$user_idea" ]]; then
            echo "## Priority Task (OVERRIDE)"
            echo "The user has specified this task. Work on it instead of the handoff's \"What Should Be Done Next\" list:"
            echo "$user_idea"
            echo ""
        fi
        echo "## Output"
        echo "Write your progress to: ${output_file}"
        echo ""
    else
        echo ""
        echo "## Fresh Start"
        echo "No previous handoff exists. Read boringdroid/CLAUDE.md first to understand the project context."
        echo ""
        if [[ -n "$user_idea" ]]; then
            echo "The initial idea / task:"
            echo "$user_idea"
            echo ""
        fi
        echo "Do real work — investigate, edit code, build, boot emulator, verify. Do NOT just write a plan."
        echo "Write your progress to: ${output_file}"
        echo ""
    fi

    cat <<PROMPT_RULES
## Rules (MUST FOLLOW)

1. **Fail fast**: implement → build → boot emulator → exercise feature → check logs → iterate.
2. **Small changes**: One fix at a time. Verify before moving to the next.
3. **Region markers**: Every modification inside a forked upstream AOSP file (e.g. \`frameworks/base/\`, \`packages/apps/Launcher3/\`, \`system/*\`, \`art/\` — anything that exists in stock AOSP) MUST be wrapped in \`// region boringdroid\` / \`// endregion\` (use language-appropriate comment syntax: \`#\` for shell/Python/Make, \`<!-- region boringdroid -->\` for XML). Files wholly owned by boringdroid (\`vendor/boringdroid/*\`, \`device/generic/boringdroid_x86_64/*\`, BoringdroidSystemUI, BoringdroidSettings) do NOT need markers.
4. **Version portability**: Boringdroid tracks multiple AOSP versions (9 – 14). When editing a forked upstream AOSP file, keep the diff minimal and additive so the patch rebases cleanly onto future AOSP releases. Prefer hooks, overlays, or new files over intrusive in-place edits.
5. **Read before edit**: Always read a file before modifying it.
6. **No blind sleeps for boot**: NEVER use a flat \`sleep\` to wait for boot. Poll \`sys.boot_completed\` (max ~60 iterations).
7. **Reuse running emulator**: If an emulator is already booted and you only changed an app (not framework or device config), just rebuild and reinstall — no full \`m\` + restart needed.
8. **Write handoff early**: Write your handoff document as soon as you have results, BEFORE doing extensive secondary investigations.
9. **Budget awareness**: Limited budget per cycle. Prioritize: (a) read handoff, (b) make code fixes, (c) build, (d) boot + verify, (e) write handoff.
10. **No Claude commit attribution**: If you create git commits, do NOT include a \`Co-Authored-By: Claude ...\` trailer or any AI attribution in the commit message.

## Build, Deploy & Verify Commands

### Full rebuild (after framework / device / vendor changes)
\`\`\`bash
source build/envsetup.sh && lunch ${LUNCH_TARGET}
pkill -9 -f qemu-system-x86_64 || true; sleep 2
m
nohup emulator -no-snapshot -writable-system > /tmp/emu.log 2>&1 &
n=0; while [ "\$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\\r')" != "1" ] && [ \$n -lt 60 ]; do sleep 1; n=\$((n+1)); done
if [ "\$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\\r')" != "1" ]; then echo "ERROR: Boot did not complete"; exit 1; fi
adb root && sleep 2 && adb remount
\`\`\`

### App-only changes (BoringdroidSystemUI / BoringdroidSettings / Launcher3)
Rebuild the module and reinstall — no emulator restart needed if it's already booted:
\`\`\`bash
# For app modules with their own Gradle setup (e.g. BoringdroidSystemUI), use ./gradlew assembleDebug inside the project.
# For Soong-built modules, target them with mmm or m <module-name>, then adb install -r the APK from out/.
\`\`\`

### Quick smoke test
After boot:
- \`adb shell getprop sys.boot_completed\` returns 1
- Launcher/taskbar renders, a freeform window can be opened and resized
- Relevant logcat (\`adb logcat -d -s BoringdroidSystemUI SystemUIService WindowManager\`) shows no new errors

## Handoff Document Format

Your output handoff document MUST follow this exact structure:

\`\`\`
# Boringdroid Handoff #N: [Brief Title]

## What Was Done
[Describe each change with file paths and technical details]

## How It Was Verified
[What was built, did the emulator boot, what did you exercise, what did logs show]

## Current State
[Does the emulator boot? Does the target feature work? Any regressions?]

## Files Modified (This Session)
| File | Change | Has region-boringdroid markers? |
|------|--------|---------------------------------|
| ... | ... | yes / n/a (boringdroid-owned file) |

## Current Blocker (if any)
[What's preventing progress, with technical details]

## What Should Be Done Next
[Prioritized list of next steps]

## Rules for Working on This Project
[Copy rules from previous handoff, add any new lessons learned]

## Build & Test
[Copy build commands]

## STATUS: IN_PROGRESS
\`\`\`

## Completion

When the task's acceptance criteria are met AND the ${LUNCH_TARGET} emulator boots cleanly with the change applied:

Change the last line to: \`## STATUS: COMPLETE\`

Otherwise keep it as: \`## STATUS: IN_PROGRESS\`

## IMPORTANT

- START by reading the handoff document (or boringdroid/CLAUDE.md for fresh starts).
- DO real work. You have full tool access — edit files, run builds, boot the emulator, check logs.
- WRITE your handoff document EARLY — as soon as you have results. Don't delay writing it.
- Be SPECIFIC — exact file paths, line numbers, error messages, logcat excerpts.
- If you can't make progress on the top priority, document WHY and move to the next item.
- BUDGET: Limited budget per cycle. Focus on ONE concrete change per cycle, verify it, write the handoff, and exit.
PROMPT_RULES
}

# ──────────────────────────────────────────────
# Run a single subagent cycle
# Returns 0 on success, 1 on failure
# ──────────────────────────────────────────────
run_subagent() {
    local current=$1
    local next=$2
    local user_idea="${3:-}"
    local log_file="${LOG_DIR}/cycle-${next}.log"
    local prompt_file
    prompt_file=$(mktemp "${LOG_DIR}/prompt-${next}-XXXXX.txt")

    build_prompt "$current" "$next" "$user_idea" > "$prompt_file"

    echo "[$(date '+%H:%M:%S')] Prompt written to ${prompt_file} ($(wc -c < "$prompt_file") bytes)"
    echo "[$(date '+%H:%M:%S')] Log: ${log_file}"
    echo "[$(date '+%H:%M:%S')] Running claude -p --model ${MODEL} --max-budget-usd ${MAX_BUDGET} ..."
    echo ""

    # Run claude with stream-json output piped through a progress filter.
    local exit_code=0
    if (cd "${WORK_DIR}" && claude -p \
        --dangerously-skip-permissions \
        --model "${MODEL}" \
        --max-budget-usd "${MAX_BUDGET}" \
        --verbose \
        --output-format stream-json \
        < "$prompt_file" 2>"${log_file}.stderr") \
        | python3 "${SCRIPT_DIR}/dispatch-progress.py" "$log_file" 30; then
        echo ""
        echo "[$(date '+%H:%M:%S')] Subagent exited successfully."
        return 0
    else
        exit_code=$?
        echo ""
        echo "[$(date '+%H:%M:%S')] Subagent exited with code ${exit_code}."
        if [[ -s "${log_file}.stderr" ]]; then
            echo "[$(date '+%H:%M:%S')] Stderr:"
            tail -10 "${log_file}.stderr" 2>/dev/null || true
        fi
        echo "[$(date '+%H:%M:%S')] Last 20 lines of log:"
        tail -20 "$log_file" 2>/dev/null || true
        return 1
    fi
}

# ──────────────────────────────────────────────
# Verify that the boringdroid emulator is actually running AND that
# BoringdroidSystemUI is live (loaded, not disabled, bound to the nav bar).
#
# Handoff #1 "completed" while the plugin was silently disabled by
# PluginActionManager after a ClassCastException — a log-free failure that
# the bare boot_completed check happily waved through. This verifier now:
#   1. Checks the device is connected and sys.boot_completed=1
#   2. Confirms the BoringdroidSystemUI package exists and its
#      SystemUIOverlay component is NOT in disabledComponents
#   3. Confirms the most recent SystemUIOverlay "setup … nav bar …" log
#      line reports a non-null nav bar (plugin actually attached)
#   4. Captures a screenshot for human review
# ──────────────────────────────────────────────
verify_completion() {
    echo "[$(date '+%H:%M:%S')] Verifying boringdroid_x86_64 emulator is running..."

    if ! adb devices 2>/dev/null | grep -q "emulator\|device"; then
        echo "[$(date '+%H:%M:%S')] ✗ No emulator/device connected"
        return 1
    fi

    if [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" != "1" ]; then
        echo "[$(date '+%H:%M:%S')] ✗ Emulator not booted"
        return 1
    fi

    local screenshot="${LOG_DIR}/verify-screen-$(date +%Y%m%d-%H%M%S).png"
    if adb exec-out screencap -p > "$screenshot" 2>/dev/null && [ -s "$screenshot" ]; then
        echo "[$(date '+%H:%M:%S')] ✓ Screenshot captured at ${screenshot}"
    else
        echo "[$(date '+%H:%M:%S')] ⚠ Screenshot capture failed (continuing)"
    fi

    if ! adb shell pm list packages 2>/dev/null | grep -q "^package:com.boringdroid.systemui$"; then
        echo "[$(date '+%H:%M:%S')] ✗ BoringdroidSystemUI package is not installed"
        return 1
    fi

    local disabled
    disabled=$(adb shell dumpsys package com.boringdroid.systemui 2>/dev/null \
        | awk '/disabledComponents:/{flag=1;next}/^[[:space:]]*$/{flag=0}flag' \
        | tr -d '\r')
    if echo "$disabled" | grep -q "com.boringdroid.systemui.SystemUIOverlay"; then
        echo "[$(date '+%H:%M:%S')] ✗ BoringdroidSystemUI plugin is in disabledComponents (PluginActionManager disabled it after a crash)"
        echo "[$(date '+%H:%M:%S')]   Check adb logcat for the exception, fix it, then run:"
        echo "[$(date '+%H:%M:%S')]     adb shell \"su 0 pm enable com.boringdroid.systemui/.SystemUIOverlay\""
        return 1
    fi

    # The framework must create a NavigationBar window for the plugin to hook into.
    # Without this, the plugin's setup(…) runs with navBar=null and the views vanish.
    if ! adb shell dumpsys window windows 2>/dev/null | grep -q "Window{.* NavigationBar0}"; then
        echo "[$(date '+%H:%M:%S')] ✗ NavigationBar0 window is missing — plugin has nothing to attach to"
        return 1
    fi

    # If the setup line is still in the ring buffer, double-check it didn't see a null.
    # A missing line (logcat wrapped) is not a failure by itself — the plugin may just
    # have been running long enough to age out. The disabledComponents check above
    # already catches a crashed plugin.
    local setup_line
    setup_line=$(adb logcat -d -s SystemUIOverlay:D 2>/dev/null | grep "setup status bar" | tail -1)
    if [ -n "$setup_line" ] && echo "$setup_line" | grep -q "nav bar null"; then
        echo "[$(date '+%H:%M:%S')] ✗ SystemUIOverlay got 'nav bar null' — NavigationBar was not created"
        echo "[$(date '+%H:%M:%S')]   Most recent setup line: $setup_line"
        return 1
    fi

    echo "[$(date '+%H:%M:%S')] ✓ Emulator booted, plugin loaded, NavigationBar0 present."
    echo "[$(date '+%H:%M:%S')]   Screenshot: ${screenshot}"
    return 0
}

# ──────────────────────────────────────────────
# Main dispatch loop
# ──────────────────────────────────────────────
main() {
    local user_idea="${*}"

    echo "╔══════════════════════════════════════════════╗"
    echo "║      Boringdroid Dispatch System             ║"
    echo "║      AOSP multi-window patchset              ║"
    echo "╚══════════════════════════════════════════════╝"
    echo ""
    echo "Config:"
    echo "  Work dir:     ${WORK_DIR}"
    echo "  Lunch:        ${LUNCH_TARGET}"
    echo "  Model:        ${MODEL}"
    echo "  Max budget:   \$${MAX_BUDGET}/cycle"
    echo "  Max retries:  ${MAX_RETRIES}/cycle"
    echo "  Retry wait:   ${RETRY_WAIT}s"
    echo "  Max cycles:   ${MAX_CYCLES}"
    echo "  Log dir:      ${LOG_DIR}"
    if [[ -n "$user_idea" ]]; then
        echo "  Initial idea: ${user_idea}"
    fi
    echo ""

    local cycle=0

    while (( cycle < MAX_CYCLES )); do
        cycle=$((cycle + 1))
        local current
        current=$(find_latest_handoff)
        local next=$((current + 1))
        local input_file="${WORK_DIR}/${HANDOFF_PREFIX}-${current}.md"
        local output_file="${WORK_DIR}/${HANDOFF_PREFIX}-${next}.md"

        if (( current == 0 )); then
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "[$(date '+%H:%M:%S')] Cycle ${cycle}: fresh start → ${HANDOFF_PREFIX}-${next}.md"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        else
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "[$(date '+%H:%M:%S')] Cycle ${cycle}: ${HANDOFF_PREFIX}-${current}.md → ${HANDOFF_PREFIX}-${next}.md"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

            if [[ ! -f "$input_file" ]]; then
                echo "[$(date '+%H:%M:%S')] ERROR: Input file not found: ${input_file}"
                exit 1
            fi
        fi

        # Retry loop for this cycle
        local retries=0
        local success=false

        while (( retries < MAX_RETRIES )); do
            if run_subagent "$current" "$next" "$user_idea"; then
                success=true
                break
            else
                retries=$((retries + 1))
                if (( retries < MAX_RETRIES )); then
                    echo "[$(date '+%H:%M:%S')] Retry ${retries}/${MAX_RETRIES} in ${RETRY_WAIT}s..."
                    sleep "$RETRY_WAIT"
                fi
            fi
        done

        if ! $success; then
            echo "[$(date '+%H:%M:%S')] ERROR: Cycle ${cycle} failed after ${MAX_RETRIES} attempts."
            echo "[$(date '+%H:%M:%S')] Check logs in ${LOG_DIR}/"
            exit 1
        fi

        if [[ ! -f "$output_file" ]]; then
            echo "[$(date '+%H:%M:%S')] WARNING: ${HANDOFF_PREFIX}-${next}.md was not created."
            echo "[$(date '+%H:%M:%S')] Subagent may not have finished writing. Retrying cycle..."
            continue
        fi

        echo "[$(date '+%H:%M:%S')] ${HANDOFF_PREFIX}-${next}.md written ($(wc -l < "$output_file") lines)"

        # Clear user_idea after first successful cycle — subsequent cycles read handoffs
        user_idea=""

        if grep -q "STATUS: COMPLETE" "$output_file" 2>/dev/null; then
            echo ""
            echo "[$(date '+%H:%M:%S')] ★ Subagent reports STATUS: COMPLETE"
            echo ""

            if verify_completion; then
                echo ""
                echo "╔══════════════════════════════════════════════╗"
                echo "║           BORINGDROID COMPLETE!              ║"
                echo "║   Emulator up on ${LUNCH_TARGET}"
                echo "║   Total cycles: ${cycle}"
                echo "╚══════════════════════════════════════════════╝"
                exit 0
            else
                echo "[$(date '+%H:%M:%S')] Verification failed. Appending note to handoff."
                cat >> "$output_file" <<EOF

## Dispatch Verification Note
Automated verification at $(date) could not confirm the boringdroid emulator is running.
The next subagent should investigate and re-verify.
EOF
            fi
        fi

        echo "[$(date '+%H:%M:%S')] Cycle ${cycle} complete. Moving to next cycle."
        echo ""
    done

    echo "[$(date '+%H:%M:%S')] ERROR: Reached max cycles (${MAX_CYCLES}) without completion."
    exit 1
}

main "$@"
