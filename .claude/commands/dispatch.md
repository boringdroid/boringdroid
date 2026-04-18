---
description: "Run the Boringdroid dispatch loop — automated handoff-driven development for the boringdroid AOSP patchset. Spawns subagents that read the latest handoff, do real work (edit, build, boot the emulator, verify), and write the next handoff. Loops until STATUS: COMPLETE. Invoke with /dispatch or /dispatch <task description>."
---

Run the Boringdroid automated dispatch loop via `.claude/scripts/boringdroid-dispatch.sh`. This script spawns subagents in a loop — each reads the latest handoff, does real work, writes the next handoff, and exits. The loop continues until `STATUS: COMPLETE`.

Run it now with the user's arguments (if any) passed through:

```bash
.claude/scripts/boringdroid-dispatch.sh $ARGUMENTS
```

If the script fails or the user wants to do a single manual cycle instead, fall back to reading the latest `boringdroid-handoff-*.md` (or CLAUDE.md for fresh starts) and doing the work directly in this session. Write the next handoff before finishing.

After making framework or vendor changes, verify by (re)booting the `boringdroid_x86_64-userdebug` emulator:

```bash
source build/envsetup.sh && lunch boringdroid_x86_64-userdebug
m
emulator -no-snapshot -writable-system &
# Wait for boot, then exercise the multi-window / taskbar behavior relevant to the task
adb shell getprop sys.boot_completed
```
