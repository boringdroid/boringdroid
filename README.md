# boringdroid

## Introduction

boringdroid is an `AOSP` extending project based on `AOSP` 9.0, and it provides the patch set to use multi-window in `AOSP` default. The patch set is boring, and most of problems the patch set resolves look like disappearing on `master` branch, so the project is boring, that the reason I calls it boringdroid.

## Preview

![boringdroid multiwindow screenshot](images/screenshot-multi-window.png)

The boringdroid adds minimum button for window, and provides the smooth resizing experience. The boringdroid also provides exhanced taskbar to show running task list and installed app list. The next step the boringdroid will do is to provide system tray in taskbar.

## Download

```shell
mkdir boringdroid
cd boringdroid
repo init -u https://github.com/boringdroid/manifest.git -b boringdroid-9.0.0
repo sync -c -d --no-tags
```
## Build

```shell
source build/envsetup.sh
lunch boringdroid_x86_64-userdebug
m
```

The boringdroid now runs in emulator, what is convenient to debug and test modification. So the product `boringdroid_x86_64` bases on the `goldfish`. After building, we can execute `emulator` to start emulator.

## BoringdroidSystemUI

The `BoringdroidSystemUI` uses the `SystemUI`'s plugin hook library to add custom views to system navigation bar. And it provides a gradle script to develop the `BoringdroidSystemUI` in latest `AndroidStudio`. For more detail, please see the document in the project [BoringdroidSystemUI](https://github.com/boringdroid/vendor_boringdroid/tree/boringdroid-9.0.0/packages/apps/BoringdroidSystemUI).

## Porting

There is a plan to port boringdorid to android-x86.

## License

The modified `AOSP` project uses the origin license. And the `boringdroid` created projects will uses its custom license on its project.