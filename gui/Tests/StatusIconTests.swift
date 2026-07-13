import SwiftUI
import Testing
@testable import NtfsmacGUI

// GUI-PLAN.md "Menu-bar icon states": grey=idle, blue(pulsing)=mounting, green=rw,
// yellow=ro-dirty, red=error. Asserts all five, per this unit's acceptance clause.
// Colors are `3-liquid-glass`'s literal hex values (`Colors.swift`) — idle uses `.ntfsIdleGray`
// (secondary-label gray in light mode, pure white in dark mode — `.secondary` alone read too
// faint against a dark desktop background).

@Test func idleIsGrayAndNotPulsing() {
    let style = StatusIcon.style(for: .idle)
    #expect(style.color == .ntfsIdleGray)
    #expect(!style.isPulsing)
}

@Test func mountingIsBlueAndPulsing() {
    let style = StatusIcon.style(for: .mounting)
    #expect(style.color == .ntfsBlue)
    #expect(style.isPulsing)
}

@Test func mountedReadWriteIsGreenAndNotPulsing() {
    let style = StatusIcon.style(for: .mountedReadWrite)
    #expect(style.color == .ntfsGreen)
    #expect(!style.isPulsing)
}

@Test func mountedReadOnlyByRequestIsGreenAndNotPulsing() {
    let style = StatusIcon.style(for: .mountedReadOnly)
    #expect(style.color == .ntfsGreen)
    #expect(!style.isPulsing)
}

@Test func mountedReadOnlyDirtyIsYellowAndNotPulsing() {
    let style = StatusIcon.style(for: .mountedReadOnlyDirty)
    #expect(style.color == .ntfsYellow)
    #expect(!style.isPulsing)
}

@Test func errorIsRedAndNotPulsing() {
    let style = StatusIcon.style(for: .error)
    #expect(style.color == .ntfsRed)
    #expect(!style.isPulsing)
}
