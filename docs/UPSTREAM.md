# UPSTREAM —— 上游来源、许可证与派生关系

日期：2026-10-19 ｜ 适用版本：闪寻 FlashFind 1.1.1（客户端直连形态）

## 0. 本文件的边界

本文件只登记**可核实**的来源与许可事实：凡是本仓库里实际存在的文件、实际引用的
上游、实际链接的框架，都会在这里写明来源与许可；凡是没有引入的东西，也明确写
「没有」。

不在此写任何推测性归属、未核实的贡献者名单，或不存在的依赖关系。
若某项无法从本仓库自身核实，会标为「待确认」而不是补一个说法填上。

许可与商标的完整法律文本见 `LICENSE` 与 `TRADEMARK.md`，第三方许可摘要见
`NOTICE`。本文件是这两份的**来源说明**，不是替代。

---

## 1. 本项目自身

| 项目 | 事实 |
| --- | --- |
| 名称 | 闪寻 FlashFind 1.1.1 |
| 许可 | Apache License 2.0（全文见 `LICENSE`） |
| 版权 | Copyright 2026 李青宇 |
| 形态 | macOS 客户端，直连 NAS，无服务端组件 |
| 原创范围 | `Sources/`（Swift，含 `FlashFindCore` 与 `FlashFind2App`）、`MyNASCore/` 下除「第 2 节派生文件」以外的全部 Dart 代码、`MyNASCore/bin/harness.dart`、`MyNASCore/native/TrustHTTP.swift` |

「闪寻」「FlashFind」名称与 `Resources/Brand/` 下的图标**不在** Apache-2.0 授权
范围内，见 `TRADEMARK.md`。

---

## 2. 上游一：MyNAS（MIT）

本项目 `MyNASCore/` 下的搜索核心，其设计参照了开源项目 MyNAS。

| 项目 | 事实 |
| --- | --- |
| 上游仓库 | https://github.com/chenqi92/my-nas |
| 上游许可 | MIT License |
| 上游版权 | Copyright (c) 2024 chenqi92 |
| 许可文本 | `MyNASCore/licenses/MyNAS-MIT.txt`（原样保留） |
| 固定上游版本 | `2b1458e205e0d3011d3961feb74b4066818fa61c` |
| 逐文件映射 | `MyNASCore/SOURCE_MAP.md`（本文件是它的摘要） |

### 2.1 派生文件清单

| 本仓库文件 | 上游对应位置 | 关系 |
| --- | --- | --- |
| `MyNASCore/lib/upstream_file_types.dart` | `lib/nas_adapters/base/nas_file_system.dart` | 基础接口与 `FileItem` / `FileType` / `FileRange` / `ThumbnailSize` 逐字保留，仅加来源注释；去掉 Flutter 实现依赖 |
| `MyNASCore/lib/upstream_synology_models.dart` | `lib/nas_adapters/synology/api/synology_api.dart:1032–1085`（`FileStationFile`） | 基于上游构造器改写：字段必需性、缺失字段处理与日期转换按本项目契约重定，**不是上游原样解析** |
| `MyNASCore/lib/synology_api.dart` | `synology_api.dart:74/89/209/252/436/455` | 保留 API 名、方法、参数语义与 FileStation SID 用法；会话协商、POST 表单编解码、CSRF、分页、错误与会话身份均已重构，不保留固定 `entry.cgi`、全局 logger 或 Flutter 提示 |
| `MyNASCore/lib/core.dart` | `synology_file_system.dart:24/159`、`global_file_search_service.dart:38/58/104` | 参考目录分页与 start→poll→映射链路；`TaskLease`、取消语义、独立清理预算、最终分页与数量完整性为本项目新增实现 |

### 2.2 派生关系的性质（重要）

本项目**不是** MyNAS 的 fork，也不是「整体复用其 Adapter」：

* 未复制上游的 `NasAdapter`、`SourceManagerService`、`ConnectionProvider`；
* 未声称实现了完整的 MyNAS Adapter；
* 上游代码不参与证书信任 —— 信任链由本项目新增的 `MyNASCore/lib/source_trust.dart`
  与 `MyNASCore/native/TrustHTTP.swift` 承担；
* 进程桥接、JSON 协议、模拟传输、安全模型均为本项目新增，无上游等价物。

上游的 MIT 许可要求保留版权与许可声明，已通过 `MyNASCore/licenses/MyNAS-MIT.txt`
与 `NOTICE` 满足。

---

## 3. 上游二：SQLite（公有领域）

| 项目 | 事实 |
| --- | --- |
| 位置 | `Sources/CSQLite/sqlite3.c`、`Sources/CSQLite/include/` |
| 版本 | SQLite 3.50.4（ amalgamation 头部自述） |
| 许可 | 公有领域（Public Domain），作者已放弃版权 |
| 依据 | https://www.sqlite.org/copyright.html |
| 编译宏 | `SQLITE_ENABLE_FTS5`、`SQLITE_THREADSAFE=1`、`SQLITE_ENABLE_COLUMN_METADATA` |

SQLite 不要求随附许可声明；此处登记是为了让「仓库内存在第三方 C 代码」这一事实
可被核对，而不是出于许可义务。

---

## 4. 工具链运行时（非源码依赖，但随产物分发）

搜索核心以 Dart AOT（`dart compile exe`）形式分发，因此**产物内包含 Dart 运行时
代码**，而不只是本项目自己写的 Dart。

| 项目 | 事实 |
| --- | --- |
| Dart SDK 版本 | 3.13.5（stable，macos_arm64），本轮编译所用 |
| Dart 运行时许可 | 由 Dart SDK 自带 `LICENSE` 文件规定，位于 SDK 安装目录（如 `/opt/homebrew/opt/dart-sdk/libexec/LICENSE`）；本项目未修改 Dart 运行时 |
| 编译方式 | `dart compile exe bin/harness.dart`（见 `docs/构建与打包.md`） |
| 是否引入 pub 依赖 | **否**。仓库无 `pubspec.yaml`，全部 Dart 代码只 import `dart:*` 标准库 |
| Swift 包依赖 | **无**。`Package.swift` 全部依赖为仓库内 target，无任何 `.package(url:)` 外部包 |

> 发布二进制时，Dart 运行时的许可声明由 Dart SDK 许可覆盖。若未来引入任何 pub
> 依赖或 Swift 包，必须先在此登记版本、内容哈希与全部传递依赖的许可。

---

## 5. 操作系统框架

App 链接以下 macOS 系统框架，二者均为 Apple 系统组件，随操作系统分发，
不在本许可范围内，也无需随附许可文本：

* `Carbon` —— 全局热键
* `QuickLookUI` —— 空格预览

---

## 6. 品牌素材

`Resources/Brand/` 下的字形与图标由开发过程中使用的 AI 助手生成，非改编自第三方
商业字体或图标库。

AI 生成内容的著作权归属在现行法律下尚无定论；本项目不对其单独主张著作权，亦不
就第三方主张作出担保。详见 `TRADEMARK.md`。

---

## 7. 明确不存在的关系（负面事实）

登记这些是为了避免下游误判，同样是可核实事实：

1. 本仓库**没有** vendored 的第三方 Swift / Dart 包源码（除第 2、3 节所列）；
2. 本仓库**不含**飞牛（fnOS）REST 适配器的实现代码。该实现曾移植自上游并封存，
   现已删除：真实设备确认原生文件搜索使用 WebSocket + HMAC，而非那份 REST 实现
   假设的 HTTP 管理接口。历史版本仅保留在内部 Git 历史中，不随公开仓发布；
3. 本项目**不派生自**任何 NAS 厂商的官方 SDK —— 各厂商（群晖 / QNAP / 绿联 /
   WebDAV）适配均为本项目依据公开协议行为自行实现；
4. `tools/DevTools/` 下的 CLI 与 smoke 工具是本项目自有开发期工具，非第三方代码。

---

## 8. 待确认

以下内容本仓库自身无法核实，故不填写：

* MyNAS 上游仓库是否仍在原地址维护、其当前 LICENSE 是否仍为 MIT —— 本文件依据的
  是本项目在固定版本 `2b1458e205e0…` 上抽取时留存的许可文本（`MyNASCore/licenses/MyNAS-MIT.txt`）
  与内部映射记录（`MyNASCore/SOURCE_MAP.md`），未对上游现状做二次核实。
* Dart 运行时许可条款的具体条目 —— 以所用 Dart SDK 自带的 `LICENSE` 为准。
