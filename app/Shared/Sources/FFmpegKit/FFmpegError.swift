import PierFFmpeg

public enum FFmpegError: Error, Equatable, Sendable {
    case invalidRuntimeMetadata(String)
    case invalidProbeLimits
    case corruptMedia
    case unsupportedCodec
    case native(code: Int, message: String)
    case cancelled
    case decodersNotPrepared
    case sessionClosed

    public var isInputOutputFailure: Bool {
        guard case let .native(code, _) = self else { return false }
        return code == Int(PPFF_ERROR_IO)
    }

    public var diagnosticCode: Int? {
        switch self {
        case .corruptMedia:
            Int(PPFF_ERROR_CORRUPT_MEDIA)
        case .unsupportedCodec:
            Int(PPFF_ERROR_DECODER_NOT_FOUND)
        case let .native(code, _):
            code
        default:
            nil
        }
    }
}
