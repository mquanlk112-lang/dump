# FF Tool 2.0 — Single TIPA

This project builds one TrollStore-installable `FFTool.tipa` containing:
- The FF Tool dashboard UI (purple neon reference design).
- The same executable started in a separate root HUD mode.
- A draggable, expandable system overlay that displays device battery, iOS thermal-pressure state, estimated free RAM and uptime.

## Build and install

Build with Theos on macOS using `.github/workflows/build-devicescope.yml`. The workflow uploads only one artifact named `FFTool-TIPA`. Install the single `FFTool.tipa` from TrollStore. No separate .deb is produced or delivered as an install artifact.

Open FF Tool, press **Bật HUD trên màn hình**, then switch to another app. The HUD can be dragged and tapped to expand/collapse. Press **Tắt HUD nổi** in FF Tool to stop it.

## Scope and limits

The child HUD process is spawned by the TrollStore-installed app with the required persona settings and uses an accessibility-hosted system window. It does not inject into Free Fire, read game memory, alter gameplay, or inspect match data. The overlay is an independent device-status display. This requires the TrollStore entitlement path and may depend on iOS / TrollStore compatibility; build success does not prove on-device support.

Temperature uses Apple's thermal-pressure category rather than °C. Free RAM is an estimate based on free VM pages.


## HUD window host diagnostics

The system HUD retains its `SBSAccessibilityWindowHostingController` for the full delegate lifetime, obtains the window context ID through `UIWindow._contextId`, and registers via the private window-host API. A diagnostic status file is written under `/var/mobile/Library/Caches/com.minhquandev.fftool.hud-status.plist`; stages include `window_created`, `window_hosted`, and explicit registration failures. The UI reports registration state rather than treating a live PID as proof that the overlay is visible.

The window-host lifecycle was reviewed against Lessica's TrollSpeed (MIT); see `THIRD_PARTY_NOTICES.md`. The HUD remains an independent system-window process and is not injected into Free Fire.
