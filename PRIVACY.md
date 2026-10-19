# 隐私说明

**一句话**：闪寻不收集、也不上传你的任何数据。它没有账号、没有服务器、没有云端同步 ——
也就没有一个能接收这些东西的地方。

本说明写的是**代码当前实际在做的事**，不是意图或愿景。每一条都可以用
[文末的命令](#自己核对三步)在源码里自己核对一遍；如果哪一条和实现不符，那是 bug，
请按 `SECURITY.md` 的渠道报出来。

- 适用版本：闪寻 FlashFind 1.1.1
- 最后更新：2026-10-19
- 变更方式：本文件随代码进 git，任何改动都能在提交历史里查到。

---

## 一、它不收集什么

| 类别 | 实际行为 |
| --- | --- |
| **文件内容** | 从不读取。索引只取文件名、类型、大小、修改时间；打开文件靠系统默认程序，闪寻不经手内容 |
| **文件名与路径** | 只写进**本机**的索引库（见第三节），不发往任何地方 |
| **搜索关键词** | 只在本机解析与匹配，不记录、不上报 |
| **账号名** | 随来源配置存在本机，用于连接你自己的 NAS |
| **密码** | 存进系统钥匙串，不写明文文件（细节见第三节） |
| **使用统计 / 埋点** | 没有。代码里没有任何一处统计或上报调用 |
| **崩溃报告 / 诊断上传** | 没有。诊断面板是给你看的，复制与否由你决定 |
| **设备指纹、位置、通讯录、剪贴板** | 没有申请相关权限，也没有对应代码 |
| **账号体系** | 没有注册、没有登录、没有用户 ID，因此不存在「你名下的数据」 |

**没有第三方统计 / 广告 / 推送 SDK。** 依赖清单见 `NOTICE`：SQLite、Dart 运行时、
与本项目自有的网络小工具，没有一类是做数据收集的。

---

## 二、它唯一会发出去的网络请求

一共两类。**没有第三类**，也没有任何后台定时联网。

### 1）连你自己的 NAS

- 目标：**你在设置里填的地址**（SMB 445、WebDAV、群晖 DSM 5000/5001 等）。
- 内容：登录、列目录、按文件名搜索。点对点直连，**不经过任何中转服务器**。
- 结果：这些请求只发生在你的 Mac 与你的 NAS 之间。闪寻没有「云端」这一层，
  所以也没有任何环节能看到它们。

### 2）「检查更新」——只有你点那一下才发

- 请求：`GET https://api.github.com/repos/qingxingLi/flashfind/releases/latest`
- 匿名、只读、**不带任何参数**、不带 cookie、不带任何本机标识；
  请求头里只有 `Accept: application/vnd.github+json` 与 `User-Agent: FlashFind/<版本号>`。
- **必须说清楚的一点**：任何 HTTP 请求都会把你的 IP 地址暴露给对方 —— 这里是 GitHub。
  这是网络本身的性质，不是闪寻额外收集的东西，但既然你读到「不上传数据」这句，
  就应该同时知道这条边界。GitHub 如何处理访问日志，见其隐私政策
  <https://docs.github.com/site-policy/privacy-policies/github-general-privacy-statement>。
- **不点不发**：没有定时检查、没有开机自动检查；后台不会自己去问。
- 从源码直接跑的开发构建连这一步都不做（没有版本号可比，直接判「不可比」）。
- 拿到结果后**只在本机比较版本号**：不下载、不安装、不改动你的任何文件，
  需要新版本时只是把发布页交给你自己打开。

---

## 三、局域网里它做了什么

只有在你主动点「发现设备」时才发生：

- 发 SSDP `M-SEARCH` 查询到组播地址 `239.255.255.250:1900`；
- 发群晖发现包到广播地址 `255.255.255.255:9999`；
- 读本机 ARP 表（`arp -an` 的输出，不产生网络包），并对着候选地址做 TCP 探测，
  判断这台设备开着哪些服务；
- 以上全部限于**本机所在 /24 网段**，不出公网，也不扫其他网段。

这些包的内容就是「有没有 NAS 在」这类发现查询，不含你的文件名、账号或密码。

---

## 四、它在本机存了什么

全部在 `~/Library/Application Support/FlashFind2/` 与系统钥匙串里，**不出本机**。

| 数据 | 位置 | 说明 |
| --- | --- | --- |
| 来源配置（名称、地址、端口、共享范围、账号名） | `~/Library/Application Support/FlashFind2/sources.json` 等 | 明文 JSON。**不含密码**；目录权限仅本人可读 |
| 密码 | **系统钥匙串**（`nas-source:<id>` 条目） | 不写明文。ad-hoc 签名下实际落在「经典钥匙串」那一档，签上 Developer ID 后新写入才走 Data Protection，详见 `SECURITY.md` |
| 文件名索引 | `~/Library/Application Support/FlashFind2/<sourceID>.sqlite` | 仅相对路径、类型、大小、修改时间，**无文件内容** |
| 1.0 时期的旧明文凭据 | 同目录 `credentials.json`（0600） | 只作迁移来源：搬进钥匙串、且某次真实登录验证通过后逐条删除；迁移没走完时它还在，属正常 |
| 运行态（待验证标记等） | 同目录 | 与连接状态有关，不含内容与密码 |

> 这个目录是应用自己的数据目录，**不含**你的文档、照片或任何被搜索的文件本身 ——
> 那些始终在原来的位置，闪寻只记名字。

---

## 五、你的控制权

- **删掉一个来源**：同时删掉它在钥匙串里的密码（`CredentialStore.removeSource`），
  不会留下无人认领的孤儿条目。
- **取消「记住这台 NAS 的密码」**：立刻删掉已保存的密码，不留副本。
- **清索引**：在设置里移除来源，它对应的 `.sqlite` 索引一并清理。
- **不想让它联网**：不点「检查更新」就不会有任何对外请求；不点「发现设备」
  就不会有广播。也可以直接断网使用，搜索与打开仍然工作。
- **彻底清理**：退出闪寻后删除 `~/Library/Application Support/FlashFind2/`，
  并在「钥匙串访问」里搜 `nas-source:` 删掉对应条目即可。卸载 App 本身不会自动删这两处。

---

## 六、这份说明的边界

- 它覆盖**闪寻自己**。你的 NAS 由厂商管理，NAS 侧的访问日志与数据归属请看你 NAS 的说明。
- 通过 SMB / WebDAV 传输的数据，安全级别由你的 NAS 与网络决定。闪寻**不会**替你
  把加密连接悄悄降级成明文；如果某台设备只支持明文 HTTP，界面会明确提示并让你自己选。
- 本说明不承诺「绝对安全」这种做不到的事，只承诺**上面写的行为与代码一致**。

---

## 自己核对（三步）

```bash
# 1) 所有网络调用点都在这里，数一遍就知道有没有第三个出口
grep -rn "URLSession\|URLRequest" Sources/

# 2) 有没有统计 / 埋点 / 上报（CSQLite 是 SQLite 源码，那几条命中是它自己的注释）
grep -rin "telemetry\|analytics\|tracking\|上报\|埋点" Sources/ | grep -v CSQLite

# 3) 源码里出现的所有对公网地址
grep -rn "https://" Sources/FlashFindCore Sources/FlashFind2App | grep -v example
```

第 1 步应当只列出连接你自己的 NAS、SSDP 发现、端点探测与检查更新这几处；
第 3 步应当只有 `api.github.com` 与 `github.com` 两个域名（都属检查更新）。

---

## English summary

FlashFind does not collect or upload your data. There is no account, no server,
no cloud sync — nothing that could receive it. The app indexes file **names and
metadata only** (never file contents) into a local SQLite database, and stores NAS
passwords in the macOS Keychain.

Exactly two kinds of network requests exist: (1) connections to the NAS address
**you** configured, peer-to-peer; (2) an anonymous update check to
`api.github.com/repos/qingxingLi/flashfind/releases/latest`, sent **only when you
click "Check for Updates"** — no query parameters, no cookies, no identifiers.
As with any HTTP request, that one exposes your IP address to GitHub. There is no
analytics, telemetry, crash reporting or advertising SDK. LAN discovery uses SSDP
and broadcast probes inside your local /24 only.
