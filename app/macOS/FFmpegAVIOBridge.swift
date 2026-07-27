//
//  FFmpegAVIOBridge.swift
//  播放内核 — 把 MediaFileHandle 桥接为 FFmpeg 自定义 AVIO
//
//  作用:让 avformat_open_input() 直接"打开"SMB/WebDAV/网盘上的文件,
//  实现不下载、流式解封装、任意位置 seek。整条播放链路的关键胶水。
//
//  依赖:你自己的 FFmpeg XCFramework(LGPL 配置构建!去掉 --enable-gpl 组件)。
//  下面的 `import CFFmpeg` 换成你 modulemap 里实际的模块名。
//
//  线程模型:
//  FFmpeg 的 read/seek 回调是同步 C 函数,而 MediaFileHandle 是 async。
//  桥接策略:回调线程用信号量阻塞等待 async 读完成。
//  这是安全的 —— 解封装本来就运行在播放内核的专用线程,阻塞它不影响 UI。
//

import Foundation
import CFFmpeg // TODO: 替换为你的 FFmpeg 模块名

public final class FFmpegAVIOBridge {

    /// AVIO 内部缓冲。太小 → 回调频繁;太大 → seek 后丢弃浪费。256KB 是网络源的良好起点。
    private static let bufferSize = 256 * 1024

    private let handle: MediaFileHandle
    /// FFmpeg 视角的当前读取位置(由回调维护)
    fileprivate var position: Int64 = 0
    fileprivate let fileSize: Int64

    private var ioContext: UnsafeMutablePointer<AVIOContext>?

    public init(handle: MediaFileHandle) {
        self.handle = handle
        self.fileSize = handle.fileSize
    }

    deinit {
        if let ctx = ioContext {
            // avio_context_free 会释放 context,但 buffer 需要单独释放
            av_freep(&ctx.pointee.buffer)
            var mutableCtx: UnsafeMutablePointer<AVIOContext>? = ctx
            avio_context_free(&mutableCtx)
        }
    }

    // MARK: - 对外接口

    /// 创建 AVIOContext,挂到 AVFormatContext.pb 上使用:
    ///
    ///     let bridge = FFmpegAVIOBridge(handle: try await source.open(file: path))
    ///     var fmtCtx = avformat_alloc_context()
    ///     fmtCtx!.pointee.pb = bridge.makeAVIOContext()
    ///     avformat_open_input(&fmtCtx, nil, nil, nil)   // url 传 nil,走自定义 IO
    ///
    /// 注意:bridge 的生命周期必须覆盖整个播放会话(强持有它)。
    public func makeAVIOContext() -> UnsafeMutablePointer<AVIOContext>? {
        guard ioContext == nil else { return ioContext }

        guard let buffer = av_malloc(Self.bufferSize) else { return nil }
        let opaque = Unmanaged.passUnretained(self).toOpaque()

        ioContext = avio_alloc_context(
            buffer.assumingMemoryBound(to: UInt8.self),
            Int32(Self.bufferSize),
            0,              // write_flag = 0,只读
            opaque,
            avioReadPacket, // read 回调
            nil,            // 不需要 write
            avioSeek       // seek 回调 —— 没有它就无法拖进度条
        )
        return ioContext
    }

    // MARK: - 同步桥(供 C 回调调用)

    /// 阻塞式读:在回调线程等待 async read 完成
    fileprivate func blockingRead(into buf: UnsafeMutablePointer<UInt8>, maxLength: Int) -> Int32 {
        if position >= fileSize { return AVERROR_EOF }

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Data, Error> = .failure(MediaSourceError.readFailed(underlying: nil))

        let offset = position
        let handle = self.handle
        Task.detached(priority: .userInitiated) {
            do {
                result = .success(try await handle.read(offset: offset, length: maxLength))
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()

        switch result {
        case .success(let data):
            if data.isEmpty { return AVERROR_EOF }
            data.copyBytes(to: buf, count: data.count)
            position += Int64(data.count)
            return Int32(data.count)
        case .failure:
            return swift_AVERROR(EIO) // 见文件底部说明
        }
    }

    fileprivate func performSeek(offset: Int64, whence: Int32) -> Int64 {
        // AVSEEK_SIZE:FFmpeg 询问文件总大小
        if whence & AVSEEK_SIZE != 0 { return fileSize }

        let newPosition: Int64
        switch whence & ~AVSEEK_FORCE {
        case SEEK_SET: newPosition = offset
        case SEEK_CUR: newPosition = position + offset
        case SEEK_END: newPosition = fileSize + offset
        default:       return -1
        }
        guard newPosition >= 0, newPosition <= fileSize else { return -1 }

        position = newPosition
        return newPosition
        // 注意:seek 本身不发起网络请求,只移动指针 —— 下一次 read 才会按新位置拉数据。
        // 预读缓存层(后续在 MediaFileHandle 实现里做)应感知大幅 seek 并丢弃失效预读。
    }
}

// MARK: - C 回调(@convention(c) 不能捕获上下文,通过 opaque 找回 self)

private func avioReadPacket(opaque: UnsafeMutableRawPointer?,
                            buf: UnsafeMutablePointer<UInt8>?,
                            bufSize: Int32) -> Int32 {
    guard let opaque, let buf else { return swift_AVERROR(EINVAL) }
    let bridge = Unmanaged<FFmpegAVIOBridge>.fromOpaque(opaque).takeUnretainedValue()
    return bridge.blockingRead(into: buf, maxLength: Int(bufSize))
}

private func avioSeek(opaque: UnsafeMutableRawPointer?,
                      offset: Int64,
                      whence: Int32) -> Int64 {
    guard let opaque else { return -1 }
    let bridge = Unmanaged<FFmpegAVIOBridge>.fromOpaque(opaque).takeUnretainedValue()
    return bridge.performSeek(offset: offset, whence: whence)
}

// MARK: - 辅助

/// FFmpeg 的 AVERROR 是宏,Swift 导入不了,自己等价实现:AVERROR(e) == -e
private func swift_AVERROR(_ code: Int32) -> Int32 { -code }
