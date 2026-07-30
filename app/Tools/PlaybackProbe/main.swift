import CryptoKit
import Darwin
import FFmpegKit
import Foundation
import MediaSourceKit

@main
struct PlaybackProbeCommand {
    static func main() async {
        do {
            let arguments = try Arguments.parse(CommandLine.arguments)
            if arguments.showsHelp {
                printUsage()
                return
            }

            let file = try LocalMediaFile(url: arguments.fileURL)
            let inputID = opaqueInputID(
                url: arguments.fileURL,
                size: file.identity.size
            )
            let result = try await PlaybackCompatibilityProbe.run(
                file: file,
                inputID: inputID,
                options: PlaybackProbeOptions(
                    seekTime: arguments.seekTime,
                    videoFrameLimit: arguments.frameLimit
                )
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(result)
            guard let output = String(data: data, encoding: .utf8) else {
                throw ProbeCommandError.encodingFailed
            }
            print(output)
        } catch {
            fputs("PlaybackProbe: \(safeMessage(for: error))\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    private static func opaqueInputID(url: URL, size: Int64) -> String {
        let material = "pier-player-playback-probe-v1|\(url.standardizedFileURL.path)|\(size)"
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func safeMessage(for error: Error) -> String {
        switch error {
        case ProbeCommandError.missingPath:
            "missing media path"
        case ProbeCommandError.invalidSeek:
            "--seek requires a non-negative number of seconds"
        case ProbeCommandError.invalidFrames:
            "--frames requires a positive integer"
        case ProbeCommandError.unknownArgument:
            "unknown argument"
        case ProbeCommandError.notRegularFile:
            "input is not a readable regular file"
        case ProbeCommandError.encodingFailed:
            "could not encode the report"
        case PlaybackProbeError.invalidSeekTime:
            "seek time is invalid"
        case PlaybackProbeError.invalidFrameLimit:
            "frame limit is invalid"
        default:
            "playback probe failed"
        }
    }

    private static func printUsage() {
        print("""
        Usage: PlaybackProbe <path> [--seek <seconds>] [--frames <count>]

        Reads through the same cache and custom AVIO path used by playback and
        emits redacted JSON. The input path is never included in the report.
        """)
    }
}

private struct Arguments {
    let fileURL: URL
    let seekTime: TimeInterval?
    let frameLimit: Int?
    let showsHelp: Bool

    static func parse(_ rawArguments: [String]) throws -> Arguments {
        var values = Array(rawArguments.dropFirst())
        if values == ["--help"] || values == ["-h"] {
            return Arguments(
                fileURL: URL(fileURLWithPath: "/dev/null"),
                seekTime: nil,
                frameLimit: nil,
                showsHelp: true
            )
        }
        guard !values.isEmpty else { throw ProbeCommandError.missingPath }
        let fileURL = URL(fileURLWithPath: values.removeFirst()).standardizedFileURL
        var seekTime: TimeInterval?
        var frameLimit: Int?

        while !values.isEmpty {
            let option = values.removeFirst()
            switch option {
            case "--seek":
                guard !values.isEmpty,
                      let value = Double(values.removeFirst()),
                      value.isFinite,
                      value >= 0 else {
                    throw ProbeCommandError.invalidSeek
                }
                seekTime = value
            case "--frames":
                guard !values.isEmpty,
                      let value = Int(values.removeFirst()),
                      value > 0 else {
                    throw ProbeCommandError.invalidFrames
                }
                frameLimit = value
            default:
                throw ProbeCommandError.unknownArgument
            }
        }

        return Arguments(
            fileURL: fileURL,
            seekTime: seekTime,
            frameLimit: frameLimit,
            showsHelp: false
        )
    }
}

private actor LocalMediaFile: MediaReadableFile {
    nonisolated let identity: MediaFileIdentity
    private let handle: FileHandle
    private var isClosed = false

    init(url: URL) throws {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ])
        guard values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize >= 0 else {
            throw ProbeCommandError.notRegularFile
        }
        handle = try FileHandle(forReadingFrom: url)
        identity = MediaFileIdentity(
            sourceID: UUID(),
            path: "/redacted/local-media",
            size: Int64(fileSize),
            modifiedAt: values.contentModificationDate
        )
    }

    func read(at offset: Int64, length: Int) async throws -> Data {
        guard !isClosed,
              offset >= 0,
              length > 0,
              offset < identity.size else {
            return Data()
        }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: length) ?? Data()
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        try? handle.close()
    }
}

private enum ProbeCommandError: Error {
    case missingPath
    case invalidSeek
    case invalidFrames
    case unknownArgument
    case notRegularFile
    case encodingFailed
}
