# Cores

A small menu bar app that shows CPU core load and temperatures. Click the readout in the menu bar to open a panel with per-core bars, GPU memory, 60-second load and temperature history, and a sensor list (CPU, GPU, SSD, battery, fans).

## Download

**[Download Cores.dmg](https://github.com/Jam0r85/Cores/releases/latest/download/Cores.dmg)** (Apple Silicon Mac, macOS 14 or later). Open it and drag Cores into Applications. It's signed and notarized, so it opens without a security warning.

The repo is private, so sign in to GitHub in the browser on the Mac you're downloading to. Every release is on the [Releases page](https://github.com/Jam0r85/Cores/releases).

## Build and install

```bash
./build.sh            # builds build/Cores.app
./build.sh --install  # also copies it to /Applications and launches it
```

The build is signed ad-hoc, which is enough to run it on the Mac that built it. To share it, use `release.sh` below.

Open `Package.swift` in Xcode to edit the app with previews and the debugger.

## Command-line checks

```bash
build/Cores.app/Contents/MacOS/Cores --dump             # print live readings
build/Cores.app/Contents/MacOS/Cores --snapshot ./shots # render the panel to PNGs
build/Cores.app/Contents/MacOS/Cores --selftest ./shots # open/close the panel in a window and report sampling and size
```

## Sampling

Every second while the panel is open. Every 3 seconds while it's closed, at background priority, reading only core load and CPU/GPU temperature; fans, GPU memory, SSD and battery are read only while the panel is open. While closed, the panel's views aren't updated at all, and the menu bar image is only redrawn when the numbers or bars it shows change.

Measured with `--selftest`: about 0.05% of one core with the panel closed, about 3.5% while it's open.

## How it reads the hardware

- **Core load:** the kernel's per-CPU tick counters (`host_processor_info`), grouped into tiers using `hw.perflevelN` (Super and Performance on the M5 Pro).
- **CPU, GPU and fans:** the SMC. CPU is the average of the `Tp*`/`Te*` sensors, GPU the average of 16 evenly spread `Tg*` sensors.
- **SSD, battery:** the HID sensor hub (refreshed every 5 seconds while the panel is open). Its SoC die sensors stand in for CPU temperature only on a Mac where the SMC can't be read.
- **GPU memory:** the GPU driver's statistics in the I/O registry (in use and allocated), and Metal's `recommendedMaxWorkingSetSize` for the maximum. Apple Silicon has no separate VRAM; this is the GPU's share of unified memory.

Apple has no public API for temperatures, so these readers use undocumented interfaces. A macOS update could break temperature readings; core load uses a supported API. The app can't be sandboxed or go on the Mac App Store for the same reason.

## Releasing

```bash
./release.sh 1.1
```

This sets the version, builds the app, signs it with your Developer ID certificate, has Apple notarize it, packages `Cores.dmg` (also signed and notarized), tags the commit, pushes, and creates the GitHub release with the .dmg attached. Commit your changes first.

One-off setup on the Mac you release from:

1. **Developer ID certificate:** Xcode → Settings → Accounts → your team → Manage Certificates → + → Developer ID Application.
2. **Notary credentials:** create an app-specific password at [account.apple.com](https://account.apple.com) (Sign-In and Security → App-Specific Passwords), then run `xcrun notarytool store-credentials Cores-notary --team-id BAZ32PFTJS` and enter your Apple ID and that password when asked. They're kept in your keychain.
3. **GitHub CLI:** `gh auth login` (installed at `~/.local/bin/gh` on the original Mac).
