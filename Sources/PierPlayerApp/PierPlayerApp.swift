import AppKit
import SwiftUI

@MainActor
enum ApplicationActivation {
    static func activate() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let activateApplication: @MainActor () -> Void

    override convenience init() {
        self.init(activateApplication: ApplicationActivation.activate)
    }

    init(activateApplication: @escaping @MainActor () -> Void) {
        self.activateApplication = activateApplication
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        activateApplication()
    }
}

@main
struct PierPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .defaultSize(width: 1040, height: 680)
    }
}
