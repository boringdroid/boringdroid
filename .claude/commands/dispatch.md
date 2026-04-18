---
description: "Run the Boringdroid dispatch loop — automated handoff-driven development for the boringdroid AOSP patchset. Spawns subagents that read the latest handoff, do real work (edit, build, boot the emulator, verify), and write the next handoff. Loops until STATUS: COMPLETE. Invoke with /dispatch or /dispatch <task description>."
---

Run the Boringdroid automated dispatch loop via `.claude/scripts/boringdroid-dispatch.sh`. This script spawns subagents in a loop — each reads the latest handoff, does real work, writes the next handoff, and exits. The loop continues until `STATUS: COMPLETE`.

## Run the script in the background

```bash
.claude/scripts/boringdroid-dispatch.sh $ARGUMENTS
```

Launch it with `run_in_background: true`. Note the output-file path the tool returns — you will need it for the Monitor below.

## MANDATORY: Monitor progress and report forcibly

Dispatch cycles commonly exceed 10–30 minutes and can silently stall on long builds, hung emulator boots, or frozen subagents. You MUST NOT rely solely on the background task's completion notification. Immediately after spawning the script, start a Monitor on its output file so heartbeats, cycle boundaries, and errors surface to the user as they happen.

Use this Monitor invocation — substitute `<OUTPUT_FILE>` with the path from the background Bash task:

```
Monitor(
  description: "dispatch loop key events",
  timeout_ms: 3600000,
  persistent: false,
  command: "tail -n +1 -F <OUTPUT_FILE> | grep -E --line-buffered 'Cycle|STATUS|Done —|handoff|exited|Subagent|Emulator booted|BORINGDROID|FAIL|error|Error|ERROR|\\[ *[0-9]+m[0-9]+s\\] ~ heartbeat'"
)
```

The filter covers:
- cycle boundaries (`Cycle N:`)
- heartbeats every 30s (so you see *something* during long builds)
- handoff writes (`handoff-N.md written`)
- completion markers (`STATUS: COMPLETE`, `Done —`, `BORINGDROID COMPLETE`)
- failure signatures (`FAIL`, `error`, `ERROR`, `exited`)

## Reporting cadence

You MUST report progress to the user on:
- **Every cycle start** — one line: which handoff → which handoff.
- **Every handoff write** — one line.
- **Any error/failure event** — full context.
- **Stalls**: if three consecutive heartbeats show the same tool-call count and the same `last:` tool, report it explicitly — the subagent may be hung on a long build, emulator boot, or stuck Bash. Do not wait silently through stalls.
- **Completion** — summarize cycles + what was delivered.

Plain heartbeats where progress is advancing (tool-call count rising) do NOT need to be surfaced individually; batch them into a single update every ~5 minutes.

## Fallback — manual single cycle

If the script fails to start or the user wants to do a single manual cycle instead, fall back to reading the latest `boringdroid-handoff-*.md` (or `boringdroid/CLAUDE.md` for fresh starts) and doing the work directly in this session. Write the next handoff before finishing.

## Verification after framework/vendor changes

After making framework or vendor changes, verify by (re)booting the `boringdroid_x86_64-userdebug` emulator:

```bash
source build/envsetup.sh && lunch boringdroid_x86_64-userdebug
m
emulator -no-snapshot -writable-system &
# Wait for boot, then exercise the multi-window / taskbar behavior relevant to the task
adb shell getprop sys.boot_completed
# Screenshot the emulator and confirm BoringdroidSystemUI renders:
adb exec-out screencap -p > /tmp/verify.png
```

A passing boot is not sufficient — screenshot and confirm the taskbar / plugin views are actually visible, not silently disabled.
