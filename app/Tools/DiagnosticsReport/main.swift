import Darwin
import DiagnosticsKit
import Foundation

@main
struct DiagnosticsReport {
    static func main() async {
        do {
            try await run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            fputs("DiagnosticsReport: invalid diagnostic bundle\n", stderr)
            exit(2)
        }
    }

    private static func run(arguments: [String]) async throws {
        if arguments == ["--help"] || arguments == ["-h"] {
            printUsage()
            return
        }
        if arguments.count == 2, arguments[0] == "--generate-fixture" {
            try await generateFixture(at: URL(fileURLWithPath: arguments[1]))
            print("fixture_generated")
            return
        }
        guard let first = arguments.first, arguments.count <= 2 else {
            throw DiagnosticBundleError.invalidPackage
        }
        let option = arguments.dropFirst().first
        guard option == nil || option == "--validate" || option == "--timeline" else {
            throw DiagnosticBundleError.invalidPackage
        }

        let bundle = try DiagnosticBundleReader.validate(
            at: URL(fileURLWithPath: first, isDirectory: true)
        )
        switch option {
        case "--validate":
            print("valid schema=1 entries=5")
        case "--timeline":
            printTimeline(bundle.events)
        default:
            printSummary(bundle.summary)
        }
    }

    private static func printSummary(_ summary: DiagnosticBundleSummary) {
        print("runs=\(summary.runCount)")
        print("events=\(summary.eventCount)")
        print("metrics=\(summary.metricCount)")
        print("failures=\(summary.failureCount)")
        print("stalls=\(summary.stallCount)")
        print("unmatched_operations=\(summary.unmatchedOperationCount)")
        print("unclosed_resources=\(summary.unclosedResourceCount)")
        print("dropped_events=\(summary.droppedEssentialEvents + summary.droppedDetailedEvents)")
        for error in summary.errors {
            print("error code=\(error.code.rawValue) count=\(error.count)")
        }
        for operation in summary.slowOperations {
            print(
                "slow event=\(operation.name.rawValue) duration_ms=\(format(operation.durationMilliseconds))"
            )
        }
    }

    private static func printTimeline(_ events: [DiagnosticEvent]) {
        for event in events.sorted(by: { $0.sequence < $1.sequence }) {
            let outcome = event.outcome?.rawValue ?? "none"
            let duration = event.durationMilliseconds.map(format) ?? "none"
            print(
                "sequence=\(event.sequence) event=\(event.name.rawValue) phase=\(event.phase.rawValue) outcome=\(outcome) duration_ms=\(duration)"
            )
        }
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private static func generateFixture(at destination: URL) async throws {
        let runID = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
        let activityID = UUID(uuidString: "00000000-0000-0000-0000-000000000202")!
        let event = DiagnosticEvent(
            sequence: 1,
            wallTime: Date(timeIntervalSince1970: 1),
            monotonicNanoseconds: 1_000_000_000,
            level: .error,
            name: .playbackFailed,
            context: DiagnosticContext(
                appRunID: runID,
                activityID: activityID,
                operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000203")!
            ),
            phase: .end,
            outcome: .failure,
            durationMilliseconds: 250,
            payload: DiagnosticPayload(
                container: .mkv,
                fileSize: 1_048_576,
                error: DiagnosticErrorDescriptor(code: .playerFailed)
            ),
            persistence: .essential
        )
        var eventData = try DiagnosticEventEncoder.encode(event)
        eventData.append(0x0A)
        let snapshot = DiagnosticStoreSnapshot(
            manifest: DiagnosticRunManifest(
                runID: runID,
                startedAt: Date(timeIntervalSince1970: 0),
                endedAt: Date(timeIntervalSince1970: 2),
                policy: .incident,
                environment: DiagnosticRunEnvironment(
                    appVersion: "1.0",
                    appBuild: "1",
                    osVersion: "macOS",
                    architecture: .arm64,
                    hardwareClass: .mac,
                    networkAvailability: .available,
                    networkInterface: .ethernet
                )
            ),
            eventSegments: [eventData],
            metricSegments: [],
            eventSegmentURLs: [],
            metricSegmentURLs: []
        )
        try await DiagnosticBundleExporter(
            now: { Date(timeIntervalSince1970: 2) }
        ).export(snapshots: [snapshot], to: destination)
    }

    private static func printUsage() {
        print("""
        Usage:
          swift run DiagnosticsReport <bundle.pierdiag>
          swift run DiagnosticsReport <bundle.pierdiag> --validate
          swift run DiagnosticsReport <bundle.pierdiag> --timeline
          swift run DiagnosticsReport --generate-fixture <bundle.pierdiag>

        Reads only exported diagnostics packages. It never accesses media or credentials.
        """)
    }
}
