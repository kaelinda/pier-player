//
//  SMBMediaSource.swift
//  MediaVFS — SMB 协议适配器
//
//  依赖: AMSMB2 (libsmb2 的 Swift 封装, MIT 许可; libsmb2 本身为 LGPL, 动态链接合规)
//  SPM:  .package(url: "https://github.com/amosavian/AMSMB2.git", from: "3.0.0")
//
//  验收要点(上线前必测):
//  - SMB3 + 传输加密的服务器(群晖默认配置)能否连接 —— 有的 SMB 库只协商到 2.x
//  - 大文件(> 4GB) range 读取的正确性
//  - Wi-Fi 切换 / NAS 休眠唤醒后的重连
//

import Foundation
import AMSMB2

public actor SMBMediaSource: MediaSource {

    public nonisolated let id: UUID
    public nonisolated let displayName: String

    /// 形如 smb://192.168.1.10 或 smb://nas.local
    private let serverURL: URL
    /// 共享名,如 "media"
    private let shareName: String
    private let credential: MediaSourceCredential

    private var client: SMB2Manager?

    public init(id: UUID = UUID(),
                displayName: String,
                serverURL: URL,
                shareName: String,
                credential: MediaSourceCredential) {
        self.id = id
        self.displayName = displayName
        self.serverURL = serverURL
        self.shareName = shareName
        self.credential = credential
    }

    // MARK: - MediaSource

    public func connect() async throws {
        guard client == nil else { return }

        let urlCredential = URLCredential(
            user: credential.domain.map { "\($0)\\\(credential.username)" } ?? credential.username,
            password: credential.password,
            persistence: .forSession
        )
        guard let manager = SMB2Manager(url: serverURL, credential: urlCredential) else {
            throw MediaSourceError.unreachable(underlying: "无效的服务器地址: \(serverURL)")
        }

        do {
            try await manager.connectShare(name: shareName)
            client = manager
        } catch {
            // TODO: 区分 libsmb2 的认证错误码与网络错误码,分别映射
            throw MediaSourceError.unreachable(underlying: error.localizedDescription)
        }
    }

    public func disconnect() async {
        try? await client?.disconnectShare()
        client = nil
    }

    public func list(directory path: String) async throws -> [MediaSourceItem] {
        let client = try activeClient()
        let entries = try await client.contentsOfDirectory(atPath: path.isEmpty ? "/" : path)

        return entries.compactMap { attrs -> MediaSourceItem? in
            guard let name = attrs[.nameKey] as? String,
                  let itemPath = attrs[.pathKey] as? String else { return nil }
            // 过滤 SMB 隐藏项
            guard name != "." && name != ".." else { return nil }

            let isDirectory = (attrs[.fileResourceTypeKey] as? URLFileResourceType) == .directory
            return MediaSourceItem(
                name: name,
                path: itemPath,
                kind: isDirectory ? .directory : .file,
                size: (attrs[.fileSizeKey] as? NSNumber)?.int64Value,
                modifiedAt: attrs[.contentModificationDateKey] as? Date
            )
        }
        .sorted { lhs, rhs in
            // 目录优先,再按名称
            if lhs.kind != rhs.kind { return lhs.kind == .directory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    public func open(file path: String) async throws -> MediaFileHandle {
        let client = try activeClient()
        let attrs = try await client.attributesOfItem(atPath: path)
        guard let size = (attrs[.fileSizeKey] as? NSNumber)?.int64Value else {
            throw MediaSourceError.notFound(path: path)
        }
        return SMBFileHandle(client: client, path: path, fileSize: size)
    }

    // MARK: - Private

    private func activeClient() throws -> SMB2Manager {
        guard let client else { throw MediaSourceError.notConnected }
        return client
    }
}

// MARK: - SMB 文件句柄

/// 说明:AMSMB2 的 contents(atPath:range:) 每次调用内部完成 open/read/close。
/// 骨架阶段先用它跑通;性能优化阶段应改为持有 libsmb2 文件句柄 + 复用连接,
/// 并在句柄内做顺序预读(播放器读模式高度顺序化,预读收益极大)。
final class SMBFileHandle: MediaFileHandle, @unchecked Sendable {

    let fileSize: Int64

    private let client: SMB2Manager
    private let path: String
    /// 串行化并发读请求;后续可替换为多连接并行分片读
    private let readQueue = DispatchQueue(label: "media.vfs.smb.read")

    init(client: SMB2Manager, path: String, fileSize: Int64) {
        self.client = client
        self.path = path
        self.fileSize = fileSize
    }

    func read(offset: Int64, length: Int) async throws -> Data {
        guard offset < fileSize else { return Data() } // EOF
        let end = min(offset + Int64(length), fileSize)

        do {
            return try await client.contents(
                atPath: path,
                range: Int64(offset)..<end,
                progress: nil
            )
        } catch {
            throw MediaSourceError.readFailed(underlying: error.localizedDescription)
        }
    }

    func close() async {
        // contents(atPath:range:) 模式下无持久句柄需要释放。
        // 切换到持久 libsmb2 句柄后,在这里关闭文件与释放预读缓冲。
    }
}
