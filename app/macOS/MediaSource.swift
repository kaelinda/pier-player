//
//  MediaSource.swift
//  MediaVFS — 统一数据源抽象层
//
//  设计原则:
//  1. 上层(媒体库扫描器、播放内核)只依赖本文件中的协议,永不感知具体协议(SMB/WebDAV/网盘)。
//  2. 只暴露两组能力:目录枚举(扫描用) + 字节范围随机读(播放用)。
//  3. 全部 async/await + Sendable,适配器内部用 actor 保证连接状态线程安全。
//

import Foundation

// MARK: - 数据源条目

public struct MediaSourceItem: Hashable, Sendable {
    public enum Kind: Sendable {
        case file
        case directory
    }

    /// 显示名(含扩展名)
    public let name: String
    /// 数据源内的相对路径,如 "Movies/Dune.Part.Two.2024.2160p.mkv"
    public let path: String
    public let kind: Kind
    /// 文件字节数;目录为 nil
    public let size: Int64?
    public let modifiedAt: Date?

    public init(name: String, path: String, kind: Kind, size: Int64? = nil, modifiedAt: Date? = nil) {
        self.name = name
        self.path = path
        self.kind = kind
        self.size = size
        self.modifiedAt = modifiedAt
    }

    /// 扫描器用:是否是候选视频文件
    public var isVideoFile: Bool {
        guard kind == .file else { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        return Self.videoExtensions.contains(ext)
    }

    public static let videoExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "mov", "avi", "ts", "m2ts", "mts",
        "wmv", "flv", "webm", "vob", "iso", "rmvb", "mpg", "mpeg", "strm",
    ]
}

// MARK: - 凭据

/// 注意:实际项目中密码只在使用时从 Keychain 取出,本结构不做任何持久化。
public struct MediaSourceCredential: Sendable {
    public var username: String
    public var password: String
    /// SMB 域(工作组),通常留空
    public var domain: String?

    public init(username: String, password: String, domain: String? = nil) {
        self.username = username
        self.password = password
        self.domain = domain
    }

    public static let guest = MediaSourceCredential(username: "guest", password: "")
}

// MARK: - 错误

public enum MediaSourceError: Error, Sendable {
    case notConnected
    case authenticationFailed
    case unreachable(underlying: String?)
    case notFound(path: String)
    case readFailed(underlying: String?)
    case unsupported(String)
}

// MARK: - 随机读句柄(播放内核的唯一依赖)

/// 按字节范围随机读取的文件句柄。
/// FFmpeg 的 AVIO read/seek 回调、AVAssetResourceLoader 最终都桥接到它。
/// 实现方需保证:并发调用 read 是安全的(内部串行化或使用独立连接)。
public protocol MediaFileHandle: AnyObject, Sendable {
    var fileSize: Int64 { get }

    /// 从 offset 起最多读取 length 字节。
    /// 返回的 Data 可能短于 length(到达 EOF 或网络层分片);返回空 Data 表示 EOF。
    func read(offset: Int64, length: Int) async throws -> Data

    func close() async
}

// MARK: - 数据源协议(VFS 核心)

public protocol MediaSource: AnyObject, Sendable {
    /// 稳定标识,库数据库用它把媒体条目关联回来源
    var id: UUID { get }
    var displayName: String { get }

    func connect() async throws
    func disconnect() async

    /// 目录枚举 —— 供媒体库扫描器使用。path 为 "" 表示共享根目录。
    func list(directory path: String) async throws -> [MediaSourceItem]

    /// 打开文件用于流式随机读 —— 供播放内核使用
    func open(file path: String) async throws -> MediaFileHandle
}

// MARK: - 便捷扩展

public extension MediaSource {
    /// 一次性读入小文件(.nfo、外挂字幕、封面),带体积上限保护
    func readEntireFile(at path: String, maxSize: Int = 16 * 1024 * 1024) async throws -> Data {
        let handle = try await open(file: path)
        defer { Task { await handle.close() } }

        let size = handle.fileSize
        guard size <= maxSize else {
            throw MediaSourceError.unsupported("文件过大(\(size) 字节),超过 readEntireFile 上限")
        }

        var result = Data(capacity: Int(size))
        var offset: Int64 = 0
        while offset < size {
            let chunk = try await handle.read(offset: offset, length: 1024 * 1024)
            if chunk.isEmpty { break }
            result.append(chunk)
            offset += Int64(chunk.count)
        }
        return result
    }

    /// 递归扫描辅助:深度优先枚举全部视频文件(扫描器可直接复用)
    func enumerateVideoFiles(under path: String = "", maxDepth: Int = 8) async throws -> [MediaSourceItem] {
        guard maxDepth > 0 else { return [] }
        var videos: [MediaSourceItem] = []
        for item in try await list(directory: path) {
            switch item.kind {
            case .file where item.isVideoFile:
                videos.append(item)
            case .directory where !item.name.hasPrefix("."):
                videos += try await enumerateVideoFiles(under: item.path, maxDepth: maxDepth - 1)
            default:
                break
            }
        }
        return videos
    }
}
