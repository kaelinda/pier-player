import Foundation
import Testing
@testable import SubtitleKit

@Test func srtHandlesBOMLineEndingsStylesOverlapAndBoundedWarnings() throws {
    let source = "\u{feff}1\r\n00:00:00,250 --> 00:00:01,250\r\n<i>First</i>\r\n\r\n" +
        "2\r\n00:00:01,000 --> 00:00:02,000\r\nSecond\r\n\r\n" +
        "broken\r\nnot a timestamp\r\nIgnored\r\n\r\n" +
        "also broken\r\n"

    let result = try SubtitleParser.parse(
        Data(source.utf8),
        format: .subRip,
        warningLimit: 1
    )

    #expect(result.cues.count == 2)
    #expect(result.cues[0].text == "First")
    #expect(result.cues[0].startTime == 0.25)
    #expect(result.cues[1].startTime == 1)
    #expect(result.warnings.count == 1)

    var timeline = SubtitleTimeline()
    timeline.select(result.cues)
    #expect(timeline.activeCues(at: 1.1).map(\.text) == ["First", "Second"])
    timeline.seek(to: 2.5)
    #expect(timeline.activeCues(at: 2.5).isEmpty)
    timeline.select(nil)
    #expect(!timeline.isEnabled)
}

@Test func webVTTParsesCueIdentifiersAndSettings() throws {
    let source = """
    WEBVTT

    intro
    00:00.500 --> 00:01.250 align:start position:10%
    <b>Hello</b>

    00:01.500 --> 00:02.000
    World
    """

    let result = try SubtitleParser.parse(Data(source.utf8), format: .webVTT)
    #expect(result.cues.map(\.text) == ["Hello", "World"])
    #expect(result.cues.map(\.startTime) == [0.5, 1.5])
}

@Test func assUsesDeclaredColumnsAndPreservesTextCommas() throws {
    let source = """
    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    Dialogue: 0,0:00:00.25,0:00:01.00,Default,,0,0,0,,{\\an8}Hello, world\\NSecond line
    """

    let result = try SubtitleParser.parse(Data(source.utf8), format: .ass)
    let cue = try #require(result.cues.first)
    #expect(cue.startTime == 0.25)
    #expect(cue.endTime == 1)
    #expect(cue.text == "Hello, world\nSecond line")
}
