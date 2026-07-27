## 一、关键技术点调研

**1. 数据源 / 协议层（第一个坑就在这）**

iOS/tvOS **没有公开的 SMB 系统 API**（Files App 能连 SMB，但不开放给第三方），所以 NAS 访问必须自带协议栈：

| 协议 | 方案 | 备注 |
|---|---|---|
| SMB | `libsmb2`（LGPL）/ Swift 封装 `AMSMB2` | NAS 主力协议，必做；注意有开源实现只协商到 SMB 2.x，遇到强制 SMB3 加密的服务器会连不上，选库时要验证 SMB3 + 加密支持 |
| NFS | `libnfs` | 群晖/威联通常见，优先级次于 SMB |
| WebDAV / FTP | 基于 `URLSession` 自研 | 成本最低，还是网盘直连的基础 |
| UPnP / DLNA | SSDP 发现 + HTTP 流 | 主要价值是**自动发现**，降低连接门槛 |
| Plex / Emby / Jellyfin | REST API + 直链播放 | 性价比极高：登录即得全库元数据，不用自己刮削 |

配套要做：Bonjour/mDNS 局域网自动发现（把"输 IP 填端口"变成"点一下"）、凭据存 Keychain（可随 iCloud Keychain 同步）。另外注意 **tvOS 没有可靠的持久化大容量存储**（缓存可能被系统清理），所以整体必须按"纯流式 + 可再生缓存"设计。

**2. 播放内核（技术含量最高的模块）**

`AVPlayer` 只支持 Apple 系格式（MP4/MOV/HLS），MKV、TS、ISO 一概不认——这正是 Infuse 自研内核的原因。现实可选路线：

| 路线 | 优点 | 致命点 |
|---|---|---|
| VLCKit | 格式全、成熟 | LGPL 合规要处理；HDR/杜比视界支持弱，渲染走老管线 |
| MPVKit (libmpv) | 画质调校强 | GPL 传染（闭源商用不可行）；视频输出走 OpenGL 层，HDR 支持不如 Metal 路线 |
| KSPlayer | 纯 Swift、基于 AVPlayer + FFmpeg 双内核,支持 HLG/HDR10/HDR10+/杜比视界、文本与图形字幕,覆盖苹果全平台 | 默认 GPL(要求开源你的项目),商用闭源需联系作者购买 LGPL 或更宽松授权 |
| 自研：FFmpeg 解封装 + VideoToolbox 硬解 + Metal 渲染 | 完全可控、无授权纠纷（FFmpeg 用 LGPL 构建） | 工作量最大，音画同步、seek、HDR 色调映射都要自己啃 |

推荐架构思想是**混合内核**（这也是 KSPlayer 和 Infuse 的共同路径）：系统能吃的格式走 AVPlayer/系统管线,享受杜比视界、Atmos、Match Content 等深度系统集成;系统不认的格式用 FFmpeg 解封装后,视频 ES 流尽量喂给 VideoToolbox 硬解,只有硬件不支持的编码才落到软解（配 dav1d 处理 AV1 老设备）。

**3. HDR 与音频（决定"发烧友买不买账"）**

- 真·杜比视界（Profile 5/8）必须走系统显示管线（`AVSampleBufferDisplayLayer` + 正确的 `CMFormatDescription` 元数据透传），自绘 Metal 只能做到 HDR10/HLG 的 EDR 呈现。
- 音频:多声道走 `AVAudioEngine`;Apple TV 上 E-AC3（Atmos）可直通给功放。AC-3 专利已过期可放心软解；**DTS/DTS-HD 仍在专利保护期**，FFmpeg 虽有解码器,商业分发有专利风险——这就是 Infuse 把 DTS 塞进 Pro 的原因之一，你需要评估是否购买 DTS 授权或首版先不支持。

**4. 字幕**：文本字幕（SRT/ASS）用 `libass` 渲染保证特效正确；位图字幕（PGS/VobSub）解码后作为独立图层在 Metal 里合成；在线字幕接 OpenSubtitles API。

**5. 刮削与媒体库**：文件名解析器（类 GuessIt 的规则引擎：抽出片名/年份/S01E02/分辨率）→ TMDB API 匹配 → 海报缓存 → 本地 SQLite（推荐 GRDB）。要点是**增量扫描**（记录目录 mtime/etag，别每次全量）和**离线优先**（元数据全部本地持久化，NAS 不在线也能浏览）。注意 TMDB API 商用需要单独商业授权。

**6. 跨设备同步**：CloudKit 私有数据库（免费、免运维）同步观看进度、库配置、连接列表；这是留存的核心钩子，建议 P1 就做进度同步。

**7. 多端 UI**：SwiftUI 一套代码 + 平台适配层。tvOS 是重点差异区：焦点引擎（focus engine）、Siri Remote 手势快进、Top Shelf 扩展（桌面展示"继续观看"）。

**8. 合规红线**：FFmpeg 必须用 **LGPL 配置构建**（去掉 `--enable-gpl` 组件如 x264）并保证 LGPL 合规（动态链接或提供可重链接目标文件）；GPL 组件（libmpv、KSPlayer 免费版）与闭源上架冲突；杜比视界标识需要认证；产品叙事上远离盗版联想（App Store 审核敏感点）。

## 二、总体架构设计

核心设计原则只有一条：**"来源无关"**——所有协议适配器归一到一个统一的 VFS 抽象（提供"按字节范围读取"能力），上层的媒体库和播放内核完全不感知数据从哪来。这正是 Infuse 架构的 primitive。链路上的几个工程要点：FFmpeg 侧通过**自定义 AVIO 回调**把"读文件"重定向到 VFS 的字节范围读取，这样 SMB/网盘上的 MKV 无需下载即可流式播放和任意 seek；解码后视频帧保持 `CVPixelBuffer` 零拷贝直达 Metal；音画同步以音频时钟为主时钟（音频卡顿远比丢帧刺耳）；HDR 元数据（色域/传递函数/DV RPU）要沿管线完整透传，这是"真 HDR"和"洗掉的 HDR"的分界线。

## 四、技术选型总结

| 模块 | 推荐方案 | 备选 |
|---|---|---|
| 语言/UI | Swift + SwiftUI（多端共享包，平台差异化壳） | UIKit/AppKit 混编热点页面 |
| SMB | AMSMB2 (libsmb2)，验证 SMB3 加密 | 自研 SMB 客户端（不建议） |
| 播放内核 | 混合内核：AVPlayer + 自研 FFmpeg(LGPL 构建)/VideoToolbox | 购买 KSPlayer LGPL 商用授权快速起步 |
| 视频渲染 | Metal + EDR；DV 走系统显示管线 | AVSampleBufferDisplayLayer 全托管 |
| 字幕 | libass + PGS 位图合成 | 仅 SRT 起步 |
| 数据库 | GRDB (SQLite) | SwiftData |
| 同步 | CloudKit 私有库 + Keychain | 自建账号体系（后期再说） |
| 元数据 | TMDB API（商用需授权）+ 自研文件名解析 | 复用 Plex/Jellyfin 服务端元数据 |

## 五、落地路线（建议三阶段）

**P0 · 跑通闭环（约 2–3 个月）**：SMB + WebDAV 两个适配器、VFS 抽象、AVPlayer 播 MP4、基础文件名解析 + TMDB 刮削 + 海报墙、iPhone/iPad 单端。这一版验证的是"连接 → 海报墙 → 播放"的 Aha 时刻。

**P1 · 补上灵魂（3–6 个月）**：FFmpeg 混合内核上线（MKV 是 NAS 场景的事实标准格式，播不了 MKV 就没有产品）、tvOS 端（这是此类产品的主战场）、观看进度 CloudKit 同步、字幕系统。

**P2 · 拉开差距**：HDR10/杜比视界、音频直通、Jellyfin/Plex 客户端模式、网盘适配器、Mac 端、局域网自动发现向导。

## 六、主要风险提示

技术上最大的两个坑是**播放内核的长尾兼容**（格式矩阵 × 设备矩阵，需要尽早建自动化片源回归测试库）和 **SMB 在真实 NAS 环境的连接成功率**（群晖/威联通/Windows 共享的配置千奇百怪，这恰好也是 Infuse 的最大漏斗洞）。合规上盯住三条：FFmpeg 只用 LGPL 构建、DTS 专利、TMDB 商用条款。产品上则要想清楚与 Infuse/Vidhub 的差异化切入点——上一轮拆解里提到的"引导式连接向导"和"端侧 AI 字幕"，其实就是留给后来者的两个空位。