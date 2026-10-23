# 安全说明

## 报告漏洞

请通过本仓库的 Security Advisory 私下提交，**不要开公开 issue**。
请在报告里附上：受影响的版本、复现步骤、你观察到的实际行为与预期行为。

---

## 凭据是怎么存的

| 项 | 位置 |
|---|---|
| NAS 账号密码 / OTP | **系统钥匙串**（`KeychainSecretStore`，GUI App 的默认后端） |
| 历史遗留的明文副本 | `~/Library/Application Support/FlashFind2/credentials.json`（目录 `0700`、文件 `0600`） |
| 证书固定记录 | `~/Library/Application Support/FlashFind2/MyNAS/trust/source-trust.json` |

### 1.1.5 起：所有设备合并成一条记录

1.1.5 之前是「一台设备一条钥匙串条目」——于是每装一个新版本，你要为**每台设备**分别
授权一次，设备越多越烦。1.1.5 起改为**全部凭据存进同一条**（`service=com.flashfind.v2.credentials`、
`account=vault`，内容是 `{"v":1,"entries":{"来源账号":"密码"}}`），
授权次数从此**与设备台数无关**。

代价与约束，一并说清：

- **每装一个新版本仍会弹 1 次。** 本包 ad-hoc 签名，系统按 cdhash 认身份，换版本即换身份，
  条目访问列表里的旧身份失配。想让这一次也消失，只有 Developer ID 一条路。
- **搬迁顺序是硬约束**：先写新条目 → **读回确认** → 才删旧条目。写不进或读不回，
  旧条目一律原样留着（`VaultConsolidation` 里锁死）。
- **读不懂就不写。** 合并条目解析失败时按 `damaged` 处理，只读不写——
  否则一次解析错误就可能把全部设备的密码覆盖成空表。
- 弹框请点 **「始终允许」**；点「允许」只对本次运行有效。

### 钥匙串的两档，以及现在停在哪一档

钥匙串有经典与 Data Protection（DP）两档。后者要 App 带
`keychain-access-groups` entitlement，而本分发包是 **ad-hoc 签名、没有 entitlement**，
于是 `KeychainSecretStore` 会**自动退到经典钥匙串**——密码照样存得上，只是层级低一档。

等签上 Developer ID、entitlement 到位，新写入自然会走 DP。
但那时**已经躺在经典钥匙串里的那批密码不会自己跟过来**，
所以需要 `KeychainTierMigration` 显式搬一次（先写 DP、再删经典，顺序反了等于删掉唯一副本）。

### 明文文件现在只是迁移源

`credentials.json` 是 1.0 时期的落点。自 1.0.1 起 GUI App 默认走钥匙串，
这个文件只剩一个用途：**迁移来源**。启动时把里面的条目搬进钥匙串，
搬完不立刻删——要等某次真实登录用钥匙串里的密码连上了，才逐条删、最后删掉整个文件。
（`CredentialStore.migrateLegacyPlaintext` → `confirmCredentialVerified`）。

它若存在，权限是目录 `0700` / 文件 `0600`；随着迁移完成它会消失，
**留着一个不空的 `credentials.json` 说明迁移还没走完，那才是要查的事**。

### 开发中想加钥匙串调用，请先读这条闸口

`Tests/FlashFindCoreTests/NoKeychainAccessTests.swift` 守着一条硬规矩：
**除 `KeychainSecretStore.swift` 一个文件之外，产品代码不许出现任何 `SecItem*` 调用**。

理由不是洁癖：钥匙串弹窗是**进程外**的副作用，由系统 SecurityAgent 弹出，
单次 XCTest 里根本观察不到——本机跑一百遍都是绿的，用户一开机就中招。
典型的漏法是「为了顺手迁移旧条目」在某个别的文件里留一次 `SecItemCopyMatching`。
要碰钥匙串，就收进 `KeychainSecretStore.swift`。

### 凭据怎么传给搜索核心

搜索核心是独立子进程。**凭据只在需要时经 stdin 管道写入**，不出现在命令行参数里，
也不写进环境变量 —— 避免被 `ps` 或子进程环境看到。

---

## 证书固定（source pin）

首次连接一台设备时，客户端记录该设备证书的 SHA-256。
之后证书变了就拒绝连接并要求重新确认，防止中间人。

- 信任记录按 **sourceID + host + port** 三元组存；
- 若设备证书是系统可信 CA 签发的、且未配置 pin，则按系统策略放行，不算故障；
- `allowExpired` 只对用户明确确认过的记录置位。

---

## 局域网发现做了什么

扫描**只在本机所在的 `/24` 内**进行，且只针对私有网段
（`10/8`、`172.16/12`、`192.168/16`）。

- 公网地址、回环地址一律不扫 —— 有测试锁（`testOnlyPrivateIPv4IsScannable`）；
- TCP 端口探测已降级为兜底，只对「ARP 说在线但没有任何识别证据」的主机执行；
- 不向任何外部服务器上报数据，本项目没有遥测。

macOS 会为局域网访问弹「本地网络」权限，这是系统行为。

---

## 已知的安全取舍

以下都不是漏洞，是明确的取舍，改之前请先讨论：

1. **未签名 / 未公证** —— 分发包是 ad-hoc 签名，Gatekeeper 会拦截。
   升级到 Developer ID 需要 Apple 开发者账号。这一条同时卡着钥匙串的档次：
   没有 entitlement 就只能用经典钥匙串（见上）。
2. **只扫 `/24`** —— 更大范围的扫描不符合「文件搜索工具」的定位。

---

## 第三方组件的安全更新

`MyNASCore`（Dart）与 vendored `Sources/CSQLite/sqlite3.c` 需要跟随上游更新。
清单见 `NOTICE`。
