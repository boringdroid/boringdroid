# Contributing to boringdroid projects

A big welcome and thank you for considering contributing to boringdroid open source projects! It’s people like you that make it a reality for users in our community.

Reading and following these guidelines will help us make the contribution process easy and effective for everyone involved. It also communicates that you agree to respect the time of the developers managing and developing these open source projects. In return, we will reciprocate that respect by addressing your issue, assessing changes, and helping you finalize your pull requests.

## Code of Conduct

We take our open source community seriously and hold ourselves and other contributors to high standards of communication. By participating and contributing to this project, you agree to uphold our Code of Conduct.
The boringdroid apps use [Spotless](https://github.com/diffplug/spotless) to format source code, you can use `./gradlew spotlessApply` to apply format changes for your commits before you push to projects for review. Other projects, you should follow the [AOSP's code style](https://source.android.com/setup/contribute#contribute-to-the-code).

## Getting Started

Contributions are made to this repo via Issues and Pull Requests (PRs). A few general guidelines that cover both:

- Search for existing Issues and PRs before creating your own.
- We work hard to makes sure issues are handled in a timely manner but, depending on the impact, it could take a while to investigate the root cause. A friendly ping in the comment thread to the submitter or a contributor can help draw attention if your issue is blocking.

### Issues

Issues should be used to report problems, request a new feature, or to discuss potential changes before a PR is created.

### Pull Requests

PRs to our projects are always welcome and can be a quick way to get your fix or improvement slated for the next release.

## Testing

### Instrumentation tests

The `BoringdroidSystemUI` instrumentation suite (including `OverviewTest`) runs on the `boringdroid_x86_64-userdebug` emulator. Build with Soong and install as a normal test APK:

```shell
m BoringdroidSystemUITests
adb install -r -t \
    out/target/product/boringdroid_x86_64/testcases/BoringdroidSystemUITests/x86_64/BoringdroidSystemUITests.apk
adb shell am instrument -w -e class \
    com.boringdroid.systemui.overview.OverviewTest \
    com.boringdroid.systemui.test/androidx.test.runner.AndroidJUnitRunner
```

### Manual smoke target — HelloBoringdroid

`samples/HelloBoringdroid` is the recommended target for manual
end-to-end checks: a single APK that drives freeform + caption,
peek caption (under `Meta`+`Up` and a top-edge hover), the
taskbar context menu (long-press its icon), Material You themed
icons (its `<monochrome>` layer is exercised by BoringdroidSystemUI's
`ThemedIconLoader`), and Material 3 dynamic color (the activity body
retints when wallpaper changes).

```shell
m HelloBoringdroid
adb install -r out/target/product/boringdroid_x86_64/system/app/HelloBoringdroid/HelloBoringdroid.apk
adb shell am start -n com.boringdroid.hello/.MainActivity
```

A per-surface verification recipe lives in
[`samples/HelloBoringdroid/README.md`](../samples/HelloBoringdroid/README.md).

### Peek caption gating

The peek caption (drop-down title bar over a maximized window, see
[ARCHITECTURE.md](ARCHITECTURE.md#peek-caption)) is gated by two sysprops
read at `PeekCaptionController.start`. The instrumentation suite covers
the legacy-decor happy path; the two early-return branches need a
plugin restart so they have to be exercised manually.

```shell
adb root && adb wait-for-device
adb shell whoami                        # must print "root"
```

Switch between scenarios by setting the props and restarting SystemUI
so the plugin re-reads them:

```shell
# Happy path: kill switch on, desktop mode off
adb shell setprop persist.boringdroid.peek_caption true
adb shell setprop persist.wm.debug.desktop_mode_2 false
adb shell setprop persist.wm.debug.desktop_mode  false

# Kill switch off
adb shell setprop persist.boringdroid.peek_caption false

# Decor gate: modern desktop-mode caption active
adb shell setprop persist.wm.debug.desktop_mode_2 true

# Apply
adb shell killall com.android.systemui
sleep 5
```

Use `false` rather than `""` — `setprop key ""` is shell-fragile and on
some Android builds leaves the previous value live. `SystemProperties.
getBoolean` treats `false`/`0`/`off` as false regardless, so the
explicit value is unambiguous and matches what the prop ends up as on
a fresh boot.

Then inspect which branch the controller took:

```shell
adb logcat -d -s PeekCaptionController
```

Expected output per scenario:

| Scenario                                    | Log line                                                                                       |
| ------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| Happy path                                  | *(no early-return line; peek arms — verify with `dumpsys window windows | grep BoringdroidPeek`)* |
| `persist.boringdroid.peek_caption=false`    | `persist.boringdroid.peek_caption=false; not arming peek caption`                              |
| `persist.wm.debug.desktop_mode[_2]=true`    | `DesktopMode active; not arming peek caption (in-window caption stays visible)`                |

If `killall com.android.systemui` returns `Operation not permitted`,
`adb root` did not promote — re-check `adb shell whoami` before assuming
the gate is broken. The plugin only re-reads the props on `start()`, so
without a SystemUI restart the change is invisible.

To trigger the peek panel itself headlessly (no host mouse hover
available), the existing `PeekCaptionTest` methods inject hover events
via `UiAutomation.injectInputEvent`:

```shell
adb shell am instrument -w -r \
    -e class 'com.boringdroid.systemui.PeekCaptionTest#peekPanel_appearsOnHoverAtTopEdge' \
    com.boringdroid.systemui.test/androidx.test.runner.AndroidJUnitRunner

# Holds the panel visible for 25s so you can screencap or inspect dumpsys
adb shell am instrument -w -r \
    -e class 'com.boringdroid.systemui.PeekCaptionTest#holdPeekForScreenshot' \
    com.boringdroid.systemui.test/androidx.test.runner.AndroidJUnitRunner
```

`adb shell input` cannot inject `ACTION_HOVER_ENTER` / `ACTION_HOVER_MOVE`
(it only knows `DOWN`/`UP`/`MOVE`/`CANCEL`), so the instrumentation path
is the only headless route. With an emulator window visible, the host
cursor at the screen's top edge works as expected.

### Taskbar context menu

The context menu over running-app icons is opened by **long-press**
on the icon. Coverage lives in `TaskbarContextMenuTest`, which uses
`UiObject2.longClick()` from UiAutomator.

We previously also bridged a real-mouse right-click via
`pointerInteropFilter` matching `MotionEvent.ACTION_DOWN` / `ACTION_BUTTON_PRESS`
with `BUTTON_SECONDARY`. That code was removed because the Android
Emulator never delivers `BUTTON_SECONDARY` to the guest — the
emulator binary only exposes a virtual keyboard and a stack of
touchscreen devices, host right-click is intercepted by the emulator
UI, and we verified there is no path to add a mouse device:

```shell
adb shell getevent -p | grep "name:"
#   "qwerty2"
#   "virtio_input_multi_touch_1..11"
#   "AT Translated Set 2 keyboard"
#   "Power Button"
```

Attempted fixes that did not work:

- `hw.mouse=yes` in `device/generic/boringdroid_x86_64/config.ini.pc`
  — `strings` on the emulator binary shows it doesn't recognise
  `hw.mouse` as a config key.
- `-qemu -device usb-mouse` — emulator aborts: "No 'usb-bus' bus
  found for device 'usb-mouse'".
- `-qemu -usb -device usb-mouse` — emulator boots but the Goldfish
  kernel does not ship USB HID drivers, so the guest never
  enumerates the mouse.

Long-press covers touch + synthetic-touch testing and is the single
trigger we support today. If boringdroid eventually ships on real
x86 hardware where a USB mouse IS enumerated, real-mouse right-click
can be reintroduced behind a build flag.

### CI / gating policy

A single clean instrumentation run is the pass/fail signal. If a run fails, retry it **once** against a freshly-booted emulator before treating it as a regression.

Back-to-back stress runs (e.g. five consecutive `OverviewTest` invocations after a `force-stop` of `com.android.settings` and `com.boringdroid.systemui`) are a **development tool** for hunting races, not a CI gate. Under sustained instrumentation load the emulator accumulates GC/IO pressure; per-suite runtimes can double or triple after several minutes, and multiple otherwise-independent test paths will flake in the same run. Chasing that tail with longer timeouts lengthens the suite linearly without eliminating the race. If you need repeated stress runs, recycle the emulator between them.
