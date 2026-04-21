# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Boringdroid is an AOSP-extending project that layers a minimal multi-window patchset on top of stock Android (supports AOSP 9.0 – 14.0). This working tree is the `boringdroid-14.0.0` branch. The repository root is an AOSP checkout assembled via `repo`; the `boringdroid/` directory you are in contains the project's own meta files (README, ARCHITECTURE, CONTRIBUTING, this CLAUDE.md), while the customizations themselves live scattered across forked AOSP repos (notably `frameworks/base`) and a handful of boringdroid-owned repos under `vendor/` and `device/`.

## Repository Layout

The AOSP root (the parent of this `boringdroid/` directory) is assembled by `repo sync` from `https://github.com/boringdroid/manifest.git`. Boringdroid-specific code lives in:

- `vendor/boringdroid/` — vendor config, overlays, RRO, plus `boringdroid.mk` (adds `BoringdroidSettings` + `BoringdroidSystemUI` to `PRODUCT_PACKAGES` and sets `persist.sys.systemuiplugin.enabled=true`).
- `vendor/boringdroid/apps/BoringdroidSystemUI/` — SystemUI plugin that renders the taskbar and injects views into the nav bar. Builds via Soong (`Android.bp`); consumes `sysui_shared.jar` from SystemUI for task events.
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

For IDE-driven iteration on `BoringdroidSystemUI` or `BoringdroidSettings`, import the modules via Android Studio's Soong integration. The plugin also needs the framework patches and `sysui_shared.jar` from a full AOSP build to run correctly.

## Code Style

- Boringdroid apps follow the [AOSP code style](https://source.android.com/setup/contribute#contribute-to-the-code) — same rules as framework/system changes.

## Conventions for Claude

- **Do NOT add `Co-Authored-By: Claude ...` trailers (or any Claude attribution) to commit messages.** Author commits normally with no AI co-author line.
- **Wrap every edit inside a forked upstream AOSP file in `region boringdroid` markers.** Use the language's comment syntax:
  - Java / Kotlin / C / C++ / JS: `// region boringdroid` … `// endregion`
  - Shell / Python / Make: `# region boringdroid` … `# endregion`
  - XML: `<!-- region boringdroid -->` … `<!-- endregion -->`

  This applies to any file that exists in stock AOSP (notably `frameworks/base/`, `packages/apps/Launcher3/`, `system/*`, `art/`). Files wholly owned by boringdroid (`vendor/boringdroid/*`, `device/generic/boringdroid_x86_64/*`, `BoringdroidSystemUI`, `BoringdroidSettings`) don't need markers — they ship with boringdroid.
- **Keep forward-porting in mind when editing forked AOSP files.** Boringdroid tracks AOSP 9.0 – 14.0; the same patch is replayed against new AOSP releases. Keep diffs in upstream files minimal and additive — prefer hooks, overlays, or new standalone files over intrusive in-place edits. A change that reads cleanly in a `git diff` against `aosp/main` is one that will rebase cleanly next year.
- **Always import classes in Java/Kotlin code; do not use fully-qualified class paths inline.** Add an `import` at the top of the file and reference the class by its simple name in the body. The only exception is when the simple name would collide with another class already imported in the same file — in that case, use the fully-qualified name for the conflicting reference only.
- **Build boringdroid apps with Soong (`Android.bp`).** `BoringdroidSystemUI`, `BoringdroidSettings`, `Launcher3`, and any new boringdroid-owned apps ship as AOSP modules — they must build with `m <module>` as part of the `boringdroid_x86_64-userdebug` image. Use AOSP-hosted libraries (e.g. `androidx.test.runner`, `androidx.test.uiautomator_uiautomator`, `truth-prebuilt`) rather than Maven coordinates. Gradle is not used anywhere in the product pipeline — there are no `build.gradle.kts` / `./gradlew` files in these modules. New source sets (e.g. `androidTest/`) need a corresponding `android_test` stanza in `Android.bp`.
- **Keep dispatch / plan / handoff state out of production code.** Project-internal milestone labels (`M1 Task 4`, `Task 4e-b`, `Priority 1`, `handoff #17`, `post-M1`, etc.) belong in `docs/superpowers/plans/*.md` and `boringdroid-handoff-*.md`, not in Kotlin/Java/XML sources, `AndroidManifest.xml`, `Android.bp`, or RRO `config.xml`. When a comment's only purpose is to tie code to the roadmap cycle that introduced it, delete the comment; if there's a genuine WHY (a permission rationale, a resource-id invariant, a threading note), keep the WHY and drop the milestone reference. Future dispatch subagents: write the rationale in the handoff, not the file.
- Changes are split across many forked AOSP repos — before editing, confirm which repo owns the file (`git -C <path-to-repo> status`) so the commit lands in the right project.
- Boringdroid prefers small, targeted patches that could plausibly upstream: keep diffs minimal and resist refactors outside the change at hand (see `ARCHITECTURE.md`'s framing of the patchset as intentionally "boring").

## UI Rules for BoringdroidSystemUI

Rules distilled from the M5 redesign cycle. They apply to every plugin-owned overlay window (taskbar, action center, calendar, start menu, overview) and to any future surface added under `BoringdroidSystemUI`.

- **Overlay panels must sit above the 64dp taskbar, not overlap it.** The taskbar (`taskbar_window_height = 64dp`) is the bottom anchor for every other plugin surface. Prefer `Gravity.BOTTOM` with `y = R.dimen.panel_taskbar_gap` (8dp) — the taskbar is `TYPE_NAVIGATION_BAR`, so WMS auto-insets every bottom-anchored window above it and you only need the breathing gap. Do *not* add `taskbar_window_height` into the `marginBottom` math: it will be double-counted and push the panel 64dp too high. `Gravity.TOP` windows must subtract `R.dimen.taskbar_window_height` from their computed `y`. Fullscreen overlays (e.g. Overview) must not use `MATCH_PARENT` height — shrink the window height by the taskbar so the taskbar stays interactable underneath.
- **The taskbar must not overlap Launcher content.** The Launcher draws its hotseat at the bottom of its own window and positions icons using `mInsets.bottom` from the framework. If the taskbar advertises its raw visual height (`heightPx`) as the provided nav-bar inset, Launcher3's `hotseatBarBottomSpacePx = mInsets.bottom + minQsbMargin` adds only a couple of pixels and the hotseat icons end up flush against the taskbar's top edge — visually, the taskbar "overlaps" the Launcher. Fix: the taskbar's `InsetsFrameProvider` must report `heightPx + R.dimen.panel_taskbar_gap`, so Launcher (and any other full-height app) leaves that visible gap between its bottom-anchored content and the taskbar.
- **Global keyboard shortcuts belong in the plugin, not in framework edits.** Alt+Tab (recents) already flows through AOSP's `PhoneWindowManager.showRecentApps()` → `StatusBarManager` → `OverviewProxyService` → our `BoringdroidOverviewService.onOverviewShown(triggeredFromAltTab=true)`, so no framework changes are needed. The Meta (Windows) key is dispatched by `PhoneWindowManager.launchAllAppsViaA11y()` as `AccessibilityService.GLOBAL_ACTION_ACCESSIBILITY_ALL_APPS`; claim it from the plugin with `AccessibilityManager.registerSystemAction(...)` so the framework's existing call-site ends up triggering `AllAppsWindow`. Requires `platform_apis` + platform signature (for `MANAGE_ACCESSIBILITY`), which the plugin already has. Remember to `unregisterSystemAction` in `onDestroy`.
- **Bottom-anchored action buttons must use `Modifier.weight(1f)` on the scrolling sibling, not an outer `verticalScroll`.** The "Clear all" row in the Action Center is the canonical example. If the outer container scrolls, the button lives in the scrolled area and UiAutomator's visibility filter will report it as unreachable the moment the notification list fills the viewport. Keep the panel root a non-scrolling `Column` that fills the Surface, give the list `weight(1f)` to absorb the remaining space, and park the action button immediately after it — the LazyColumn scrolls internally, the button stays pinned at the bottom, and `By.res(PLUGIN_PKG, "clear_all_button")` always resolves.
- **Budget panel heights for the content that ships, not for the minimum case.** When a fixed-size QS grid or section would otherwise clip because `LazyVerticalGrid` inside a non-scrolling `Column` needs a bounded height, size the grid's `height()` constraint to the full row count (3 rows × 88dp tiles + 8dp gutters ≈ 300dp for the 3×3 QS grid). If the surrounding Surface then needs to grow, grow `action_center_window_height` in `dimens.xml` rather than shrinking the grid; never leave tiles physically clipped at the bottom.
- **Taskbar callbacks are the plugin's narrow UI contract.** Every new taskbar affordance (recents button, overflow menu, quick settings entry) lands as a new field on `TaskbarCallbacks` in `taskbar/Taskbar.kt` and is wired through `SystemUIOverlay.onCreate`. Do not instantiate window/service references from inside `Taskbar.kt`'s Compose tree — the callbacks are hoisted precisely so the composable stays hermetic for recomposition and preview/testing.
- **Keep mutually exclusive panels in sync via both-side dismissal.** The Calendar, Overview, and Action Center panels are mutually exclusive surfaces. When wiring a new toggle in `SystemUIOverlay`, the click handler must dismiss the other exclusive panels before opening its own, and `closeSystemDialogsReceiver` must call `dismiss()` / `hide()` on every exclusive panel — otherwise `adb shell input keyevent HOME` or the next taskbar tap leaves a ghost window hanging.
- **When exposing a Compose element to UiAutomator, prefix test tags with `pkg:id/` and use `clearAndSetSemantics` if the element is also wrapped in `clickable`.** Compose's `testTagsAsResourceId = true` writes the tag into `AccessibilityNodeInfo.setViewIdResourceName`, so tags must read `"com.boringdroid.systemui:id/xxx"` to satisfy `By.res(PLUGIN_PKG, "xxx")`. When both `testTag` and `contentDescription` must land on the same a11y node (e.g. to make `By.res(...).descContains(...)` match), replace `.semantics { ... }` with `.clearAndSetSemantics { ... }` on the `clickable` Box — plain `.semantics` on a `Modifier.clickable` chain emits two separate `AccessibilityNodeInfo`s and the selector mismatches.
- **When removing UI (a QS tile, a start-menu section, a settings entry), delete the full supply chain.** For a QS tile that means: the `QsTile(...)` invocation in `QsGrid`, the `collectAsState()` variable, the `MutableStateFlow` + public `StateFlow` + `set…()` in `QsTileStore`, the `LABEL_…` constant, the matching `toggle…()` in `QsController`, and any import of the (now unreferenced) Material icon. Half-removed code rots fast — unreferenced flows survive in IDE autocomplete and tempt re-reintroduction one milestone later.

## Dispatch Automation

`.claude/commands/dispatch.md` plus `.claude/scripts/boringdroid-dispatch.sh` and `.claude/scripts/dispatch-progress.py` implement an automated handoff-driven development loop for boringdroid, adapted from the Digitalis project's dispatch system. Invoke from within Claude Code with `/dispatch [task description]`, or from a shell:

```bash
.claude/scripts/boringdroid-dispatch.sh "Fix taskbar flicker on rotate"
```

Each cycle spawns a subagent that reads the latest `boringdroid-handoff-N.md` (or `boringdroid/CLAUDE.md` on a fresh start), makes a concrete change, builds `boringdroid_x86_64-userdebug`, boots the emulator, polls `sys.boot_completed`, exercises the relevant feature, and writes `boringdroid-handoff-(N+1).md`. The loop exits when a handoff ends with `## STATUS: COMPLETE` and verification confirms the emulator is booted. Tunable via `BORINGDROID_MAX_BUDGET`, `BORINGDROID_MAX_CYCLES`, `BORINGDROID_MODEL`, `BORINGDROID_LUNCH_TARGET` env vars (see the script header).
