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
