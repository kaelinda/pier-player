import DiagnosticsKit
import Foundation
import Testing
@testable import PierPlayerApp

@Suite @MainActor struct DiagnosticEnvironmentMonitorTests {
    @Test func environmentBuilderMapsOnlyPrivacySafeSystemClasses() {
        let environment = DiagnosticEnvironmentBuilder.make(
            bundleValues: DiagnosticBundleValues(version: "1.2", build: "34"),
            systemValues: DiagnosticSystemValues(
                osVersion: "macOS 15.5",
                architecture: .arm64,
                hardwareClass: .mac,
                memoryPressure: .normal,
                thermalState: .fair,
                powerState: .lowPower
            ),
            networkState: DiagnosticNetworkState(
                availability: .available,
                interface: .wifi
            )
        )

        #expect(environment.appVersion == "1.2")
        #expect(environment.appBuild == "34")
        #expect(environment.osVersion == "macOS 15.5")
        #expect(environment.architecture == .arm64)
        #expect(environment.hardwareClass == .mac)
        #expect(environment.memoryPressure == .normal)
        #expect(environment.thermalState == .fair)
        #expect(environment.powerState == .lowPower)
        #expect(environment.networkAvailability == .available)
        #expect(environment.networkInterface == .wifi)
    }

    @Test func monitorRecordsExactClosedEnvironmentEventsWithoutRawNetworkData() async throws {
        let recorder = AppRecordingDiagnosticRecorder()
        let source = FakeDiagnosticEnvironmentEventSource()
        let monitor = DiagnosticEnvironmentMonitor(
            recorder: recorder,
            context: appDiagnosticContext,
            eventSource: source
        )

        monitor.start()
        source.send(.sleep)
        source.send(.wake)
        source.send(.networkChanged(DiagnosticNetworkState(
            availability: .available,
            interface: .ethernet
        )))
        source.send(.thermalChanged(.serious))
        source.send(.powerChanged(.lowPower))
        source.send(.memoryPressureChanged(.critical))

        try await waitForEnvironmentEvents(recorder, count: 6)
        monitor.stop()

        let events = Array(recorder.snapshot.suffix(6))
        #expect(events.map(\.name) == [
            .appSleep,
            .appWake,
            .networkChanged,
            .environmentSnapshot,
            .environmentSnapshot,
            .environmentSnapshot,
        ])
        #expect(events[2].payload.networkAvailability == .available)
        #expect(events[2].payload.networkInterface == .ethernet)
        #expect(events[3].payload.thermalState == .serious)
        #expect(events[4].payload.powerState == .lowPower)
        #expect(events[5].payload.memoryPressure == .critical)

        let encoded = try events.map(DiagnosticEventEncoder.encode)
            .map { String(decoding: $0, as: UTF8.self) }
            .joined()
            .lowercased()
        for forbidden in ["ssid", "ipaddress", "dns", "interfaceaddress", "192.168."] {
            #expect(!encoded.contains(forbidden))
        }
    }
}

private final class FakeDiagnosticEnvironmentEventSource:
    DiagnosticEnvironmentEventSource,
    @unchecked Sendable
{
    let events: AsyncStream<DiagnosticEnvironmentEvent>
    private let continuation: AsyncStream<DiagnosticEnvironmentEvent>.Continuation

    init() {
        var captured: AsyncStream<DiagnosticEnvironmentEvent>.Continuation?
        events = AsyncStream(bufferingPolicy: .unbounded) { captured = $0 }
        continuation = captured!
    }

    func start() {}
    func stop() { continuation.finish() }

    func send(_ event: DiagnosticEnvironmentEvent) {
        continuation.yield(event)
    }
}

@MainActor
private func waitForEnvironmentEvents(
    _ recorder: AppRecordingDiagnosticRecorder,
    count: Int
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    while recorder.snapshot.count < count {
        guard clock.now < deadline else {
            Issue.record("Timed out waiting for environment events")
            return
        }
        await Task.yield()
    }
}
