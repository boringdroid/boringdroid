# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Boringdroid is an AOSP-extending project that layers a minimal multi-window patchset on top of stock Android (supports AOSP 9.0 – 14.0). This working tree is the `boringdroid-14.0.0` branch. The repository root is an AOSP checkout assembled via `repo`; the `boringdroid/` directory you are in contains the project's own meta files (README, ARCHITECTURE, CONTRIBUTING, this CLAUDE.md), while the customizations themselves live scattered across forked AOSP repos (notably `frameworks/base`) and a handful of boringdroid-owned repos under `vendor/` and `device/`.

## Repository Layout

The AOSP root (the parent of this `boringdroid/` directory) is assembled by `repo sync` from `https://github.com/boringdroid/manifest.git`. Boringdroid-specific code lives in:

- `vendor/boringdroid/` — vendor config, overlays, RRO, plus `boringdroid.mk` (adds `BoringdroidSettings` + `BoringdroidSystemUI` to `PRODUCT_PACKAGES` and sets `persist.sys.systemuiplugin.enabled=true`).
- `vendor/boringdroid/apps/BoringdroidSystemUI/` — SystemUI plugin that renders the taskbar and injects views into the nav bar. Has its own Gradle setup for IDE development; consumes `sysui_shared.jar` from SystemUI for task events.
- `vendor/boringdroid/apps/BoringdroidSettings/` — Settings app using `EXTRA_SETTINGS` to hook into the stock Settings dashboard (toggles PC mode, toggles `BoringdroidSystemUI`).
- `vendor/boringdroid/apps/Launcher3/` — customized Launcher3 fork.
- `device/generic/boringdroid_x86_64/` — emulator target derived from `sdk_phone_x86_64` (`AndroidProducts.mk`, `BoardConfig.mk`, `boringdroid_x86_64.mk`, `config.ini.pc`).
- `frameworks/base/` (forked) — carries the framework-level patches: `freeform` enabled by default, window bounds/mode persistence, SystemUI plugin hook enablement, navigation bar layout tweaks. Reference commits:
  - `1eee9a5eba93ea145e1926eddd5e8e989fac83f6` — freeform bounds/windowing mode persistence
  - `5669078669825defbb100ca43aa7b6b8697a2d52` — BoringdroidSystemUI plugin hook

Everything else under the AOSP root (`art/`, `bionic/`, `build/`, `external/`, `packages/`, `system/`, …) is stock AOSP.

## Build & Run

Full-tree build from the AOSP root (not from `boringdroid/`):

```shell
source build/envsetup.sh
lunch boringdroid_x86_64-userdebug
m
```

The target is emulator-based (derived from `goldfish`). After `m`, launch with `emulator`. If you hit "boot image verified" errors, constrain the build parallelism (`m -j8` or lower) — this is a known workaround on the 13.0.0+ branches.

For IDE-driven iteration on `BoringdroidSystemUI` (the most frequently-edited component), use its in-tree Gradle script — see that project's own docs. The app still needs the framework patches and `sysui_shared.jar` from a full AOSP build to run correctly.

## Code Style

- Boringdroid apps use **Spotless**: run `./gradlew spotlessApply` inside each app's Gradle project before committing.
- Non-app (framework / system) changes follow the [AOSP code style](https://source.android.com/setup/contribute#contribute-to-the-code).

## Conventions for Claude

- **Do NOT add `Co-Authored-By: Claude ...` trailers (or any Claude attribution) to commit messages.** Author commits normally with no AI co-author line.
- **Wrap every edit inside a forked upstream AOSP file in `region boringdroid` markers.** Use the language's comment syntax:
  - Java / Kotlin / C / C++ / JS: `// region boringdroid` … `// endregion`
  - Shell / Python / Make: `# region boringdroid` … `# endregion`
  - XML: `<!-- region boringdroid -->` … `<!-- endregion -->`

  This applies to any file that exists in stock AOSP (notably `frameworks/base/`, `packages/apps/Launcher3/`, `system/*`, `art/`). Files wholly owned by boringdroid (`vendor/boringdroid/*`, `device/generic/boringdroid_x86_64/*`, `BoringdroidSystemUI`, `BoringdroidSettings`) don't need markers — they ship with boringdroid.
- **Keep forward-porting in mind when editing forked AOSP files.** Boringdroid tracks AOSP 9.0 – 14.0; the same patch is replayed against new AOSP releases. Keep diffs in upstream files minimal and additive — prefer hooks, overlays, or new standalone files over intrusive in-place edits. A change that reads cleanly in a `git diff` against `aosp/main` is one that will rebase cleanly next year.
- Changes are split across many forked AOSP repos — before editing, confirm which repo owns the file (`git -C <path-to-repo> status`) so the commit lands in the right project.
- Boringdroid prefers small, targeted patches that could plausibly upstream: keep diffs minimal and resist refactors outside the change at hand (see `ARCHITECTURE.md`'s framing of the patchset as intentionally "boring").

## Dispatch Automation

`.claude/commands/dispatch.md` plus `.claude/scripts/boringdroid-dispatch.sh` and `.claude/scripts/dispatch-progress.py` implement an automated handoff-driven development loop for boringdroid, adapted from the Digitalis project's dispatch system. Invoke from within Claude Code with `/dispatch [task description]`, or from a shell:

```bash
.claude/scripts/boringdroid-dispatch.sh "Fix taskbar flicker on rotate"
```

Each cycle spawns a subagent that reads the latest `boringdroid-handoff-N.md` (or `boringdroid/CLAUDE.md` on a fresh start), makes a concrete change, builds `boringdroid_x86_64-userdebug`, boots the emulator, polls `sys.boot_completed`, exercises the relevant feature, and writes `boringdroid-handoff-(N+1).md`. The loop exits when a handoff ends with `## STATUS: COMPLETE` and verification confirms the emulator is booted. Tunable via `BORINGDROID_MAX_BUDGET`, `BORINGDROID_MAX_CYCLES`, `BORINGDROID_MODEL`, `BORINGDROID_LUNCH_TARGET` env vars (see the script header).
