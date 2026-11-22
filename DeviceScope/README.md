# DeviceScope

A clean SwiftUI device-status utility for iOS and TrollStore.

## Features
- Device name, model and iOS version
- Battery percentage and charging state
- Low Power Mode status
- iOS thermal pressure state
- Device uptime
- Memory used by this app process only
- Manual refresh and automatic 5-second refresh

It does not overclock the CPU, kill other apps, modify game memory, or hide jailbreak files. RAM shown is process memory, not system-wide free memory. Thermal status is Apple's qualitative state, not a temperature measurement in °C.

## Build
Run \`scripts/build-tipa.sh\` on a Mac with Xcode and XcodeGen installed, or use the GitHub Actions workflow at \`.github/workflows/devicescope-build.yml\`.

The output is \`out/DeviceScope.tipa\`, containing \`Payload/DeviceScope.app\`. Minimum deployment target is iOS 15.0; the target device on iOS 16.7.16 is within that range.
