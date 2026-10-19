# 闪寻 FlashFind

macOS 菜单栏 NAS 文件搜索工具。按下全局热键呼出搜索框，直接搜你 NAS 上的文件名，
不用先在 Finder 里挂载共享文件夹。

- **当前版本**：1.1.1
- **许可**：Apache-2.0（见 `LICENSE`）
- **商标**：名称与图标保留，见 `TRADEMARK.md`

---

## 它解决什么问题

NAS 上的文件要找，通常得先连上共享文件夹，再用 Finder 慢慢翻。
闪寻做的是：**不挂载、直接搜**。搜索请求由客户端直连 NAS 发出，
结果列出后点一下才按需挂载、用系统方式打开。

## 支持什么设备

| 类型 | 协议 | 说明 |
|---|---|---|
| 群晖 Synology | DSM `SYNO.FileStation.Search` v2 | 走 DSM 的 Web API，支持 OTP 双因子登录 |
| 通用 WebDAV | WebDAV `PROPFIND` / `SEARCH` | 含飞牛 fnOS 等；OpenList 的入口是 `/dav` 且必须 https |
| SMB/CIFS | 系统 `mount_smbfs` | 只用于打开结果，不用于搜索 |

局域网发现走五路证据合并：Bonjour / Synology UDP 9999 / SSDP / ARP / TCP 端口探测
（端口探测已降级为兜底，只探「ARP 说在线但没有任何识别证据」的主机）。

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
bash scripts/build.sh test      # Swift 全量 755 项 + MyNASCore 的行为套件
```

或分开跑：

```bash
swift test                       # 755 项
cd MyNASCore && dart test_*.dart # 9 个套件
```

> `MyNASCore/test_webdav_live.dart` 默认在**本机**起一个真 WebDAV 服务器做端到端验证，
> 不连外部设备；只有显式传 `--base-url/--user/--password` 才会去连真机。

---

## 已知限制

- **仅 arm64**（Apple Silicon）。`LSMinimumSystemVersion = 13.0`，Intel Mac 装不了。
- **未做 Developer ID 签名与公证**。分发包是 ad-hoc 签名，
  Gatekeeper 会拦截。首次打开的放行方式见 `docs/安装与首次打开.md`。
- **凭据存系统钥匙串**。但本包是 ad-hoc 签名、没有
  `keychain-access-groups` entitlement，所以实际停在**经典钥匙串**那一档；
  签上 Developer ID 后新写入才会走 Data Protection，届时已有的密码由
  `KeychainTierMigration` 搬一次。详见 `SECURITY.md`。
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

## 安全

读 `SECURITY.md`。

## 第三方组件

见 `NOTICE`。
