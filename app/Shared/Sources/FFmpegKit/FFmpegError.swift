public enum FFmpegError: Error, Equatable, Sendable {
    case invalidRuntimeMetadata(String)
    case invalidProbeLimits
    case native(code: Int, message: String)
    case cancelled
    case decodersNotPrepared
    case sessionClosed
}
