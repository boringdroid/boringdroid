# The architecture of the boringdroid project

## AOSP

The boringdroid project is based on the `AOSP`, so it follow the main architecture of `AOSP`.

## MultiWindow

The MultiWindow of the boringdroid project, follows the `AOSP`'s `freeform` mechanism, and enable it default. We also add mechanism to save/restore window bounds. The more detail, you can see the commit [ Add basic freeform bounds/windowing mode persistence](https://github.com/boringdroid/platform_frameworks_base/commit/1eee9a5eba93ea145e1926eddd5e8e989fac83f6).

## vendor_packages_apps_BoringdroidSystemUI

The `BoringdroidSystemUI` uses the `SystemUI`'s plugin hook library to add custom views to system navigation bar. And it also uses `sysui_shared.jar` exposed by `SystemUI` to receive task changed events for taskbar. For better developing experience, it provides a gradle script to develop the `BoringdroidSystemUI` in latest `AndroidStudio`. For more detail, please see the document in the project [BoringdroidSystemUI](https://github.com/boringdroid/vendor_packages_apps_BoringdroidSystemUI).

The plugin hook is disabled default, we should enable it and add our customization to it, such as fixing the plugin reloading problem, updating navigation bar layout, fixing task notify problem. The more detail, you can see the commit [Add BoringdroidSystemUI hook](https://github.com/boringdroid/platform_frameworks_base/commit/5669078669825defbb100ca43aa7b6b8697a2d52).

## vendor_packages_apps_BoringdroidSettings

It is a single app that uses `EXTRA_SETTINGS` to hook itself to the official Settings dashboard. It manages the setting page for enabling/disabling pc mode, enabling/disabling `BoringdroidSystemUI`, and showing the basic information about the boringdroid project.


## vendor_boringdroid

We place our vendor configuration and overlay to [vendor_boringdroid](https://github.com/boringdroid/vendor_boringdroid).

## device_generic_boringdroid_x86_64

The development of the boringdroid project bases on the Emulator. We use it for quick development and quick prototype. So we create a new device based on `sdk_phone_x86_64` for the Emulator.

## Freeform window rounded corners

Freeform windows must clip their content with rounded corners — leaving them rectangular looks out of place next to AOSP's stock rounded-everything aesthetic, and the cut-off corner area must reveal whatever is behind the window (wallpaper, the task below), not a flat color. Historically this was hard: pre-AOSP-14 builds used a `ViewOutlineProvider` on the activity's `DecorView`, which clipped the foreground but left the window's own rectangular background painted into the cut-off pixels (filed as [issue #11](https://github.com/boringdroid/boringdroid/issues/11), 2023).

There are now two clipping paths in the tree, picked at runtime by `persist.wm.debug.caption_on_shell`:

### Shell-rendered caption (`persist.wm.debug.caption_on_shell=true`, default in AOSP 14)

WMShell owns the caption and the corner radius. Upstream commit `f6871bed58da "Add rounded corners for freeform tasks"` (Maryam Dehaini @ Google, udc-qpr-dev) calls `setCornerRadius` directly on the freeform task's `SurfaceControl` inside `WindowDecoration.startT` / `finishT`:

```java
if (mTaskInfo.getWindowingMode() == WINDOWING_MODE_FREEFORM) {
    startT.setCornerRadius(mTaskSurface, params.mCornerRadius);
    finishT.setCornerRadius(mTaskSurface, params.mCornerRadius);
}
```

SurfaceFlinger clips at composition, so the cut-off corner is a true alpha hole — whatever is behind shows through. Boringdroid's contribution on this path is the configurable knob: commit [d9c618ea98e4 "wmshell: Update window corner radius with resource/dimen"](https://github.com/boringdroid/platform_frameworks_base/commit/d9c618ea98e4) exposes `R.dimen.decor_corner_radius` (default 8dp) in the Shell resources package, so an RRO under `vendor/boringdroid/` can tune the radius without touching framework Java.

### Legacy DecorView caption (`persist.wm.debug.caption_on_shell=false`)

When shell-side caption is off, no `WindowDecoration` is constructed for the freeform task and the caption is drawn in-process by the app's `DecorView` via `R.layout.decor_caption`. The shell-side `setCornerRadius` call never fires, so without intervention this path regresses to the 2023 visual.

Boringdroid covers this by applying the radius from WMS itself. `Task.updateFreeformCornerRadius(SurfaceControl.Transaction)` runs from `prepareSurfaces()` and pushes `setCornerRadius(mSurfaceControl, R.dimen.freeform_decor_corner_radius)` when:

1. The task is in `WINDOWING_MODE_FREEFORM`, and
2. `ViewRootImpl.CAPTION_ON_SHELL` is `false`.

A cached `mLastAppliedCornerRadius` ensures the transaction is only emitted on transitions (entering or leaving freeform), and the gate on `CAPTION_ON_SHELL` keeps WMS out of the way when WMShell is the writer. The dimen lives in framework-res (`core/res/res/values/dimens.xml`) so an RRO can tune it independently of the Shell-side dimen.

Both paths converge on the same mechanism — `SurfaceControl.setCornerRadius` — so the cut-off corner is composited as transparent regardless of which caption stack is active. Region markers (`// region boringdroid` … `// endregion`) wrap every edit in forked AOSP files so the patch stays cleanly reviewable against `aosp/main` for forward-porting.
