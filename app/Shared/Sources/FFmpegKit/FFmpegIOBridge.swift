import Darwin
import Foundation
import PierFFmpeg

public protocol FFmpegByteSource: AnyObject, Sendable {
    var size: Int64 { get }
    func read(at offset: Int64, length: Int) throws -> Data
}

final class FFmpegIOBridge: @unchecked Sendable {
    private let source: any FFmpegByteSource
    private let lock = NSLock()
    private let deadline: TimeInterval
    private var position: Int64 = 0
    private var remainingBytes: Int64
    private var isCancelled = false

    init(source: any FFmpegByteSource, limits: FFmpegProbeLimits) {
        self.source = source
        self.remainingBytes = limits.maximumBytes
        self.deadline = ProcessInfo.processInfo.systemUptime + limits.maximumDuration
    }

    var callbacks: PPFFIOCallbacks {
        PPFFIOCallbacks(
            opaque: Unmanaged.passUnretained(self).toOpaque(),
            read: ppffSwiftRead,
            seek: ppffSwiftSeek,
            interrupt: ppffSwiftInterrupt
        )
    }

    func cancel() {
        lock.withLock {
            isCancelled = true
        }
    }

    fileprivate func read(into buffer: UnsafeMutablePointer<UInt8>, length: Int) -> Int32 {
        lock.lock()
        defer { lock.unlock() }

        guard !shouldInterruptLocked(), remainingBytes > 0 else {
            return Int32(PPFF_ERROR_IO)
        }
        guard position < source.size else { return Int32(PPFF_ERROR_EOF) }

        let available = source.size - position
        let readLength = Int(min(Int64(length), available, remainingBytes))
        guard readLength > 0 else { return Int32(PPFF_ERROR_EOF) }

        do {
            let data = try source.read(at: position, length: readLength)
            guard !data.isEmpty else { return Int32(PPFF_ERROR_EOF) }
            let copiedCount = min(data.count, readLength)
            data.withUnsafeBytes { bytes in
                if let baseAddress = bytes.baseAddress {
                    memcpy(buffer, baseAddress, copiedCount)
                }
            }
            position += Int64(copiedCount)
            remainingBytes -= Int64(copiedCount)
            return Int32(copiedCount)
        } catch {
            return Int32(PPFF_ERROR_IO)
        }
    }

    fileprivate func seek(offset: Int64, whence: Int32) -> Int64 {
        lock.withLock {
            if (whence & Int32(PPFF_AVSEEK_SIZE)) != 0 {
                return source.size
            }
            guard !shouldInterruptLocked() else { return Int64(PPFF_ERROR_IO) }

            let mode = whence & 0xFFFF
            let base: Int64
            switch mode {
            case SEEK_SET:
                base = 0
            case SEEK_CUR:
                base = position
            case SEEK_END:
                base = source.size
            default:
                return Int64(PPFF_ERROR_INVALID_ARGUMENT)
            }

            let (target, overflow) = base.addingReportingOverflow(offset)
            guard !overflow, target >= 0, target <= source.size else {
                return Int64(PPFF_ERROR_INVALID_ARGUMENT)
            }
            position = target
            return target
        }
    }

    fileprivate func interrupted() -> Int32 {
        lock.withLock {
            shouldInterruptLocked() ? 1 : 0
        }
    }

    private func shouldInterruptLocked() -> Bool {
        isCancelled || ProcessInfo.processInfo.systemUptime >= deadline
    }
}

private let ppffSwiftRead: PPFFReadCallback = { opaque, buffer, size in
    guard let opaque, let buffer, size > 0 else {
        return Int32(PPFF_ERROR_INVALID_ARGUMENT)
    }
    return Unmanaged<FFmpegIOBridge>
        .fromOpaque(opaque)
        .takeUnretainedValue()
        .read(into: buffer, length: Int(size))
}

private let ppffSwiftSeek: PPFFSeekCallback = { opaque, offset, whence in
    guard let opaque else { return Int64(PPFF_ERROR_INVALID_ARGUMENT) }
    return Unmanaged<FFmpegIOBridge>
        .fromOpaque(opaque)
        .takeUnretainedValue()
        .seek(offset: offset, whence: whence)
}

private let ppffSwiftInterrupt: PPFFInterruptCallback = { opaque in
    guard let opaque else { return 1 }
    return Unmanaged<FFmpegIOBridge>
        .fromOpaque(opaque)
        .takeUnretainedValue()
        .interrupted()
}

private final class DataByteSource: FFmpegByteSource, @unchecked Sendable {
    let size: Int64
    private let data: Data

    init(data: Data) {
        self.data = data
        self.size = Int64(data.count)
    }

    func read(at offset: Int64, length: Int) -> Data {
        guard offset >= 0, length > 0, offset < size else { return Data() }
        let lowerBound = Int(offset)
        let upperBound = min(lowerBound + length, data.count)
        return data.subdata(in: lowerBound..<upperBound)
    }
}

extension FFmpegIOBridge {
    static func dataSource(_ data: Data) -> any FFmpegByteSource {
        DataByteSource(data: data)
    }
}
