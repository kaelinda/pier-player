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
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appModel)
                .task {
                    await appModel.restore()
                }
        }
        .defaultSize(width: 1040, height: 680)
    }
}
