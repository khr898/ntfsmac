import AppKit
import SwiftUI
import os.log

private let preferencesLog = Logger(subsystem: "com.khr898.ntfsmac", category: "PreferencesOpener")

/// Opens the Preferences window (GUI-PLAN.md "Preferences window" — gear icon in every screen's
/// footer). Originally routed through SwiftUI's `Settings` scene via
/// `NSApp.sendAction(Selector(("showSettingsWindow:")), ...)` — a private, reverse-engineered
/// selector, not documented API. Empirically confirmed dead on this box (macOS 26.5): no
/// `activate()`/dispatch-timing combination ever made the Settings window appear. The
/// `@Environment(\.openSettings)` replacement Apple does document requires macOS 14 (this
/// project's floor is 13.0 — `Package.swift`), so isn't usable unconditionally either. Showing a
/// plain `NSWindow` directly sidesteps both: no private API, no version gate, no scene-action
/// routing to race.
@MainActor
public enum PreferencesOpener {
    private static var window: NSWindow?
    private static var makeContent: (() -> AnyView)?

    /// Called once from `NtfsmacApp.init` with the same environment objects the old `Settings`
    /// scene closure captured — `open()` itself takes no parameters so all 3 call sites
    /// (`PopoverContentView`, `FirstRunView`, `CLIMissingView`) stay a single no-arg tap target.
    public static func configure(content: @escaping () -> AnyView) {
        makeContent = content
    }

    public static func open() {
        NSApp.activate(ignoringOtherApps: true)
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard let makeContent else { return }

        // Diagnostic only (temporary — remove once the ~5s first-open lag reported live is
        // localized and fixed): times each step of the cold-start path. No call into
        // `HelperInstaller`/`HelperClient` happens on this path, so their 5s
        // `staleCheckTimeoutNanoseconds` is not reachable from here — ruled out by inspection, not
        // by this logging. Read via `log stream --predicate 'subsystem == "com.khr898.ntfsmac" AND
        // category == "PreferencesOpener"'` while reproducing.
        let openStart = Date()

        let beforeContent = Date()
        let content = makeContent()
        logElapsed("makeContent()", since: beforeContent)

        let beforeHosting = Date()
        let hosting = NSHostingController(rootView: content)
        logElapsed("NSHostingController.init", since: beforeHosting)

        let beforeWindow = Date()
        let newWindow = NSWindow(contentViewController: hosting)
        logElapsed("NSWindow.init", since: beforeWindow)

        newWindow.title = "ntfsmac Preferences"
        newWindow.styleMask = [.titled, .closable]
        // `LSUIElement` apps have no real main window for Preferences to be a child of. `.floating`
        // alone wasn't enough — reported still appearing behind the popover panel, confirmed live:
        // `MenuBarExtra(.window)`'s own panel renders at `.popUpMenu` level (101), well above
        // `.floating` (3). One level above that guarantees Preferences always draws in front of it.
        newWindow.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        newWindow.center()
        window = newWindow

        let beforeFront = Date()
        newWindow.makeKeyAndOrderFront(nil)
        logElapsed("makeKeyAndOrderFront", since: beforeFront)
        logElapsed("open() total (first call)", since: openStart)
    }

    private static func logElapsed(_ label: String, since start: Date) {
        let ms = Date().timeIntervalSince(start) * 1000
        preferencesLog.notice("\(label, privacy: .public): \(ms, privacy: .public)ms")
    }
}
