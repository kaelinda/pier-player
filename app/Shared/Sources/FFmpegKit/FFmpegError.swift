import PierFFmpeg

public enum FFmpegError: Error, Equatable, Sendable {
    case invalidRuntimeMetadata(String)
    case invalidProbeLimits
    case native(code: Int, message: String)
    case cancelled
    case decodersNotPrepared
    case sessionClosed

    public var isInputOutputFailure: Bool {
        guard case let .native(code, _) = self else { return false }
        return code == Int(PPFF_ERROR_IO)
    }
}
