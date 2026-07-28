import AppKit
import Testing
@testable import PierPlayerApp

@MainActor
@Test func applicationUsesRegularActivationPolicy() {
    ApplicationActivation.activate()

    #expect(NSApplication.shared.activationPolicy() == .regular)
}

@MainActor
@Test func applicationActivatesAfterFinishingLaunch() {
    var activationCount = 0
    let delegate = AppDelegate {
        activationCount += 1
    }

    delegate.applicationDidFinishLaunching(
        Notification(name: NSApplication.didFinishLaunchingNotification)
    )

    #expect(activationCount == 1)
}
