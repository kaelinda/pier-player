import Foundation
import OSLog

public struct DiagnosticSystemLogRecord: Equatable, Sendable {
    public let level: DiagnosticLevel
    public let name: DiagnosticEventName
    public let phase: DiagnosticPhase
    public let operationID: UUID
    public let outcome: DiagnosticOutcome?
    public let durationMilliseconds: Double?
    public let fileID: String?
    public let errorCode: DiagnosticErrorCode?

    public init(event: DiagnosticEvent) {
        self.level = event.level
        self.name = event.name
        self.phase = event.phase
        self.operationID = event.context.operationID
        self.outcome = event.outcome
        self.durationMilliseconds = event.durationMilliseconds
        self.fileID = event.payload.fileID
        self.errorCode = event.payload.error?.code
    }
}

public protocol DiagnosticSystemLogging: Sendable {
    func log(_ record: DiagnosticSystemLogRecord)
}

public struct NoopDiagnosticSystemLogger: DiagnosticSystemLogging {
    public init() {}

    public func log(_ record: DiagnosticSystemLogRecord) {}
}

public final class AppleDiagnosticSystemLogger: DiagnosticSystemLogging, @unchecked Sendable {
    private let logger: Logger
    private let signpostLog: OSLog
    private let lock = NSLock()
    private var intervals: [UUID: OSSignpostID] = [:]

    public init(subsystem: String = "app.pier-player", category: String = "diagnostics") {
        self.logger = Logger(subsystem: subsystem, category: category)
        self.signpostLog = OSLog(subsystem: subsystem, category: category)
    }

    public func log(_ record: DiagnosticSystemLogRecord) {
        let outcome = record.outcome?.rawValue ?? "none"
        let duration = record.durationMilliseconds ?? 0
        logger.log(
            level: record.level.osLogType,
            "event=\(record.name.rawValue, privacy: .public) outcome=\(outcome, privacy: .public) duration_ms=\(duration, privacy: .public)"
        )

        switch record.phase {
        case .begin:
            let identifier = OSSignpostID(log: signpostLog)
            lock.lock()
            intervals[record.operationID] = identifier
            lock.unlock()
            os_signpost(
                .begin,
                log: signpostLog,
                name: "DiagnosticOperation",
                signpostID: identifier,
                "event=%{public}s",
                record.name.rawValue
            )
        case .end:
            lock.lock()
            let identifier = intervals.removeValue(forKey: record.operationID)
            lock.unlock()
            if let identifier {
                os_signpost(
                    .end,
                    log: signpostLog,
                    name: "DiagnosticOperation",
                    signpostID: identifier,
                    "event=%{public}s outcome=%{public}s",
                    record.name.rawValue,
                    outcome
                )
            } else {
                os_signpost(
                    .event,
                    log: signpostLog,
                    name: "DiagnosticUnmatchedEnd",
                    "event=%{public}s",
                    record.name.rawValue
                )
            }
        case .instant:
            os_signpost(
                .event,
                log: signpostLog,
                name: "DiagnosticEvent",
                "event=%{public}s",
                record.name.rawValue
            )
        }
    }
}

private extension DiagnosticLevel {
    var osLogType: OSLogType {
        switch self {
        case .debug: .debug
        case .info: .info
        case .notice: .default
        case .warning: .error
        case .error, .critical: .fault
        }
    }
}
