import Foundation
import Testing
@testable import DiagnosticsKit

@Test func systemLogProjectionContainsOnlyTypedSchemaValues() {
    let id = UUID()
    let event = DiagnosticEvent(
        sequence: 1,
        wallTime: Date(timeIntervalSince1970: 0),
        monotonicNanoseconds: 1,
        level: .error,
        name: .smbRead,
        context: DiagnosticContext(
            appRunID: id,
            activityID: id,
            operationID: id
        ),
        phase: .end,
        outcome: .failure,
        durationMilliseconds: 12,
        payload: DiagnosticPayload(
            sourceID: id,
            fileID: String(repeating: "a", count: 64),
            offset: 10,
            requestedLength: 20,
            actualLength: 0,
            error: DiagnosticErrorDescriptor(code: .sourceReadFailed)
        ),
        persistence: .essential
    )

    let record = DiagnosticSystemLogRecord(event: event)

    #expect(record.name == .smbRead)
    #expect(record.operationID == id)
    #expect(record.outcome == .failure)
    #expect(record.durationMilliseconds == 12)
    #expect(record.fileID == String(repeating: "a", count: 64))
    #expect(record.errorCode == .sourceReadFailed)
}
