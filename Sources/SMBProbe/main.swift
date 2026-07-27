import Darwin
import Foundation
import MediaSourceKit
import SMBSourceKit
import StreamIOKit

@main
struct SMBProbe {
    private static let pageSize = 1 * 1_024 * 1_024
    private static let cacheCapacity = 32 * 1_024 * 1_024
    private static let defaultProbeBytes: Int64 = 256 * 1_024 * 1_024

    static func main() async {
        if CommandLine.arguments.dropFirst().contains("--help") {
            printUsage()
            return
        }

        do {
            try await run()
        } catch {
            fputs("SMBProbe: \(safeMessage(for: error))\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    private static func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        let host = try required("PIER_SMB_HOST", in: environment)
        let share = try required("PIER_SMB_SHARE", in: environment)
        let username = try required("PIER_SMB_USER", in: environment)
        let domain = environment["PIER_SMB_DOMAIN"]
        let requiresEncryption = try parseBoolean(
            environment["PIER_SMB_ENCRYPTION"] ?? "false"
        )
        let filePath = environment["PIER_SMB_FILE"]
        let probeBytes = try parseProbeBytes(environment["PIER_SMB_PROBE_BYTES"])
        let password = try readPassword()

        let configuration = try SMBConnectionConfiguration(
            displayName: "SMB Probe",
            host: host,
            share: share,
            domain: domain,
            requiresEncryption: requiresEncryption
        )
        let credential = try SMBCredential(username: username, password: password)
        let client = LibSMB2Client(configuration: configuration, credential: credential)
        let source = SMBMediaSource(configuration: configuration, client: client)

        do {
            try await source.connect()
            let entries = try await source.list(directory: "/")
            print("root_entries=\(entries.count)")

            if let filePath, !filePath.isEmpty {
                try await probe(
                    filePath: filePath,
                    byteLimit: probeBytes,
                    source: source
                )
            }
            await source.disconnect()
        } catch {
            await source.disconnect()
            throw error
        }
    }

    private static func probe(
        filePath: String,
        byteLimit: Int64,
        source: SMBMediaSource
    ) async throws {
        let file = try await source.open(file: filePath)
        let reader = try CachedMediaReader(
            file: file,
            pageSize: pageSize,
            capacityBytes: cacheCapacity
        )
        let targetBytes = min(file.identity.size, byteLimit)
        let start = ContinuousClock.now
        var offset: Int64 = 0

        do {
            while offset < targetBytes {
                let length = Int(min(Int64(pageSize), targetBytes - offset))
                let data = try await reader.read(at: offset, length: length)
                guard !data.isEmpty else { break }
                offset += Int64(data.count)
            }
            let elapsed = start.duration(to: .now)
            let seconds = durationSeconds(elapsed)
            let throughput = seconds > 0
                ? Double(offset) / 1_048_576 / seconds
                : 0
            let metrics = await reader.metrics

            print("bytes=\(offset)")
            print(String(format: "elapsed_seconds=%.3f", seconds))
            print(String(format: "throughput_mib_s=%.2f", throughput))
            print("cache_hits=\(metrics.cacheHits)")
            print("cache_misses=\(metrics.cacheMisses)")
            print("upstream_reads=\(metrics.upstreamReads)")
            print("upstream_bytes=\(metrics.upstreamBytes)")
            await reader.close()
        } catch {
            await reader.close()
            throw error
        }
    }

    private static func required(
        _ key: String,
        in environment: [String: String]
    ) throws -> String {
        guard let value = environment[key], !value.isEmpty else {
            throw ProbeError.missingEnvironment(key)
        }
        return value
    }

    private static func parseBoolean(_ value: String) throws -> Bool {
        switch value.lowercased() {
        case "1", "true", "yes": true
        case "0", "false", "no": false
        default: throw ProbeError.invalidEncryption
        }
    }

    private static func parseProbeBytes(_ value: String?) throws -> Int64 {
        guard let value else { return defaultProbeBytes }
        guard let bytes = Int64(value), bytes > 0 else {
            throw ProbeError.invalidByteLimit
        }
        return bytes
    }

    private static func readPassword() throws -> String {
        var buffer = [CChar](repeating: 0, count: 1_024)
        guard readpassphrase(
            "SMB password: ",
            &buffer,
            buffer.count,
            RPP_ECHO_OFF
        ) != nil else {
            throw ProbeError.passwordReadFailed
        }
        return buffer.withUnsafeBufferPointer { pointer in
            let bytes = UnsafeRawPointer(pointer.baseAddress!)
                .assumingMemoryBound(to: UInt8.self)
            return String(decodingCString: bytes, as: UTF8.self)
        }
    }

    private static func durationSeconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private static func safeMessage(for error: Error) -> String {
        switch error {
        case let ProbeError.missingEnvironment(key):
            "missing required environment variable \(key)"
        case ProbeError.invalidEncryption:
            "PIER_SMB_ENCRYPTION must be true or false"
        case ProbeError.invalidByteLimit:
            "PIER_SMB_PROBE_BYTES must be a positive integer"
        case ProbeError.passwordReadFailed:
            "could not read the password from the terminal"
        case SMBConfigurationError.invalidHost:
            "the SMB host is invalid"
        case SMBConfigurationError.invalidShare:
            "the SMB share is invalid"
        case MediaSourceError.authenticationFailed:
            "authentication failed"
        case MediaSourceError.unreachable:
            "the SMB server is unreachable"
        case MediaSourceError.notFound:
            "the requested SMB item was not found"
        default:
            "the SMB probe failed"
        }
    }

    private static func printUsage() {
        print("""
        Usage: swift run -c release SMBProbe

        Required environment:
          PIER_SMB_HOST          NAS host name or IP address
          PIER_SMB_SHARE         SMB share name
          PIER_SMB_USER          SMB username

        Optional environment:
          PIER_SMB_DOMAIN        Authentication domain
          PIER_SMB_ENCRYPTION    true to require SMB encryption (default: false)
          PIER_SMB_FILE          File path for sequential throughput measurement
          PIER_SMB_PROBE_BYTES   Maximum bytes to read (default: 268435456)

        The password is read interactively without echo.
        """)
    }
}

private enum ProbeError: Error {
    case missingEnvironment(String)
    case invalidEncryption
    case invalidByteLimit
    case passwordReadFailed
}
