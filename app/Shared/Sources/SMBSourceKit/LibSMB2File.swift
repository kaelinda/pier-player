import Foundation
import SMB2

public actor LibSMB2File: SMBClientFile {
    private let size: Int64
    private let handle: any SMBNativeFileHandle
    private let connection: any SMBNativeConnection
    private var isClosed = false

    init(
        size: Int64,
        handle: any SMBNativeFileHandle,
        connection: any SMBNativeConnection
    ) {
        self.size = size
        self.handle = handle
        self.connection = connection
    }

    public func read(at offset: Int64, length: Int) async throws -> Data {
        guard offset >= 0, length > 0, UInt64(length) <= UInt64(UInt32.max) else {
            throw SMBClientError.invalidRead(offset: offset, length: length)
        }
        guard !isClosed else {
            throw SMBClientError.notConnected
        }
        guard offset < size else {
            return Data()
        }

        let available = size - offset
        let readLength = min(length, Int(available))
        return try await handle.read(at: offset, length: readLength)
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        await handle.close()
        await connection.disconnect()
    }
}

final class SystemLibSMB2FileHandle: SMBNativeFileHandle, @unchecked Sendable {
    private let connection: SystemLibSMB2Connection
    private let state: State

    init(connection: SystemLibSMB2Connection, handle: OpaquePointer) {
        self.connection = connection
        state = State(handle: handle)
    }

    func read(at offset: Int64, length: Int) async throws -> Data {
        try await connection.perform { context in
            guard let handle = self.state.handle else {
                throw SMBClientError.notConnected
            }

            var data = Data(repeating: 0, count: length)
            let count = data.withUnsafeMutableBytes { buffer -> Int32 in
                guard let baseAddress = buffer.baseAddress else { return 0 }
                return smb2_pread(
                    context,
                    handle,
                    baseAddress.assumingMemoryBound(to: UInt8.self),
                    UInt32(length),
                    UInt64(offset)
                )
            }
            guard count >= 0 else {
                throw mapLibSMB2Status(count, operation: .read)
            }
            data.count = Int(count)
            return data
        }
    }

    func close() async {
        try? await connection.perform { context in
            guard let handle = self.state.takeHandle() else { return }
            _ = smb2_close(context, handle)
        }
    }

    private final class State: @unchecked Sendable {
        var handle: OpaquePointer?

        init(handle: OpaquePointer) {
            self.handle = handle
        }

        func takeHandle() -> OpaquePointer? {
            defer { handle = nil }
            return handle
        }
    }
}
