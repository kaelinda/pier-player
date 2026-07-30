import Foundation

public enum SubtitleParser {
    public static func parse(
        _ data: Data,
        format: SubtitleFormat,
        warningLimit: Int = 20
    ) throws -> SubtitleParseResult {
        guard var source = String(data: data, encoding: .utf8) else {
            throw SubtitleParserError.invalidUTF8
        }
        if source.first == "\u{feff}" {
            source.removeFirst()
        }
        source = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let result: SubtitleParseResult
        switch format {
        case .subRip:
            result = parseTimedBlocks(source, isWebVTT: false, warningLimit: warningLimit)
        case .webVTT:
            result = parseTimedBlocks(source, isWebVTT: true, warningLimit: warningLimit)
        case .ass:
            result = parseASS(source, warningLimit: warningLimit)
        }
        return SubtitleParseResult(
            cues: result.cues.sorted {
                $0.startTime == $1.startTime
                    ? $0.endTime < $1.endTime
                    : $0.startTime < $1.startTime
            },
            warnings: result.warnings
        )
    }

    public static func normalizedText(_ text: String) -> String {
        let lineNormalized = text
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
        let patterns = ["\\{[^}]*\\}", "<[^>]+>"]
        let stripped = patterns.reduce(lineNormalized) { partial, pattern in
            guard let expression = try? NSRegularExpression(pattern: pattern) else {
                return partial
            }
            let range = NSRange(partial.startIndex..<partial.endIndex, in: partial)
            return expression.stringByReplacingMatches(
                in: partial,
                range: range,
                withTemplate: ""
            )
        }
        return stripped
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseTimedBlocks(
        _ source: String,
        isWebVTT: Bool,
        warningLimit: Int
    ) -> SubtitleParseResult {
        let lines = source.components(separatedBy: "\n")
        var cues: [SubtitleCue] = []
        var warnings: [SubtitleParseWarning] = []
        var block: [(line: Int, text: String)] = []

        func appendWarning(line: Int, message: String) {
            guard warnings.count < max(0, warningLimit) else { return }
            warnings.append(SubtitleParseWarning(line: line, message: message))
        }

        func consumeBlock() {
            defer { block.removeAll(keepingCapacity: true) }
            guard !block.isEmpty else { return }
            if isWebVTT,
               block[0].text.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("WEBVTT") {
                return
            }
            if isWebVTT,
               block[0].text.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("NOTE") {
                return
            }
            guard let timingIndex = block.firstIndex(where: { $0.text.contains("-->") }) else {
                appendWarning(line: block[0].line, message: "missing cue timing")
                return
            }
            let timingParts = block[timingIndex].text.components(separatedBy: "-->")
            guard timingParts.count == 2,
                  let start = parseTimestamp(timingParts[0]),
                  let endToken = timingParts[1].split(whereSeparator: { $0.isWhitespace }).first,
                  let end = parseTimestamp(String(endToken)),
                  end > start else {
                appendWarning(line: block[timingIndex].line, message: "invalid cue timing")
                return
            }
            let text = normalizedText(
                block.dropFirst(timingIndex + 1).map(\.text).joined(separator: "\n")
            )
            guard !text.isEmpty else {
                appendWarning(line: block[timingIndex].line, message: "empty cue")
                return
            }
            cues.append(SubtitleCue(startTime: start, endTime: end, text: text))
        }

        for (offset, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                consumeBlock()
            } else {
                block.append((line: offset + 1, text: line))
            }
        }
        consumeBlock()
        return SubtitleParseResult(cues: cues, warnings: warnings)
    }

    private static func parseASS(
        _ source: String,
        warningLimit: Int
    ) -> SubtitleParseResult {
        let lines = source.components(separatedBy: "\n")
        var eventSection = false
        var columns: [String] = []
        var cues: [SubtitleCue] = []
        var warnings: [SubtitleParseWarning] = []

        func appendWarning(line: Int, message: String) {
            guard warnings.count < max(0, warningLimit) else { return }
            warnings.append(SubtitleParseWarning(line: line, message: message))
        }

        for (offset, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                eventSection = line.caseInsensitiveCompare("[Events]") == .orderedSame
                continue
            }
            guard eventSection else { continue }
            if line.lowercased().hasPrefix("format:") {
                columns = line.dropFirst("format:".count)
                    .split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                continue
            }
            guard line.lowercased().hasPrefix("dialogue:") else { continue }
            guard !columns.isEmpty,
                  let startIndex = columns.firstIndex(of: "start"),
                  let endIndex = columns.firstIndex(of: "end"),
                  let textIndex = columns.firstIndex(of: "text") else {
                appendWarning(line: offset + 1, message: "missing ASS event format")
                continue
            }
            let payload = line.dropFirst("dialogue:".count)
            let values = payload.split(
                separator: ",",
                maxSplits: max(0, columns.count - 1),
                omittingEmptySubsequences: false
            ).map(String.init)
            guard values.count == columns.count,
                  let start = parseTimestamp(values[startIndex]),
                  let end = parseTimestamp(values[endIndex]),
                  end > start else {
                appendWarning(line: offset + 1, message: "invalid ASS dialogue")
                continue
            }
            let text = normalizedText(values[textIndex])
            guard !text.isEmpty else {
                appendWarning(line: offset + 1, message: "empty ASS dialogue")
                continue
            }
            cues.append(SubtitleCue(startTime: start, endTime: end, text: text))
        }
        return SubtitleParseResult(cues: cues, warnings: warnings)
    }

    private static func parseTimestamp(_ rawValue: String) -> TimeInterval? {
        let value = rawValue
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        let components = value.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 2 || components.count == 3,
              let seconds = Double(components.last ?? "") else {
            return nil
        }
        let minutesIndex = components.count - 2
        guard let minutes = Double(components[minutesIndex]) else { return nil }
        let hours: Double
        if components.count == 3 {
            guard let parsedHours = Double(components[0]) else { return nil }
            hours = parsedHours
        } else {
            hours = 0
        }
        let result = hours * 3600 + minutes * 60 + seconds
        return result.isFinite && result >= 0 ? result : nil
    }
}
