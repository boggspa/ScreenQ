# Screen Q Broadcast Upload Extension (scaffolding)

Apple's `RPBroadcastSampleHandler` runs in a separate, sandboxed process and
is the only supported way for a third-party iOS / iPadOS app to capture
the *system-wide* screen. It is one-way: capture only, no input injection.

This target is development-only scaffolding. The main app target does not
depend on or embed the extension in public builds.

## Wire it up

1. In Xcode: **File → New → Target → Broadcast Upload Extension**.
2. Use product name `ScreenQBroadcastExtension`.
3. Use bundle id `<your-app-bundle-id>.ScreenQBroadcastExtension`.
4. Select the same team as the host app.
5. After Xcode generates the target, replace the auto-generated files with
   the ones in this folder:
   - `SampleHandler.swift`
   - `BroadcastSetupViewController.swift`
   - `Info.plist`
6. (Optional but recommended) Add an App Group, e.g.
   `group.<your-app-bundle-id>`, in both the host app and the extension
   so the host can hand session details to the extension via
   `UserDefaults(suiteName:)`.
7. In the host app, set:

   ```swift
   appState.replayKitModel.broadcastExtensionBundleID =
       "<your-app-bundle-id>.ScreenQBroadcastExtension"
   ```

   This pre-selects the Screen Q extension in `RPSystemBroadcastPickerView`.

## What this does NOT do

- **No touch / keyboard / pointer injection.** iOS does not expose any API
  for that to a third-party app, with or without an extension.
- **No bypass of the 50 MB extension memory limit.** Use the hardware
  H.264 encoder (`VTCompressionSession`) and discard sample buffers
  promptly.
- **No private API usage.** This file is intentionally close to Apple's
  template.
