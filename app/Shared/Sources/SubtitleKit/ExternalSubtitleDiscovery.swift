import Foundation
import MediaSourceKit

public struct ExternalSubtitleCandidate: Equatable, Sendable, Identifiable {
    public let item: MediaSourceItem
    public let format: SubtitleFormat
    public let language: String?

    public var id: String { item.path }

    public init(item: MediaSourceItem, format: SubtitleFormat, language: String?) {
        self.item = item
        self.format = format
        self.language = language
    }
}

public enum ExternalSubtitleError: Error, Equatable, Sendable {
    case fileTooLarge
    case invalidFileSize
}

public enum ExternalSubtitleDiscovery {
    public static let maximumFileSize: Int64 = 8 * 1024 * 1024

    public static func discover(
        videoPath: String,
        among items: [MediaSourceItem]
    ) -> [ExternalSubtitleCandidate] {
        let videoName = (videoPath as NSString).lastPathComponent
        let videoBase = (videoName as NSString).deletingPathExtension
        let lowercaseBase = videoBase.lowercased()

        return items.compactMap { item in
            guard item.kind == .file,
                  let format = format(forExtension: (item.name as NSString).pathExtension) else {
                return nil
            }
            let subtitleBase = (item.name as NSString).deletingPathExtension
            let lowercaseSubtitleBase = subtitleBase.lowercased()
            let language: String?
            if lowercaseSubtitleBase == lowercaseBase {
                language = nil
            } else {
                let prefix = lowercaseBase + "."
                guard lowercaseSubtitleBase.hasPrefix(prefix) else { return nil }
                language = String(subtitleBase.dropFirst(videoBase.count + 1))
            }
            return ExternalSubtitleCandidate(item: item, format: format, language: language)
        }.sorted {
            $0.item.name.localizedCaseInsensitiveCompare($1.item.name) == .orderedAscending
        }
    }

    public static func load(
        _ candidate: ExternalSubtitleCandidate,
        from source: any MediaSource,
        warningLimit: Int = 20
    ) async throws -> SubtitleParseResult {
        if let size = candidate.item.size, size > maximumFileSize {
            throw ExternalSubtitleError.fileTooLarge
        }

        let file = try await source.open(file: candidate.item.path)
        do {
            let size = file.identity.size
            guard size >= 0, size <= Int64(Int.max) else {
                throw ExternalSubtitleError.invalidFileSize
            }
            guard size <= maximumFileSize else {
                throw ExternalSubtitleError.fileTooLarge
            }
            let data = size == 0
                ? Data()
                : try await file.read(at: 0, length: Int(size))
            let result = try SubtitleParser.parse(
                data,
                format: candidate.format,
                warningLimit: warningLimit
            )
            await file.close()
            return result
        } catch {
            await file.close()
            throw error
        }
    }

    private static func format(forExtension fileExtension: String) -> SubtitleFormat? {
        switch fileExtension.lowercased() {
        case "srt": .subRip
        case "vtt": .webVTT
        case "ass", "ssa": .ass
        default: nil
        }
    }
}
