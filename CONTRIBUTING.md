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

### CI / gating policy

A single clean instrumentation run is the pass/fail signal. If a run fails, retry it **once** against a freshly-booted emulator before treating it as a regression.

Back-to-back stress runs (e.g. five consecutive `OverviewTest` invocations after a `force-stop` of `com.android.settings` and `com.boringdroid.systemui`) are a **development tool** for hunting races, not a CI gate. Under sustained instrumentation load the emulator accumulates GC/IO pressure; per-suite runtimes can double or triple after several minutes, and multiple otherwise-independent test paths will flake in the same run. Chasing that tail with longer timeouts lengthens the suite linearly without eliminating the race. If you need repeated stress runs, recycle the emulator between them.
