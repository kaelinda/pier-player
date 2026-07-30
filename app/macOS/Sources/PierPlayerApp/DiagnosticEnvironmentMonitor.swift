import AppKit
import Darwin
import DiagnosticsKit
import Foundation
import Network

struct DiagnosticBundleValues: Equatable, Sendable {
    let version: String
    let build: String

    static func current(bundle: Bundle = .main) -> DiagnosticBundleValues {
        DiagnosticBundleValues(
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? "0",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
                ?? "0"
        )
    }
}

struct DiagnosticSystemValues: Equatable, Sendable {
    let osVersion: String
    let architecture: DiagnosticArchitecture
    let hardwareClass: DiagnosticHardwareClass
    let memoryPressure: DiagnosticMemoryPressure
    let thermalState: DiagnosticThermalState
    let powerState: DiagnosticPowerState

    static func current(processInfo: ProcessInfo = .processInfo) -> DiagnosticSystemValues {
        DiagnosticSystemValues(
            osVersion: processInfo.operatingSystemVersionString,
            architecture: currentArchitecture,
            hardwareClass: currentHardwareClass,
            memoryPressure: .normal,
            thermalState: DiagnosticThermalState(processInfo.thermalState),
            powerState: processInfo.isLowPowerModeEnabled ? .lowPower : .normal
        )
    }

    private static var currentArchitecture: DiagnosticArchitecture {
        #if arch(arm64)
        .arm64
        #elseif arch(x86_64)
        .x86_64
        #else
        .other
        #endif
    }

    private static var currentHardwareClass: DiagnosticHardwareClass {
        var byteCount: size_t = 0
        let result = sysctlbyname("hw.model", nil, &byteCount, nil, 0)
        return result == 0 && byteCount > 0 ? .mac : .other
    }
}

struct DiagnosticNetworkState: Equatable, Sendable {
    let availability: DiagnosticNetworkAvailability
    let interface: DiagnosticNetworkInterface

    static let unknown = DiagnosticNetworkState(
        availability: .unknown,
        interface: .none
    )

    init(
        availability: DiagnosticNetworkAvailability,
        interface: DiagnosticNetworkInterface
    ) {
        self.availability = availability
        self.interface = interface
    }

    init(path: NWPath) {
        availability = path.status == .satisfied ? .available : .unavailable
        if path.status != .satisfied {
            interface = .none
        } else if path.usesInterfaceType(.wiredEthernet) {
            interface = .ethernet
        } else if path.usesInterfaceType(.wifi) {
            interface = .wifi
        } else if path.usesInterfaceType(.cellular) {
            interface = .cellular
        } else {
            interface = .other
        }
    }
}

enum DiagnosticEnvironmentBuilder {
    static func make(
        bundleValues: DiagnosticBundleValues = .current(),
        systemValues: DiagnosticSystemValues = .current(),
        networkState: DiagnosticNetworkState = .unknown
    ) -> DiagnosticRunEnvironment {
        DiagnosticRunEnvironment(
            appVersion: bundleValues.version,
            appBuild: bundleValues.build,
            osVersion: systemValues.osVersion,
            architecture: systemValues.architecture,
            hardwareClass: systemValues.hardwareClass,
            memoryPressure: systemValues.memoryPressure,
            thermalState: systemValues.thermalState,
            powerState: systemValues.powerState,
            networkAvailability: networkState.availability,
            networkInterface: networkState.interface
        )
    }
}

enum DiagnosticEnvironmentEvent: Equatable, Sendable {
    case sleep
    case wake
    case networkChanged(DiagnosticNetworkState)
    case thermalChanged(DiagnosticThermalState)
    case powerChanged(DiagnosticPowerState)
    case memoryPressureChanged(DiagnosticMemoryPressure)
}

protocol DiagnosticEnvironmentEventSource: AnyObject, Sendable {
    var events: AsyncStream<DiagnosticEnvironmentEvent> { get }
    func start()
    func stop()
}

final class MacDiagnosticEnvironmentEventSource:
    DiagnosticEnvironmentEventSource,
    @unchecked Sendable
{
    let events: AsyncStream<DiagnosticEnvironmentEvent>

    private let continuation: AsyncStream<DiagnosticEnvironmentEvent>.Continuation
    private let networkMonitor = NWPathMonitor()
    private let networkQueue = DispatchQueue(label: "app.pier-player.diagnostics.network")
    private let lock = NSLock()
    private var isStarted = false
    private var workspaceObservers: [NSObjectProtocol] = []
    private var processObservers: [NSObjectProtocol] = []
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    init() {
        var captured: AsyncStream<DiagnosticEnvironmentEvent>.Continuation?
        events = AsyncStream(bufferingPolicy: .bufferingNewest(32)) { captured = $0 }
        guard let captured else {
            preconditionFailure("Failed to create environment event stream")
        }
        continuation = captured
    }

    func start() {
        lock.lock()
        guard !isStarted else {
            lock.unlock()
            return
        }
        isStarted = true
        lock.unlock()

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            workspaceCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: nil
            ) { [continuation] _ in
                continuation.yield(.sleep)
            },
            workspaceCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: nil
            ) { [continuation] _ in
                continuation.yield(.wake)
            },
        ]

        let processCenter = NotificationCenter.default
        processObservers = [
            processCenter.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification,
                object: nil,
                queue: nil
            ) { [continuation] _ in
                continuation.yield(.thermalChanged(
                    DiagnosticThermalState(ProcessInfo.processInfo.thermalState)
                ))
            },
            processCenter.addObserver(
                forName: Notification.Name.NSProcessInfoPowerStateDidChange,
                object: nil,
                queue: nil
            ) { [continuation] _ in
                continuation.yield(.powerChanged(
                    ProcessInfo.processInfo.isLowPowerModeEnabled ? .lowPower : .normal
                ))
            },
        ]

        networkMonitor.pathUpdateHandler = { [continuation] path in
            continuation.yield(.networkChanged(DiagnosticNetworkState(path: path)))
        }
        networkMonitor.start(queue: networkQueue)

        let memorySource = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: networkQueue
        )
        memorySource.setEventHandler { [continuation, weak memorySource] in
            guard let data = memorySource?.data else { return }
            let pressure: DiagnosticMemoryPressure
            if data.contains(.critical) {
                pressure = .critical
            } else if data.contains(.warning) {
                pressure = .warning
            } else {
                pressure = .normal
            }
            continuation.yield(.memoryPressureChanged(pressure))
        }
        memoryPressureSource = memorySource
        memorySource.resume()
    }

    func stop() {
        lock.lock()
        guard isStarted else {
            lock.unlock()
            return
        }
        isStarted = false
        lock.unlock()

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(workspaceCenter.removeObserver)
        workspaceObservers.removeAll()
        let processCenter = NotificationCenter.default
        processObservers.forEach(processCenter.removeObserver)
        processObservers.removeAll()
        networkMonitor.cancel()
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        continuation.finish()
    }
}

@MainActor
final class DiagnosticEnvironmentMonitor {
    private let recorder: any DiagnosticRecording
    private let context: DiagnosticContext
    private let eventSource: any DiagnosticEnvironmentEventSource
    private var observationTask: Task<Void, Never>?

    init(
        recorder: any DiagnosticRecording,
        context: DiagnosticContext,
        eventSource: any DiagnosticEnvironmentEventSource = MacDiagnosticEnvironmentEventSource()
    ) {
        self.recorder = recorder
        self.context = context
        self.eventSource = eventSource
    }

    func start() {
        guard observationTask == nil else { return }
        eventSource.start()
        let events = eventSource.events
        observationTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                self?.record(event)
            }
        }
    }

    func stop() {
        observationTask?.cancel()
        observationTask = nil
        eventSource.stop()
    }

    private func record(_ event: DiagnosticEnvironmentEvent) {
        let name: DiagnosticEventName
        let payload: DiagnosticPayload
        switch event {
        case .sleep:
            name = .appSleep
            payload = DiagnosticPayload()
        case .wake:
            name = .appWake
            payload = DiagnosticPayload()
        case let .networkChanged(state):
            name = .networkChanged
            payload = DiagnosticPayload(
                networkAvailability: state.availability,
                networkInterface: state.interface
            )
        case let .thermalChanged(state):
            name = .environmentSnapshot
            payload = DiagnosticPayload(thermalState: state)
        case let .powerChanged(state):
            name = .environmentSnapshot
            payload = DiagnosticPayload(powerState: state)
        case let .memoryPressureChanged(pressure):
            name = .environmentSnapshot
            payload = DiagnosticPayload(memoryPressure: pressure)
        }

        recorder.record(.instant(
            level: .info,
            name: name,
            context: context.child(),
            outcome: .success,
            payload: payload,
            persistence: .essential
        ))
    }
}

private extension DiagnosticThermalState {
    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal:
            self = .nominal
        case .fair:
            self = .fair
        case .serious:
            self = .serious
        case .critical:
            self = .critical
        @unknown default:
            self = .unknown
        }
    }
}
