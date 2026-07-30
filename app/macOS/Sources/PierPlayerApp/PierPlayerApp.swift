import AppKit
import DiagnosticsKit
import PlaybackCore
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
    var prepareForTermination: (@MainActor @Sendable () async -> Void)?
    private var isPreparingForTermination = false

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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let prepareForTermination else { return .terminateNow }
        guard !isPreparingForTermination else { return .terminateLater }
        isPreparingForTermination = true
        Task { @MainActor in
            await prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@MainActor
final class DiagnosticsRuntime {
    let center: DiagnosticCenter
    let context: DiagnosticContext
    let identityProvider: HMACDiagnosticIdentityProvider
    let directory: URL

    private let environment: DiagnosticRunEnvironment
    private let environmentMonitor: DiagnosticEnvironmentMonitor
    private var isStarted = false

    init(fileManager: FileManager = .default) {
        let runID = UUID()
        directory = Self.diagnosticsDirectory(fileManager: fileManager)
        environment = DiagnosticEnvironmentBuilder.make()
        context = DiagnosticContext(
            appRunID: runID,
            activityID: runID,
            operationID: UUID()
        )
        identityProvider = HMACDiagnosticIdentityProvider(
            keyStore: KeychainDiagnosticIdentityKeyStore()
        )
        let center = DiagnosticCenter(
            runID: runID,
            environment: environment,
            store: FileDiagnosticStore(rootDirectory: directory)
        )
        self.center = center
        environmentMonitor = DiagnosticEnvironmentMonitor(
            recorder: center.emitter,
            context: context
        )
    }

    func start() async {
        guard !isStarted else { return }
        isStarted = true
        await center.start()
        center.emitter.record(.instant(
            level: .info,
            name: .appLaunch,
            context: context.child(),
            outcome: .success,
            persistence: .essential
        ))
        center.emitter.record(.instant(
            level: .info,
            name: .environmentSnapshot,
            context: context.child(),
            outcome: .success,
            payload: DiagnosticPayload(
                memoryPressure: environment.memoryPressure,
                thermalState: environment.thermalState,
                powerState: environment.powerState,
                networkAvailability: environment.networkAvailability,
                networkInterface: environment.networkInterface
            ),
            persistence: .essential
        ))
        environmentMonitor.start()
    }

    func flush() async {
        await center.flush()
    }

    func stop() async {
        guard isStarted else { return }
        isStarted = false
        environmentMonitor.stop()
        center.emitter.record(.instant(
            level: .info,
            name: .appTermination,
            context: context.child(),
            outcome: .success,
            persistence: .essential
        ))
        await center.stop()
    }

    private static func diagnosticsDirectory(fileManager: FileManager) -> URL {
        let applicationSupport = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("Pier Player", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
    }
}

@main
@MainActor
struct PierPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var appModel: AppModel
    @StateObject private var diagnosticsViewModel: DiagnosticsViewModel
    private let diagnosticsRuntime: DiagnosticsRuntime

    init() {
        let runtime = DiagnosticsRuntime()
        diagnosticsRuntime = runtime
        let playbackContext = DiagnosticContext(
            appRunID: runtime.context.appRunID,
            activityID: UUID(),
            operationID: UUID(),
            parentOperationID: runtime.context.operationID
        )
        _appModel = StateObject(wrappedValue: AppModel(
            playbackSession: PlaybackSession(
                diagnosticRecorder: runtime.center.emitter,
                diagnosticContext: playbackContext
            ),
            diagnosticRecorder: runtime.center.emitter,
            diagnosticContext: runtime.context,
            identityProvider: runtime.identityProvider
        ))
        _diagnosticsViewModel = StateObject(wrappedValue: DiagnosticsViewModel(
            client: LiveDiagnosticsCenterClient(center: runtime.center)
        ))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appModel)
                .tint(.teal)
                .preferredColorScheme(.dark)
                .frame(minWidth: 820, minHeight: 560)
                .task {
                    appDelegate.prepareForTermination = { [diagnosticsRuntime] in
                        await diagnosticsRuntime.stop()
                    }
                    await diagnosticsRuntime.start()
                    await appModel.restore()
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase != .active else { return }
                    Task { await diagnosticsRuntime.flush() }
                }
        }
        .defaultSize(width: 1120, height: 720)

        Settings {
            DiagnosticsSettingsView(
                viewModel: diagnosticsViewModel,
                diagnosticsDirectory: diagnosticsRuntime.directory
            )
            .tint(.teal)
            .preferredColorScheme(.dark)
        }
    }
}
