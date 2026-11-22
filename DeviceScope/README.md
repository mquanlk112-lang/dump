# DeviceScope

A SwiftUI device-status utility for iOS and TrollStore.

## Features
- Device name, model and iOS version
- Battery percentage and charging state
- Low Power Mode status
- iOS thermal pressure state
- Device uptime
- Memory used by this app process only
- Manual refresh and automatic 5-second refresh while the app is active
- Optional Live Activity for the Lock Screen and Dynamic Island on supported devices
- One-tap system-wide status HUD controlled by the companion rootless SpringBoard tweak

## Dynamic Island status

Tap **Bật** in DeviceScope before switching to a game. The Live Activity shows the latest battery, thermal-state and DeviceScope memory snapshot. On iPhone 14 Pro with iOS 16.1 or later, this appears in the Dynamic Island; tapping it opens DeviceScope.

This is a snapshot, not a background sensor monitor. iOS may suspend DeviceScope after another app becomes active, so the Live Activity cannot promise continuous 5-second updates while a game is in the foreground. Reopen DeviceScope and refresh to publish a newer snapshot. Live Activities must also be enabled in iOS Settings.

## Limitations

It does not overclock the CPU, kill other apps, modify game memory, inject into another app, or hide jailbreak files. RAM shown is process memory, not system-wide free memory. Thermal status is Apple's qualitative state, not a temperature measurement in °C.

## Build

Run `scripts/build-tipa.sh` on a Mac with Xcode and XcodeGen installed, or use the GitHub Actions workflow at `.github/workflows/build-devicescope.yml`.

The output is `out/DeviceScope.tipa`, containing `Payload/DeviceScope.app` and the embedded Live Activity extension. The main app targets iOS 15.0; the Live Activity extension in this build targets iOS 16.2 or later.


## System-wide HUD

Install `DeviceScopeHUD.deb` with Sileo/Zebra on a rootless Dopamine/ElleKit jailbreak, then respring SpringBoard. Open DeviceScope and tap **Bật** under **HUD nổi toàn hệ thống**. The floating panel can be dragged; tap it to expand or collapse.

The tweak is filtered to `com.apple.springboard` only. It reads battery state, iOS thermal pressure, a free-page RAM estimate and device uptime. It does not load into Free Fire, inspect game memory, patch the game, or read match state. A third-party overlay can still be disallowed by a game's own rules; this package does not bypass such checks.
