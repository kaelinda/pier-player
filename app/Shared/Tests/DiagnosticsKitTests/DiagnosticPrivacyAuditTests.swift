import Foundation
import Testing
@testable import DiagnosticsKit

@Test func privacyAuditAcceptsTypedEventAndManifest() throws {
    let id = UUID()
    let event = DiagnosticEvent(
        sequence: 1,
        wallTime: Date(timeIntervalSince1970: 0),
        monotonicNanoseconds: 1,
        level: .info,
        name: .fileOpen,
        context: DiagnosticContext(
            appRunID: id,
            activityID: id,
            operationID: id
        ),
        phase: .end,
        outcome: .success,
        payload: DiagnosticPayload(
            sourceID: id,
            fileID: String(repeating: "a", count: 64),
            container: .mp4,
            fileSize: 100
        ),
        persistence: .essential
    )
    let manifest = DiagnosticRunManifest(
        runID: id,
        startedAt: Date(timeIntervalSince1970: 0),
        policy: .standard,
        environment: DiagnosticRunEnvironment(
            appVersion: "1.0",
            appBuild: "1",
            osVersion: "macOS 14.0",
            architecture: .arm64,
            hardwareClass: .mac,
            networkAvailability: .available,
            networkInterface: .wifi
        )
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601

    try DiagnosticPrivacyAudit.validate(try DiagnosticEventEncoder.encode(event))
    try DiagnosticPrivacyAudit.validate(try encoder.encode(manifest))
}

@Test(arguments: [
    "{\"username\":\"person\"}",
    "{\"Password\":\"secret\"}",
    "{\"host\":\"nas.local\"}",
    "{\"share\":\"Media\"}",
    "{\"file_name\":\"customer.mp4\"}",
    "{\"display-name\":\"Living Room NAS\"}",
])
func privacyAuditRejectsForbiddenKeys(json: String) {
    #expect(throws: DiagnosticPrivacyViolation.self) {
        try DiagnosticPrivacyAudit.validate(Data(json.utf8))
    }
}

@Test(arguments: [
    "smb://nas.local/Media/movie.mp4",
    "/Users/person/Videos/movie.mp4",
    "~/Videos/movie.mp4",
    "https://user:secret@example.test/media",
    "https://example.test/media?password=secret",
])
func privacyAuditRejectsSensitiveStringValues(value: String) throws {
    let data = try JSONSerialization.data(withJSONObject: ["value": value])

    #expect(throws: DiagnosticPrivacyViolation.self) {
        try DiagnosticPrivacyAudit.validate(data)
    }
}

@Test func privacyAuditValidatesEveryJSONLRecord() {
    let lines = "{\"value\":1}\n{\"path\":\"/secret\"}\n"

    #expect(throws: DiagnosticPrivacyViolation.self) {
        try DiagnosticPrivacyAudit.validate(Data(lines.utf8))
    }
}
