# DeviceScope HUD

Rootless Theos tweak for Dopamine / ElleKit on iOS 15 and later.

- Loads only inside `com.apple.springboard`
- Displays a draggable, tap-to-expand device status panel above other apps
- Reads battery level/state, iOS thermal pressure, free-page RAM estimate and uptime
- Receives show/hide commands through Darwin notifications from the DeviceScope app
- Does not load in Free Fire, read game memory, patch game code, or inspect match state

Install `DeviceScopeHUD.deb` using Sileo/Zebra. Respring SpringBoard, open DeviceScope and tap HUD **Bật**. Tap the floating panel to expand/collapse it; drag to reposition.
