import PierFFmpeg

public enum FFmpegRuntime {
    public static func version() throws -> String {
        try string(named: "version", from: ppff_version())
    }

    public static func configuration() throws -> String {
        try string(named: "configuration", from: ppff_configuration())
    }

    public static func license() throws -> String {
        try string(named: "license", from: ppff_license())
    }

    private static func string(
        named name: String,
        from pointer: UnsafePointer<CChar>?
    ) throws -> String {
        guard let pointer else {
            throw FFmpegError.invalidRuntimeMetadata(name)
        }
        let value = String(cString: pointer)
        guard !value.isEmpty else {
            throw FFmpegError.invalidRuntimeMetadata(name)
        }
        return value
    }
}
