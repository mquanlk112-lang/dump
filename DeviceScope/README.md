# FF Tool

A jailbreak-friendly iOS device-status companion with a SpringBoard-rendered floating HUD.

## UI

The dashboard follows the supplied dark violet / neon-purple reference: FF Tool header, green system-status card, one-tap HUD controls, four device metrics, and bottom navigation for Home, Game, Tools and Info.

## Single-package installation

The GitHub Actions workflow builds one rootless Debian package:

- FFTool-Combined.deb — contains the FF Tool app at /var/jb/Applications/FF Tool.app and the HUD tweak in the rootless MobileSubstrate directory.

Install the single .deb from Sileo or Zebra and respring SpringBoard. The package post-install script registers the app with uicache. Open FF Tool, tap Bật HUD trên màn hình, then switch to Free Fire. The app and tweak are installed together; TrollStore is not required for this combined package.

## HUD behavior

The tweak is filtered to com.apple.springboard only. It receives show/hide commands from FF Tool through Darwin notifications. The draggable panel reports battery percentage/state, Apple's qualitative thermal-pressure state, an estimate of free RAM pages and device uptime.

The tweak does not load into Free Fire, read or modify its memory, inspect match state, or bypass game protections. This is a device-status overlay only. Individual games may restrict third-party overlays.

## Measurement limits

- The temperature label is Apple's thermal-pressure state, not a physical temperature in °C.
- The app's RAM number is memory used by the FF Tool process only.
- The HUD's free-memory number is an estimate based on free VM pages.
- iOS may throttle status refreshes under load or while the app is suspended.

## Build

Push changes on branch devicescope-build or manually run .github/workflows/build-devicescope.yml. Successful runs upload a single artifact named FFTool-Combined-DEB.
