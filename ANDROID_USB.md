# Android USB fork

This fork adds Android USB discovery, ADB port forwarding and reconnection to
the macOS sender. The connection panel includes Chinese instructions and
separate Android USB status. Upstream: https://github.com/peetzweg/opendisplay.
The original GPL-3.0 license is preserved.

## Use

1. Install Android platform-tools (`adb`) on the Mac. The app checks
   `~/.local/bin/adb`, Homebrew paths and `~/Library/Android/sdk/platform-tools/adb`.
   You can also choose an executable in the connection panel.
2. Install the community Android receiver from
   https://github.com/josepacelli/opendisplay-android
   (tested with version 0.0.54, package `io.github.josepacelli.opendisplay`).
   The official Android beta uses a different package/transport and is not
   detected by this USB integration.
3. Enable USB debugging and authorize the Mac on the tablet, then plug it in.
4. Launch **OpenDisplay**. Grant this development app Screen Recording;
   Accessibility is needed for tablet touch input. Its existing Debug bundle
   identifier and signing requirement remain stable despite the visible name.
   It can replace `/Applications/OpenDisplay.app`; quit the running sender,
   copy the built app there without re-signing, and launch the installed copy.
5. Leave the app running. It scans every two seconds, creates a free local
   ADB forward to receiver port 9000, wakes/opens the receiver and connects.
   Unplugging releases the display; replugging rebuilds the transport using
   the same device identity, preserving macOS display arrangement.

**Disconnect** pauses auto-connect for that device, including after app restart.
**Connect** resumes it; **Reconnect** restarts the receiver connection. A deleted
forward is repaired even if the device never leaves the ADB device list.
**Rescan** checks again for a newly installed receiver.

Other Android devices without this receiver are not started or forwarded.
Wireless ADB and emulators are excluded. Existing forwards are not reused or
overwritten. On normal quit, only forwards allocated by this app instance are
removed. Forced termination may leave a forward until the USB device is unplugged.
No `adb kill-server`, root access or global Android settings changes are used.

Wi-Fi and Apple USB retain the upstream connection paths. This change does not
resolve an existing macOS Local Network permission denial for Wi-Fi.

## Build on this Apple Silicon Mac

With macOS Command Line Tools installed (full Xcode is optional):

```sh
./tools/build-usb-dev.sh
./run.sh
```

Output: `build/Build/Products/Debug/OpenDisplay.app`.
The stable Debug bundle ID and designated signing requirement follow AGENTS.md.
Do not rebuild or re-sign after granting permissions during a test session.
The sender does not use Sparkle auto-updates in this fork, so the official
release cannot overwrite the added USB support. Updates require rebuilding.
The upstream Xcode project and receiver targets remain available.

## Regression checks

```sh
mkdir -p build
swiftc -swift-version 5 Mac/AndroidUSB.swift tools/test-android-usb.swift -o build/test-android-usb
build/test-android-usb
```

These checks exercise an injectable ADB command runner: hotplug, a new transport
ID without an offline snapshot, lost forwarding, manual opt-out and persistence,
authorization state, unrelated devices, failure recovery, in-flight cancellation,
cleanup, and bounded real subprocess execution. They also run in GitHub Actions.
Physical tablet testing is separate from these simulated transport transitions.
