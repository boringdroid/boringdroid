# boringdroid

## Introduction

boringdroid is an `AOSP` extending project based on `AOSP` 9.0, and it provides the patch set to use multi-window in `AOSP` default. The patch set is boring, and most of problems the patch set resolves look like disappearing on `master` branch, so the project is boring, that the reason I calls it boringdroid.

## Preview

![screenshot with multi-window](/images/screenshot-multi-window.png)

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

The `BoringdroidSystemUI` uses the `SystemUI`'s plugin hook library to add custom views to system navigation bar. And it also uses `sysui_shared.jar` exposed by `SystemUI` to receive task changed events for taskbar. For better developing experience, it provides a gradle script to develop the `BoringdroidSystemUI` in latest `AndroidStudio`. For more detail, please see the document in the project [BoringdroidSystemUI](https://github.com/boringdroid/vendor_packages_apps_BoringdroidSystemUI).

## android-x86 porting

Also, there is an version ported to [android-x86](https://www.android-x86.org/). We only port some important bug fixes and feature to android-x86 version, and keep the origin android-x86 configuration, such as [Taskbar](https://github.com/farmerbb/Taskbar).

We can use following script to download and build android-x86 porting boringdroid:

```shell
mkdir boringdroid-x86
cd boringdroid-x86
repo init -u https://github.com/boringdroid/manifest.git -b boringdroid-x86-9.0.0
repo sync -c -d --no-tags --no-clone-bundle

source build/envsetup.sh
lunch android_x86_64-userdebug
m iso_img
```

Then we can follow [android-x86 installation howto](https://www.android-x86.org/installhowto.html) to install built iso files to real machine or vbox.

### Update:

The [android-x86](https://www.android-x86.org/) and [BlissOS](https://www.blissos.org/) have accepting those patches to their code repositories.

### Special thanks

Thanks Roger Truttmann in team bliss to help design logo.

## License

The modified `AOSP` project uses the origin license. And the `boringdroid` created projects will uses its custom license on its project.
