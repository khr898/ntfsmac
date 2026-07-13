// swift-tools-version:6.0
import Foundation
import PackageDescription

// GUI + privileged-helper package (PLAN.md Phase 3). Targets are added to incrementally as
// later §6 units land — this file only declares what `3-xpc-helper` needs.

// `#filePath` gives this manifest's own absolute path regardless of the CWD `swift build` is
// invoked from (build/package-app.sh, CI, or Xcode) — resolving helper/Info.plist and
// helper/launchd.plist relative to that is the only path-independent way to feed them to the
// linker below.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let helperInfoPlistPath = packageDir.appendingPathComponent("helper/Info.plist").path
let helperLaunchdPlistPath = packageDir.appendingPathComponent("helper/launchd.plist").path

let package = Package(
    name: "ntfsmac-gui",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "HelperShared", targets: ["HelperShared"]),
        .executable(name: "ntfsmac-helper", targets: ["ntfsmac-helper"]),
        .library(name: "NtfsmacGUI", targets: ["NtfsmacGUI"]),
        .executable(name: "ntfsmac-gui", targets: ["ntfsmac-gui"]),
    ],
    targets: [
        .target(
            name: "HelperShared",
            path: "helper",
            exclude: ["main.swift", "Info.plist", "launchd.plist", "Tests"],
            sources: ["HelperProtocol.swift", "GeneratedCLIManifest.swift"]
        ),
        .executableTarget(
            name: "ntfsmac-helper",
            dependencies: ["HelperShared"],
            path: "helper",
            exclude: ["HelperProtocol.swift", "GeneratedCLIManifest.swift", "Info.plist", "launchd.plist", "Tests"],
            sources: ["main.swift"],
            // SMJobBless reads a raw (non-.app-bundled) helper tool's identity straight out of
            // its Mach-O sections, not from a plist file sitting next to it on disk — these two
            // sectcreate flags are what make helper/Info.plist's SMAuthorizedClients and
            // helper/launchd.plist's Label/MachServices actually reachable once this binary is
            // copied into ntfsmac.app/Contents/Library/LaunchServices/ (build/package-app.sh).
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", helperInfoPlistPath,
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__launchd_plist",
                    "-Xlinker", helperLaunchdPlistPath,
                ])
            ]
        ),
        .testTarget(
            name: "HelperTests",
            dependencies: ["HelperShared"],
            path: "helper/Tests"
        ),
        .target(
            name: "NtfsmacGUI",
            dependencies: ["HelperShared"],
            path: "gui",
            exclude: ["App", "Resources", "Info.plist", "Tests"],
            sources: [
                "Helper/HelperClient.swift", "Status/StatusIcon.swift", "State/AppState.swift",
                "Drives/DriveScanner.swift", "Views/DriveRow.swift", "Actions/MountController.swift",
                "Drives/ThroughputMonitor.swift", "Views/SpeedBar.swift",
                "Actions/RemountController.swift", "Views/DirtyBanner.swift",
                "Actions/FinderOpener.swift", "Views/SecurityIndicators.swift",
                "Actions/PreferencesOpener.swift", "Actions/CLIAutoStager.swift",
                "Actions/DiagnoseRunner.swift", "Views/DiagnosePanel.swift",
                "FirstRun/HelperInstaller.swift", "Views/FirstRunView.swift",
                "FirstRun/HelperUninstaller.swift", "FirstRun/CLIInstallChecker.swift", "Views/CLIMissingView.swift",
                "Preferences/Settings.swift", "Preferences/PreferencesView.swift",
                "Style/Colors.swift", "Style/GlassTheme.swift", "Style/Icons.swift", "Style/PillButtons.swift",
                "Views/PopoverContentView.swift",
            ]
        ),
        .executableTarget(
            name: "ntfsmac-gui",
            dependencies: ["NtfsmacGUI"],
            path: "gui",
            exclude: [
                "Helper", "Status", "State", "Drives", "Views", "Actions", "FirstRun", "Preferences",
                "Style", "Resources", "Info.plist", "Tests",
            ],
            sources: ["App/NtfsmacApp.swift", "App/DemoScaffold.swift"]
        ),
        .testTarget(
            name: "NtfsmacGUITests",
            dependencies: ["NtfsmacGUI", "HelperShared"],
            path: "gui/Tests"
        ),
    ]
)
