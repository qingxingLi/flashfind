# 闪寻 FlashFind

macOS 菜单栏 NAS 文件搜索工具。按下全局热键呼出搜索框，直接搜你 NAS 上的文件名，
不用先在 Finder 里挂载共享文件夹。

- **当前版本**：1.1.19
- **许可**：Apache-2.0（见 `LICENSE`）
- **商标**：名称与图标保留，见 `TRADEMARK.md`
- **隐私**：不收集、不上传任何数据，见 `PRIVACY.md`

---

## 它解决什么问题

NAS 上的文件要找，通常得先连上共享文件夹，再用 Finder 慢慢翻。
闪寻做的是：**不挂载、直接搜**。搜索请求由客户端直连 NAS 发出，
结果列出后点一下才按需挂载、用系统方式打开。

## 怎么用

按 **⌥Space** 呼出搜索框，直接打字。

- **`\` 选位置**：列出「全部位置 / 此 Mac / 各来源下的每个搜索根」。选中后限定会**下推到设备侧**——
  只扫那一个根，不是把结果拉回来再过滤，所以检索时间是真的少了。
  没连上的来源也在列表里（副标题写「· 未连接」），选中它先连上再搜。
- **`/` 选类型**：pdf / word / excel / ppt / 照片 / 视频 / 音乐 / 压缩包 / 文档。
  类型过滤在客户端做，可以和位置叠加。
- 两个面板的候选都带数字，**按数字直接选中，也可以直接用鼠标点**；最后一条「打开设置…」固定按 **0**。
- 想改顺序或删掉不用的：设置 ▸ 搜索 ▸ **命令快捷键**。拖动整行排序、右键删除或换成别的位置/格式；
  顺序改了数字跟着变（**第几行就是几号**）。
- 结果列表里 **↓** 选中、**空格** 预览、再按 **空格** 关闭，**↩** 用系统方式打开。

## 支持什么设备

| 类型 | 协议 | 说明 |
|---|---|---|
| 群晖 Synology | DSM `SYNO.FileStation.Search` v2 | 走 DSM 的 Web API，支持 OTP 双因子登录 |
| OpenList | OpenList 的 `/api/fs/search` | 自带账号体系，支持 2FA 动态码；按搜索根查询，最多 4 路并发 |
| 通用 WebDAV | WebDAV `PROPFIND` / `SEARCH` | 含飞牛 fnOS 等；OpenList 的入口是 `/dav` 且必须 https |
| SMB/CIFS | 系统 `mount_smbfs` | 只用于打开结果，不用于搜索 |

局域网发现走五路证据合并：Bonjour / Synology UDP 9999 / SSDP / ARP / TCP 端口探测
（端口探测已降级为兜底，只探「ARP 说在线但没有任何识别证据」的主机）。

---

## 接入 AI 客户端（1.1.2 新增）

给支持 MCP 的 AI 客户端（Claude、Cursor、WorkBuddy 等）接上闪寻的检索能力，
让 AI 直接问「你那边有没有这个文件」，而不是让它猜路径。

**默认关闭，不开就没有任何对外接口。** 开启在 设置 ▸ **AI**：先打开总开关，
再勾选允许它搜哪几个来源；开关下方那段「接入提示词」可以一键复制，
粘给你的 AI 客户端即完成配置（里面写了助手位置与调用方式）。

| 项 | 说明 |
|---|---|
| 助手 | `闪寻.app/Contents/Helpers/flashfind-mcp`，随应用分发，不是单独下载 |
| 通道 | 本机 unix socket（`~/Library/Application Support/FlashFind2/ipc/mcp.sock`，权限 `0600`，仅同一登录会话可连），不出网 |
| 工具 | `list_sources` / `search` / `locate` / `locate_many` / `get_metadata` / `recent` |

交出去的只有文件本身的信息（名称、所在来源、**相对路径**、大小、修改时间、类型），
**不含文件内容**。路径给的是去掉开头 `/` 与卷挂载点的形态（如
`Users/you/Documents/报告.pdf`）——**如果你把「此 Mac」也授权给它，这个相对路径基本
就等于完整路径**，请按「它能看到文件名和所在文件夹」来评估。AI 引用文件时用的是
不透明的 `file_id`。授权范围跟着你的勾选走：取消勾选某个来源后，连它的旧 `file_id` 也问不到东西
（会像「文件不在了」一样返回 `not_found`，不给专门的拒绝码——拒绝本身也是一种信息）。

想收回随时可以：关掉总开关，或在同一页「清空 AI 历史」。细节见 `PRIVACY.md` 第六节。

---

## 构建

四个子命令，底下各是独立的脚本，`build.sh` 只做分发：

```bash
# 1) Dart 搜索核心（需要 Dart SDK 3.10.x 或更高；本轮验证使用 3.13.5）
#    位置自动发现：DART_SDK 环境变量 → PATH → 常见安装位，找不到才需要显式设
bash scripts/build.sh core

# 2) Swift 可执行体（要求 Resources/MyNAS 已在位，否则直接失败并指路，
#    绝不产出一个缺搜索核心的 App）
bash scripts/build.sh app

# 3) 打包（ad-hoc 签名，未做 Developer ID 公证）
bash scripts/build.sh package --release \
    --icon Resources/Brand/ShanXun.icns \
    --scratch <项目内的编译暂存目录> \
    --temporary-alias <指向该目录的短软链> \
    --output <项目内尚不存在的新目录>
```

三个路径的建法（软链那道是为了绕开 Swift 编译产物对路径长度的敏感）：

```bash
mkdir -p .ff2-scratch && ln -s .ff2-scratch .ff2-alias
```

> **`--scratch` / `--temporary-alias` / `--output` 都必须在项目内**，脚本会用
> `relative_to(project)` 逐个校验，写 `/tmp/...` 会直接报「不在项目内」。
> 不是洁癖：`build-record.json` 里记录的是相对项目根的路径与 SHA-256，
> 路径出了项目就无从复现。软链要先自己建好并指向 scratch 目录。

完整构建与打包参数见 `docs/构建与打包.md`。

### 跑测试

```bash
bash scripts/build.sh test      # Swift 全量 1600 项 + MyNASCore 的 11 个行为套件
```

或分开跑：

```bash
swift test                       # 1600 项
cd MyNASCore && dart test_*.dart # 11 个套件（两个 live 套件要真服务器，脚本里跳过）
```

> `MyNASCore/test_webdav_live.dart` 默认在**本机**起一个真 WebDAV 服务器做端到端验证，
> 不连外部设备；只有显式传 `--base-url/--user/--password` 才会去连真机。

---

## 已知限制

- **双架构分开发包**：Apple Silicon 用 `arm64` 包，Intel Mac 用 `x86_64` 包，
  两个包内容相同、按机器的芯片选对应的那个（关于本机 → 芯片）。
  没有做 universal 单包（体积会翻倍）。`LSMinimumSystemVersion = 13.0`。
- **未做 Developer ID 签名与公证**。分发包是 ad-hoc 签名，
  Gatekeeper 会拦截。首次打开的放行方式见 `docs/安装与首次打开.md`。
- **凭据存系统钥匙串**。但本包是 ad-hoc 签名、没有
  `keychain-access-groups` entitlement，所以实际停在**经典钥匙串**那一档；
  签上 Developer ID 后新写入才会走 Data Protection，届时已有的密码由
  `KeychainTierMigration` 搬一次。详见 `SECURITY.md`。
- **钥匙串授权框：每装一个新版本一次，与 NAS 台数无关。** 1.1.5 起所有设备的密码
  合并存成**一条**记录，所以你有 5 台 NAS 也只弹 1 次；同一版本内重启、覆盖安装都不再弹。
  弹框请点 **「始终允许」**——点「允许」只对本次运行有效，下次启动还会再问。
  这是 ad-hoc 签名的固有代价（系统按 cdhash 认应用身份，换版本即换身份），
  换成 Developer ID 签名后才会消失。
- **升级后「完全磁盘访问」可能显示为开、实际已失效。** 同样是换版本即换身份导致的：
  系统设置里那个开关可能仍停在打开位置，但新版本实际读不到受保护目录
  （闪寻设置页会显示「未授权」）。修法：把开关**关掉再打开**，然后**完全退出闪寻再启动**。
  升级后如果发现桌面、文稿里的新文件搜不到，先查这一条。
- **旧的明文凭据文件会自行消失**：1.0 时期落在
  `~/Library/Application Support/FlashFind2/credentials.json`（目录 0700、文件 0600）。
  1.0.1 起它只剩「迁移来源」一个用途——启动搬进钥匙串，等某次真实登录验证通过后才逐条删除。
  迁移没走完时它会一直在，那是正常的，不是漏删。
- 局域网发现只扫本机所在的 `/24`；`localIPv4()` 取第一个私有网卡，
  若该网卡无掩码（某些 VPN 隧道）则整轮发现不执行。

---

## 架构一瞥

```
FlashFind2App   界面层（SwiftUI + AppKit）—— 不可测，靠结构测试与人工点验
FlashFindCore   可测逻辑层（连接管理、设备归并、分类、结果排序）
MyNASCore       Dart 搜索核心，以子进程方式运行，stdin/stdout 走 JSON 行协议
```

**跨进程协议版本必须对齐**：Swift 侧 `MyNASProcessBridge.expectedCoreRevision`
与 Dart 侧 `protocol.dart` 的 `coreRevision` 必须一致，否则启动即报错退出。

凭据只在需要时经 stdin 管道送入核心，不落命令行、不写环境变量。

---

## 参与开发

请先读 `CONTRIBUTING.md`。本项目的测试纪律比较硬（App 层不可实例化，
界面层靠扫源码结构测试；改动必须先在未修源码上跑红），不读容易返工。

## 隐私

不收集、不上传任何数据：没有账号、没有服务器、没有云端同步，也就没有一个能接收的地方。
对外网络请求只有两类 —— 连**你自己配置的** NAS，以及你点「检查更新」时向 GitHub 读一次
公开的发布信息（匿名、无参数、不点不发）。文件名只进本机索引（不含内容），
密码存系统钥匙串。

AI 访问（上面那一节）走的是**本机 socket**，不是第三类网络请求；它默认关闭，
且只在你勾选的范围里、只回文件名与元数据。**AI 客户端本身是不是联网、会不会把
拿到的东西发出去，取决于那个客户端，不取决于闪寻** —— 它是你的另一个软件，
闪寻没有能力也无意替它承诺。

全文、本机落点清单与四步自查命令见 `PRIVACY.md`。

## 安全

读 `SECURITY.md`。

## 第三方组件

见 `NOTICE`。
