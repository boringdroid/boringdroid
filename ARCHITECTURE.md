# The architecture of boringdroid

Boringdroid is an AOSP patchset, not a separate codebase. The pieces live in
forked AOSP repos and in a few boringdroid-owned projects under `vendor/`
and `device/`. The whole tree is assembled by `repo sync` from
[the manifest](https://github.com/boringdroid/manifest) and built with
`lunch boringdroid_x86_64-userdebug && m`.

## Patches on top of AOSP

Boringdroid keeps its modifications to upstream AOSP small and additive,
so the same patch can be replayed against new releases each year. The
visible framework changes on this branch are:

- Freeform windowing enabled by default. Most of the heavy lifting now
  lives in stock AOSP 14; boringdroid's contribution is a vendor-side
  RRO flipping `config_freeformWindowManagement` true.
- `persist.sys.systemuiplugin.enabled=true` and other plugin-related
  defaults set in `boringdroid.mk`, so SystemUI loads
  `BoringdroidSystemUI` at boot.
- Suppression of the stock NavigationBar window so the plugin's taskbar
  is the sole bottom-of-screen bar (`NavigationBarController.java`).
- A configurable knob for the freeform corner radius in WMShell
  (`R.dimen.decor_corner_radius`).
- A `setCornerRadius` fallback for freeform task surfaces when
  `persist.wm.debug.caption_on_shell=false` (`Task.java`; see
  [Freeform window rounded corners](#freeform-window-rounded-corners)).

Every edit to a forked AOSP file is wrapped in `// region boringdroid`
markers so the diff stays cleanly reviewable against `aosp/main` and
rebases reliably across versions.

## BoringdroidSystemUI

`vendor/boringdroid/apps/BoringdroidSystemUI/` is a SystemUI plugin
loaded into the `com.android.systemui` process via SystemUI's plugin
framework. It is built with Soong (`Android.bp`); there is no Gradle in
the product pipeline. It depends on `SystemUIPluginLib` (compile-time
plugin interfaces, supplied by SystemUI at runtime) and statically
links `SystemUISharedLib` for `ActivityManagerWrapper`,
`TaskStackChangeListeners`, etc.

What the plugin renders:

- A taskbar pinned above the bottom of the screen, showing running tasks
  and the All Apps grid.
- A start menu (Meta key / all-apps button) listing installed apps.
- An action center with notifications, quick-settings tiles, and a
  "Clear all" affordance.
- A calendar / clock panel with today's agenda from `CalendarContract`.
- An Overview surface bound by SystemUI's `OverviewProxyService` and
  driven by Alt+Tab through the framework's existing
  `PhoneWindowManager.showRecentApps()` path.

The plugin joins `sharedUserId="android.uid.systemui"` so it can claim
permissions (such as `FORCE_STOP_PACKAGES`) that the SystemUI process
needs at runtime. The matching privapp-permissions allowlist ships at
`vendor/boringdroid/permissions/`.

## BoringdroidSettings

`vendor/boringdroid/apps/BoringdroidSettings/` is a standalone Compose app
that hooks into the stock Settings dashboard via
`com.android.settings.action.EXTRA_SETTINGS`. It currently exposes two
screens. App Behavior sets a per-app default windowing mode (freeform,
fullscreen, or system default), with filter chips, "Select all", and a
bulk-action bar. About Boringdroid is a hero card with Website, GitHub,
and Report-issue buttons, followed by Project, Authors, and System info
sections.

Both screens use stable test tags via `Modifier.bdTag("...")`, which
resolve to `com.boringdroid.settings:id/...` resource IDs so the
UiAutomator instrumentation suite under `app/src/androidTest/` can drive
them headlessly. The suite is wired through `Android.bp` as an
`android_test` stanza alongside the main app.

## Launcher3 fork

`vendor/boringdroid/apps/Launcher3/` is a fork of AOSP's Launcher3 with
boringdroid-specific tweaks. It is the package
`config_recentsComponentName` is redirected to (via the
`BoringdroidSystemUIOverlay` RRO, see below) and the package whose
hotseat needs to leave a visible gap above the plugin's taskbar.

## RROs

`vendor/boringdroid/rro/` contains the runtime resource overlays that
boringdroid ships. All four are static (`android:isStatic="true"`) and
get registered through `PRODUCT_PACKAGES` in
`vendor/boringdroid/boringdroid.mk`.

`BoringdroidFrameworkOverlay` targets the `android` package and overrides
`freeform_decor_corner_radius`, which WMS reads when
`caption_on_shell=false`. `BoringdroidWallpaperOverlay` supplies the
purple-orb default wallpaper. `BoringdroidLauncher3Overlay` hides
Launcher3's Google search widget on the workspace.
`BoringdroidSystemUIOverlay` neutralises Launcher3QuickStep's nav-bar
inset override (currently opt-in; see the commented block in
`boringdroid.mk`).

## device_generic_boringdroid_x86_64

`device/generic/boringdroid_x86_64/` is the emulator target, derived
from `sdk_phone_x86_64`. The product is what `lunch` selects: it
inherits `vendor/boringdroid/boringdroid.mk`, pins
`PRODUCT_PACKAGE_OVERLAYS` to the device-level overlay tree, copies the
PC feature flags into `/vendor/etc/permissions/`, and ships a
freeform-tuned `config.ini.pc` for the emulator window size.

The emulator is the primary development target. There is no separate
hardware product line.

## Freeform window rounded corners

Freeform windows clip their content with rounded corners to match the
rest of AOSP's visual style. The cut-off corner area has to be
transparent at composition time so the wallpaper or the task below
shows through, not painted over with the window background.

Pre-AOSP-14 builds clipped via a `ViewOutlineProvider` on the activity's
`DecorView`. That approach only clipped foreground drawing; the window's
own rectangular background still painted into the cut-off pixels. The
bug was filed as [issue
#11](https://github.com/boringdroid/boringdroid/issues/11) in 2023.

AOSP 14 has two clipping paths, chosen at boot by
`persist.wm.debug.caption_on_shell`:

### Shell-rendered caption (prop true, default in AOSP 14)

WMShell owns the caption and the corner radius. Upstream's
`WindowDecoration` calls `SurfaceControl.setCornerRadius` directly on
the freeform task surface:

```java
if (mTaskInfo.getWindowingMode() == WINDOWING_MODE_FREEFORM) {
    startT.setCornerRadius(mTaskSurface, params.mCornerRadius);
    finishT.setCornerRadius(mTaskSurface, params.mCornerRadius);
}
```

SurfaceFlinger then clips at composition, so the cut-off corner is a
genuine alpha hole. Boringdroid's contribution on this path is the
configurable knob: an early WMShell patch exposes
`R.dimen.decor_corner_radius` (default 8dp) in the Shell resources
package so an RRO under `vendor/boringdroid/` can retune the radius
without touching framework Java.

### Legacy DecorView caption (prop false)

With shell-side caption disabled, no `WindowDecoration` is constructed
for the freeform task and the caption is drawn in-process by the app's
`DecorView` via `R.layout.decor_caption`. The shell-side
`setCornerRadius` call never fires, so without intervention this path
regresses to the 2023 visual.

Boringdroid covers this path from WMS itself.
`Task.updateFreeformCornerRadius(SurfaceControl.Transaction)` runs from
`prepareSurfaces()` and pushes `setCornerRadius` onto the task's
`mSurfaceControl` when the task is in `WINDOWING_MODE_FREEFORM` and
`ViewRootImpl.CAPTION_ON_SHELL` is `false`. A cached
`mLastAppliedCornerRadius` keeps the transaction silent on no-op frames,
and the `CAPTION_ON_SHELL` guard keeps WMS out of the way whenever
WMShell is the writer. The dimen lives in framework-res
(`core/res/res/values/dimens.xml`) and is overridable via
`BoringdroidFrameworkOverlay`.

Both paths end up at `SurfaceControl.setCornerRadius`, so the cut-off
corner composites as transparent regardless of which caption stack is
active.

## Peek caption

[Issue #1](https://github.com/boringdroid/boringdroid/issues/1) asks for
a drop-down title bar on a maximized window — when a freeform window
goes fullscreen, the in-window caption disappears and there is no
keyboard-free way to restore / minimize / close the window. Peek
caption fills that gap with a 1px hover edge at the top of the display
that, when the cursor crosses it, slides a 40dp caption panel down with
those three buttons.

The implementation lives entirely in BoringdroidSystemUI — no framework
or WMShell patch — under
`vendor/boringdroid/apps/BoringdroidSystemUI/app/src/main/java/com/boringdroid/systemui/peek/`:

- `PeekCaptionController` owns the lifecycle. It checks two sysprops at
  start: `persist.boringdroid.peek_caption` (default on; the feature
  kill switch) and `persist.wm.debug.desktop_mode` /
  `persist.wm.debug.desktop_mode_2` (the same pair
  `DesktopModeStatus.isAnyEnabled` reads). If either desktop-mode prop
  is true, peek does not arm — WMShell's `DesktopModeWindowDecoration`
  keeps the in-window caption visible after maximize, so a peek caption
  would just duplicate it.
- `TaskFullscreenMonitor` registers a `TaskStackChangeListener` via
  `TaskStackChangeListeners.getInstance()` and remembers each task's
  previous windowing mode. When a task transitions
  `WINDOWING_MODE_FREEFORM → WINDOWING_MODE_FULLSCREEN` (the legacy
  `CaptionWindowDecoration → TaskOperations.maximizeTask` path) it
  becomes the active peek target. Tasks that launched directly
  fullscreen are left alone, so the peek does not appear on, e.g., a
  fullscreen game.
- `HoverEdgeWindow` is a 1px-tall `TYPE_NAVIGATION_BAR_PANEL` overlay
  that catches `ACTION_HOVER_ENTER`/`MOVE` and notifies the controller.
  No insets are advertised, so it does not steal screen real estate.
- `PeekPanelWindow` is the slide-down Compose panel itself. The
  controller drives restore via
  `WindowContainerTransaction.setWindowingMode(token, FREEFORM)`,
  minimize via `WCT.reorder(token, /*onTop=*/ false)` plus a home-launch
  fallback, and close via `WCT.removeTask(token)`. `WindowOrganizer`
  applies these transactions directly from the plugin process; no
  shell-transition player is needed since the bounds-only mode flip
  resolves to a regular task configuration change.

The instrumentation suite under
`app/src/androidTest/.../PeekCaptionTest.kt` exercises the legacy path
end-to-end: it pins BoringdroidSettings into freeform via
`ActivityOptions.setLaunchWindowingMode` + an organizer
`setBounds` belt-and-braces (because `am start --windowingMode 5` is
flaky once any prior task has spent time in fullscreen), taps the
WMShell caption maximize button to drive the freeform → fullscreen
transition through the shell-transition wrapper (`onTaskStackChanged`
only fires for that path, not for direct organizer mode flips), then
asserts on `dumpsys window windows` that the peek edge / panel windows
attach and detach correctly.

## Taskbar context menu

Right-clicking (or long-pressing) a running-app icon in the taskbar
opens a 3-item dropdown — Maximize / Restore, Minimize, Close — that
shares the same `wm/TaskActions.kt` helper the peek caption uses, so
the two surfaces produce identical results. The middle item is
state-aware: it reads "Maximize" while the task is freeform and
"Restore" while it is fullscreen, derived from
`BdTaskInfo.mode` populated in `TaskbarState.refreshRunningTasks`.

`TaskActions.toggleMaximize` reads
`persist.wm.debug.desktop_mode[_2]` and mirrors the WMShell decor that
prop selects: legacy decor flips windowing mode, modern desktop-mode
decor toggles bounds between the display's stable bounds and the
centred default desktop bounds.
