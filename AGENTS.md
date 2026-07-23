# MacGauge — Agent Guide

## Project overview

MacGauge is a lightweight macOS menu-bar system monitor for Apple Silicon
Macs, written in Swift (SwiftUI + AppKit) with a small C component for
temperature sensors. It shows live CPU usage in the menu bar; clicking opens
a stats panel (gauges for CPU/GPU/memory/disk, I/O speeds, top processes)
that can be pinned to the top-right corner of the screen as a compact,
always-on-top strip. Everything updates every 2 seconds.

- Single Xcode application target: `MacGauge` (bundle ID `com.even.MacGauge`)
- Platform: macOS 15.0+, Swift 5.0
- `LSUIElement = true` in `App/Info.plist` — agent app, no Dock icon
- Version is managed in `project.yml` (`MARKETING_VERSION`,
  `CURRENT_PROJECT_VERSION`)
- License: MIT

## Project layout

```
App/
  MacGaugeApp.swift    @main entry point; MenuBarExtra scene, starts StatsEngine
  StatsEngine.swift    @MainActor ObservableObject; 2 s Timer drives sampling on a
                       background DispatchQueue, publishes Snapshot to the main thread
  Samplers.swift       All metric samplers (see "Data sources" below) plus
                       AppInfoResolver (process name/icon resolution)
  StatusView.swift     SwiftUI views: StatusView (menu-bar popover) and
                       CompactStatusView (pinned strip), shared StatGauge/ProcessIcon
  PinnedPanel.swift    PinnedPanelController — borderless floating NSPanel hosting
                       CompactStatusView
  Info.plist           App metadata; LSUIElement, icon file name
  Resources/           MacGauge.icns
  Bridging/
    MacGauge-Bridging-Header.h   Imports SensorReader.h into Swift
    SensorReader.c / .h          Temperature reading via private HID APIs + AppleSMC
Shared/
  Models.swift         Snapshot, ProcessSample, DiskProcessSample, NetworkProcessSample structs;
                       IconStore (icon cache paths) and Format (display formatting)
docs/                  README screenshots and icon
project.yml            XcodeGen spec — the source of truth for the Xcode project
install.sh             Build Release and install to /Applications
```

Note: `MacGauge.xcodeproj/` is generated and gitignored — never edit it
directly. All project/target settings belong in `project.yml`.

## Build and run

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate                # regenerate MacGauge.xcodeproj after editing project.yml
xcodebuild -project MacGauge.xcodeproj -scheme MacGauge -configuration Release build
./install.sh                     # quits the app, builds Release, installs to /Applications, relaunches
```

For local use, adjust `DEVELOPMENT_TEAM` / `CODE_SIGN_IDENTITY` in
`project.yml` to match your own certificate (any Apple Development
certificate works).

There is no package manager manifest, no external dependencies, and no test
target. Validation is building successfully and running the app.

## Runtime architecture

- `StatsEngine` owns one `Timer` (2 s interval on the main run loop). Each
  tick hops to a serial utility `DispatchQueue` (`com.even.MacGauge.sampling`),
  calls every sampler to build a `Snapshot`, then publishes it on the main
  thread via `@Published`. Samplers are only touched on that queue.
- Most samplers are delta-based: they keep previous counter values and
  compute rates/percentages between ticks. The first `tick()` primes the
  counters, so the second tick is the first with real data.
- UI observes `StatsEngine` via `@EnvironmentObject`. The popover
  (`StatusView`) and pinned panel (`CompactStatusView` inside an
  `NSHostingView` in a floating `NSPanel`) render the same `Snapshot`.
- `StatsEngine.isPanelPinned` shows/hides `PinnedPanelController.shared`.
- Launch at login uses `SMAppService.mainApp` (ServiceManagement).
- App icons for process lists are exported as 40×40 PNGs to
  `~/Library/Application Support/MacGauge/icons` (see `IconStore` in
  `Shared/Models.swift`) and loaded from disk by the views.

## Data sources (keep in sync with the README table)

| Metric | Source |
|---|---|
| CPU load | `host_processor_info` tick deltas (`CPUSampler`) |
| GPU load | IORegistry `IOAccelerator` → `PerformanceStatistics` (`GPUSampler`) |
| Memory | `host_statistics64` (app + wired + compressed, Activity Monitor style) |
| Disk space | `URL.resourceValues` on `/` |
| Disk I/O | IORegistry `IOBlockStorageDriver` byte counters |
| Network total | `getifaddrs` interface byte counters (en/bridge/pdp only; 32-bit wrap handled) |
| Network per process | `/usr/bin/nettop -P -x -L 1` CSV counter deltas |
| Temperatures | `SensorReader.c`: private `IOHIDEventSystemClient` sensors, AppleSMC key enumeration fallback |
| Top CPU processes | `proc_listallpids` + `proc_pid_rusage` CPU-time deltas |
| Top disk R/W processes | `proc_pid_rusage` disk I/O byte deltas (`DiskUsageSampler`) |

## Code style conventions

- Swift, 4-space indentation, `// MARK: -` sections grouping related types
  (heavily used in `Samplers.swift` and `StatusView.swift`).
- One-purpose final classes for samplers; plain structs for data
  (`Shared/Models.swift` holds all shared model/formatting types).
- C code (`SensorReader.c`) follows CoreFoundation naming/ownership rules;
  the header exposes a single C entry point (`mg_read_temps`) consumed via
  the bridging header.
- Comments explain the *why* (data source quirks, counter wrap behavior,
  private API rationale), not the *what*.
- Clamp/guard defensively: counters may wrap, regress, or be unavailable —
  samplers return 0 / nil rather than crashing.

## Security considerations

- Temperature reading uses **private APIs** (`IOHIDEventSystemClient`) — the
  same approach as Stats / iStat Menus / asitop. The app is therefore **not
  App Store distributable**; do not add App Store entitlements or sandboxing
  that would break these calls.
- The app is signed but not notarized; README documents the
  `xattr -d com.apple.quarantine` workaround for users.
- The app shells out to `/usr/bin/nettop` for per-process network stats —
  keep the absolute path and fixed argument list.
- `CODE_SIGN_INJECT_BASE_ENTITLEMENTS` is `NO`; there is no entitlements
  file and no sandbox.

## Known limitations

- Intel Macs are untested (temperatures fall back to SMC `sp78` keys).
- Per-process GPU usage would require root (`powermetrics`); process
  rankings cover CPU, disk, and network only.
