# MyNAS 源码抽取映射

日期：2026-10-09｜固定上游：`2b1458e205e0d3011d3961feb74b4066818fa61c`；原件根 LICENSE MIT，保留于 `licenses/MyNAS-MIT.txt`。

> 正文里的 `EXP-xx` 编号是内部工作包编号，只用于追溯「这份文件是第几轮、从哪一版
> 上游抽出来的」，与当前代码的功能、行为、兼容性**没有任何关系**——改掉它们不会
> 改变任何一行代码的行为，保留是为了让后来的人能查到当时的实机结论。
> 本文件记录抽取事实，随源码一并公开即为其当前状态。

| 上游 | 抽取文件 | 保留与修改 |
| --- | --- | --- |
| lib/nas_adapters/base/nas_file_system.dart | lib/upstream_file_types.dart | 基础接口与FileItem/FileType/FileRange/ThumbnailSize逐字保留（仅加来源注释）；运行核心实际调用FileType分类，无Flutter |
| lib/nas_adapters/synology/api/synology_api.dart:1032–1085 FileStationFile | lib/upstream_synology_models.dart | 基于原构造器、additional/time映射与日期转换；必需字段严格校验，size缺失为null，时间明确UTC。不是上游原样解析 |
| synology_api.dart:74/89/209/252/436/455 | lib/synology_api.dart | 保留API名/方法/参数语义、FileStation SID、FileStationFile映射调用；按EXP-02重构Info协商/POST表单codec/CSRF/分页/错误/会话身份，不保留固定entry.cgi、全局logger或Flutter提示 |
| synology_file_system.dart:24/159 | lib/core.dart | 参考目录分页及start→poll→文件映射链路；TaskLease/取消/独立清理预算/最终分页/数量完整性为闪寻新增Dart实现，非声称上游已有 |
| global_file_search_service.dart:38/58/104 | lib/core.dart + test/matrix.dart | 来源身份/BFS名称contains逻辑的适配；改变回退条件为仅确定unsupported，限定深度/数量/目录/时间，输出partial；来源增量/queryID与模拟并行测试新增。未复制整个Manager或实现产品Coordinator |
| 无上游等价 | protocol.dart/open_target.dart/mock_transport.dart/bin/harness.dart/swift/BridgeMock.swift | 闪寻新协议/模拟传输/安全模型/进程桥接；Swift只启动与消费Dart核心，不重写NAS实现 |

实际MyNAS Dart代码（基础接口/类型、适配后的FileStation解析及API调用结构）被VM编译并用于搜索；不是仅回声probe或Swift重写。实现没有复制上游NasAdapter、SourceManagerService或ConnectionProvider，也不称完整MyNAS Adapter整体复用。
仅使用Dart标准库，无pub依赖，无需pub get/Flutter/媒体SDK。Dart SDK许可证及归档完整性证据见EXP-03-环境准备-20261009.json；工具链保留SDK LICENSE/NOTICES。未来如引入 dio/crypto，需要先补版本、内容哈希及各传递依赖许可。

http_transport.dart、swift/SwiftBridge.swift、test/socket_matrix.dart、test/live_bridge_fixture.dart、run_socket.py 为闪寻新增。严格 HTTPS/POST 同源传输已接入显式 live CLI；默认系统根或来源绑定的已授权公开 CA，禁重定向、限制响应大小、取消及超时关闭实际底层 socket。本机 HTTPS 7 项和 Swift live 全链路见 EXP-03-socket-run-02-20261009；设备兼容性仍未执行。叶证书固定、证书批准 UI、真实 NAS 登录不在本轮交付。

## v0.5 追加：Source 级证书信任整合（EXP-04）

| 来源 | 目标 | 说明 |
| --- | --- | --- |
| EXP-04连接前置/pinning/native/TrustHTTP.swift | native/TrustHTTP.swift | 基于 pinning 原型（原 sha256 `1cc17cf00d925d91d47de8ec1d8da56292552ae4c59e8113c9bf5f50a7be165d`）移植；唯一改动是新增可选 `synoToken` 输入并设置为 `X-Syno-Token` 请求头（本机设备把 token 放 body 时返回 DSM 119）。改动后 sha256 `ac24a395b8915f2ee5019bdd5223886cb8e97251ed8b08b2b6a7702465394163`；证书行为未改，本机 30 项已重跑通过 |
| EXP-04连接前置/pinning/lib/source_trust.dart | lib/source_trust.dart | 移植 SourceEndpoint/CertificateCandidate/SourceTrustStore/SourcePinnedClient；package:crypto 的 sha256 换成项目内 lib/sha256.dart 纯 Dart 实现，移除未使用的 openssl SAN 解析，SHA-1 不再是身份依据 |
| 无上游等价 | lib/sha256.dart、lib/trust_paths.dart、lib/source_pinned_transport.dart、test/source_pin_driver.dart、run_sourcepin.py | 闪寻新增；路径解析、Transport 适配、证书事件建模、本机轮换证书 fixture |

MyNAS 上游代码不参与证书信任；原生助手只处理 HTTPS 与叶证书评估，DSM 业务仍在 Dart。未引入 dio/crypto 等 pub 依赖。本机验证证据收录在内部测试归档里（不随本包发布），此处只留结论。

真实搜索同样留有内部归档证据（不随本包发布）：（EXP-05/06 v0.1，13 项验收 12 项通过）；期间修改 `lib/core.dart`：取消令牌已取消时以取消原因决定对外状态，避免传输层 NetworkFailure 掩盖 timedOut/cancelled。

真实群晖设备上的验证（内部归档，不随本包发布）：DSM 7.2.2-72806 上证书信任、API.Info、普通账号 `demo_user` 登录、FileStation.Info、`/示例共享` 共享准入与目录读取、logout 均已通过（EXP-04 v0.2，9 项全过，EXP-05/06 解锁）。中途两处实机事实：CSRF 必须走 `X-Syno-Token` 头（放 body 返回 119），与 EXP-02 契约第 46 行的写法不一致，需修订契约；`SYNO.DSM.Info` 需登录会话才回答版本号（无凭据时 v2 返回 119）。


EXP-07 正式产品适配（2026-10-09，草案）：输入来自 EXP-03-run-09 的最新受测文件（不是旧commit回退）；完整冻结见 core-input-freeze-20261009.json。trust_paths仅改应用内AOT/helper与状态目录解析；SourcePinnedClient/TrustHTTP将原15/20/25秒内层预算改为显式requestTimeoutMs（范围1000–120000），保持原CSRF、来源叶证书验证、真实取消和DSM协议；core保留原生命周期，新增每查询预算快照、产品来源名及复用SMBLocation输出，产品禁止UnsupportedSearch自动目录遍历；harness轮询500ms并传入查询预算。无Flutter/pub依赖。MyNAS完整MIT、Dart运行时LICENSE/NOTICES随包保留。

正式入口及SynologyApi默认HTTP预算亦为30秒；每查询任务预算快照由search消息传入，默认60秒由Provider明确指定。Swift NAS结果先结构发布，SMB精确文件存在性检查在后台按每批3秒软预算执行，使用isMetadataUpdate刷新canOpen，不阻塞本地来源或把已完成查询重新标为搜索中；定位时仍再次安全核验。
