import DiagnosticsKit
import Foundation

let appDiagnosticContext = DiagnosticContext(
    appRunID: UUID(uuidString: "00000000-0000-0000-0000-000000000421")!,
    activityID: UUID(uuidString: "00000000-0000-0000-0000-000000000422")!,
    operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000423")!
)

final class AppRecordingDiagnosticRecorder: DiagnosticRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [DiagnosticEvent] = []

    var snapshot: [DiagnosticEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func record(_ event: DiagnosticEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }
}
