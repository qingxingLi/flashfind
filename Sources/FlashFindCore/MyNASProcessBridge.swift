import Foundation

/// Swift owns the process/control channel; all DSM protocol work remains in bundled Dart.
@MainActor public protocol MyNASBridgeTransport: AnyObject {
    func request(_ command:String,sourceID:String,queryID:String,fields:[String:Any],event:(([String:Any])->Void)?) async throws -> [String:Any]
    /// 核心进程的**代次**；核心每重启一次 +1，只增不减。
    ///
    /// 调用方（Provider）记住自己是在第几代上连好的，代次一变就说明
    /// 「我连的那个进程已经不在了」，登录态必然失效。
    /// 不提供这个能力的传输层返回 0 —— 语义是「永不自行重启」，
    /// 因此代次恒定、不会把健康的连接误判成失效。
    var processGeneration: Int { get }
    /// 协议观测转发（诊断、核心版本不一致提示）。
    ///
    /// 带默认空实现，测试替身不必实现它 —— 但**真桥接层必须挂上**，
    /// 否则核心报上来的版本不一致、协议错误全被静默丢掉。
    var observeProtocol: (([String: Any]) -> Void)? { get set }
    /// 关闭底层进程。带默认空实现：不管理进程的传输层没有可关的东西。
    func shutdown()
}
public extension MyNASBridgeTransport {
    /// 默认实现：不具备代次概念的传输层视为「永不自行重启」。
    var processGeneration: Int { 0 }
    /// 默认空实现。只有真正管理进程的桥接层才有可观测的协议事件。
    var observeProtocol: (([String: Any]) -> Void)? {
        get { nil }
        set { }
    }
    func shutdown() {}

    func command(_ command:String,sourceID:String,queryID:String="none",fields:[String:Any]=[:],event:(([String:Any])->Void)?=nil) async throws -> [String:Any] {
        try await request(command,sourceID:sourceID,queryID:queryID,fields:fields,event:event)
    }
}
@MainActor public final class MyNASProcessBridge: MyNASBridgeTransport {
    public var observeProtocol: (([String:Any])->Void)?
    private let executable: URL
    private let stateDirectory: URL
    private var process: Process?
    private var input: FileHandle?
    private var pending: [String: CheckedContinuation<[String:Any],Error>] = [:]
    private var commands: [String:String] = [:]
    private var events: [String: ([String:Any])->Void] = [:]
    /// 实际启动的可执行文件。构建期 `swift build` 不会把资源放进产物，
    /// 因此实际路径可能与传入值不同，启动时再定位一次。
    private var resolvedExecutable: URL?

    /// 核心进程的**代次**。只要「旧进程没了 / 新进程起来了」就 +1，只增不减。
    ///
    /// 为什么需要它：核心一重启，进程里的 `sources` 与 `session` 就全空了，
    /// 但 Swift 这边的 `NASSearchProvider.ready` 仍是 `true`。
    /// 于是下一刀搜索会发给一个**根本没有这个 source** 的新核心，
    /// 表现是「界面说已连接，搜索却必失败」，而且不会自动恢复。
    /// 有了代次，Provider 只要比对「我是在第几代连上的」就能立刻知道自己已经失效。
    public private(set) var processGeneration: Int = 0

    /// 产品代码走这个：看门狗时长取默认值（180 秒）。
    ///
    /// ★ 刻意保留这个双参数形式而不是给 `init` 加一个带默认值的第三参数：
    /// 后者的 Swift 符号是 `init(executable:stateDirectory:watchdogSeconds:)`，
    /// 双参数的旧符号当场消失，未重编的调用方（例如 `AppModel.swift.o`）
    /// 会在链接期报 `Undefined symbols`。新增一个重载没有这个代价。
    public convenience init(executable: URL, stateDirectory: URL) {
        self.init(executable: executable, stateDirectory: stateDirectory, watchdogSeconds: 180)
    }
    /// 看门狗时长（秒）。取核心查询预算之上，覆盖「网络慢」与「事件漏认」两种情况。
    ///
    /// 做成可注入的，是为了让测试能把 180 秒压到 1 秒 —— 否则这条分支在快速回归里
    /// **永远跑不到**： 第三方审核（OSS-06）指出，跨线程访问看门狗正是
    /// 靠「没人真等到 180 秒」藏住的。压不下来就测不了，测不了就只能靠源码包含断言，
    /// 而那证明不了线程隔离。
    public init(executable: URL, stateDirectory: URL, watchdogSeconds: Double) {
        self.executable = executable
        self.stateDirectory = stateDirectory
        self.watchdogSeconds = watchdogSeconds
    }
    private let watchdogSeconds: Double
    /// 按候选顺序定位可执行文件：优先传入值，其次包内资源目录，
    /// 最后开发期的源码树（tools/install-mynas-core.sh 的产物）。
    private func locateExecutable() -> URL? {
        if FileManager.default.isExecutableFile(atPath:executable.path) { return executable }
        var roots: [URL] = []
        if let resources = Bundle.main.resourceURL { roots.append(resources) }
        roots.append(Bundle.main.bundleURL)
        // Bundle.main.bundleURL 可能是 .build 下的裸可执行文件，
        // 逐级向上找到工程根再拼 MyNASCore/Resources。
        var probe = Bundle.main.bundleURL
        for _ in 0..<8 {
            probe.deleteLastPathComponent()
            let candidate = probe.appendingPathComponent("Resources/MyNAS/bin/mynas-core")
            if FileManager.default.isExecutableFile(atPath:candidate.path) { return candidate }
            let nested = probe.appendingPathComponent("client/Resources/MyNAS/bin/mynas-core")
            if FileManager.default.isExecutableFile(atPath:nested.path) { return nested }
        }
        return roots.compactMap { root in
            let candidate = root.appendingPathComponent("MyNAS/bin/mynas-core")
            return FileManager.default.isExecutableFile(atPath:candidate.path) ? candidate : nil
        }.first
    }
    public func start() throws {
        if process?.isRunning == true { return }
        guard let binary = resolvedExecutable ?? locateExecutable() else { throw FlashFindError.message("应用缺少 MyNAS 搜索资源，请重新构建") }
        resolvedExecutable = binary
        try FileManager.default.createDirectory(at:stateDirectory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let p=Process(),i=Pipe(),o=Pipe(),e=Pipe()
        p.executableURL=binary;p.arguments=[]
        // 凭据只经stdin 管道传入，不放 argv、不放环境变量。
        p.environment=["PATH":"/usr/bin:/bin","LANG":"en_US.UTF-8","FF2_TRUST_DIR":stateDirectory.path]
        p.standardInput=i;p.standardOutput=o;p.standardError=e
        // ★ terminationHandler 必须认**是哪个进程**退了。
        //
        // 旧写法是 `{ [weak self] _ in Task { @MainActor in self?.failed() } }`：
        // 进程 A 退出 → handler 排队等 MainActor → 这时候新的搜索已经起了进程 B
        // → A 的 handler 才执行 → `failed()` 把**进程 B** 的状态清掉。
        // 这类竞态偶发、不能稳定复现，表现是「某次搜索后突然全部失效，
        // 重开应用就好了」——正是最难查的那一类。
        //
        // 这里记的是进程的**身份**，不是进程本身（不持有引用，避免影响生命周期）。
        let identity = ObjectIdentifier(p)
        p.terminationHandler={ [weak self] _ in
            Task { @MainActor in
                guard let self, let current = self.process, ObjectIdentifier(current) == identity else { return }
                self.failed()
            }
        }
        try p.run(); process=p;input=i.fileHandleForWriting
        processGeneration += 1
        // ★ 读循环必须记下自己属于**哪一代**核心（OSS-07）。
        //
        // 旧写法只把「这一行」投给 MainActor，不带任何来源信息。于是进程 A 退出、
        // 进程 B 起来之后，A 的读循环早就排到主线程队列里的那几行仍会送达，
        // 而 `received` 里一行畸形输出就会调 `abortAll` / `terminateHelper`，
        // 把**新**核心连同它的连接与正在进行的搜索一起结束掉。
        // 靠 requestID 挡不住：协议损坏恰好是在做 requestID 校验**之前**判定的。
        //
        // 这里用代次而不是 `ObjectIdentifier(process)`：进程对象释放后地址可能被
        // 新进程复用，身份比对会假通过；而代次只增不减，且「旧进程退 / 新进程起 /
        // 主动拆核心」三条路各 +1，捕获时的代次等于当前代次 ⇔ 输出仍来自当前核心。
        let generation = processGeneration
        DispatchQueue.global().async { [weak self] in
            var buffered=Data()
            while true {
                let bytes=o.fileHandleForReading.availableData
                if bytes.isEmpty { break }
                buffered.append(bytes)
                while let index=buffered.firstIndex(of:10) {
                    let line=Data(buffered[..<index]);buffered.removeSubrange(...index)
                    // 超大行同样属于「通道已损坏」：沉默跳过就可能丢掉某个请求的终止事件。
                    if line.count > 2_000_000 {
                        Task { @MainActor [weak self] in
                            guard let self, self.stillCurrent(generation) else { return }
                            self.protocolCorruption("核心输出的一行超过 2 MB")
                        }
                        continue
                    }
                    Task { @MainActor [weak self] in
                        guard let self, self.stillCurrent(generation) else { return }
                        self.received(line)
                    }
                }
                // 缓冲区一直等不到换行符，说明核心在胡乱输出。
                // 旧写法是 `break`：读循环静默退出，之后所有请求都只能等看门狗。
                if buffered.count > 2_000_000 {
                    Task { @MainActor [weak self] in
                        guard let self, self.stillCurrent(generation) else { return }
                        self.protocolCorruption("核心输出没有换行分隔，已超过 2 MB")
                    }
                    break
                }
            }
        }
        // Never retain, log or forward raw helper stderr.
        DispatchQueue.global().async { while !e.fileHandleForReading.availableData.isEmpty {} }
    }
    /// 这一代核心还活着吗 —— 读循环投递任何东西之前都要先问一句（OSS-07）。
    ///
    /// `received` 与 `protocolCorruption` 都只在当前这一代上才允许生效：
    /// 旧代的一行畸形输出若被放进来，它会 `abortAll` 掉**新**核心上所有在等的请求，
    /// 甚至 `terminateHelper` 把新核心直接送走 —— 而用户看到的是「刚连上又断了」。
    private func stillCurrent(_ generation: Int) -> Bool { generation == processGeneration }

    /// 让所有在等的请求立刻失败，并清掉它们的看门狗。
    ///
    /// 单独抽出来是因为「进程没了」「版本不一致」「协议被污染」三种原因
    /// 都要做同一件事，但给出去的**原因**不同——原因必须准确，否则用户无从下手。
    private func abortAll(_ error: FlashFindError) {
        let waits=pending;pending.removeAll();events.removeAll();commands.removeAll()
        // 进程没了，所有看门狗都失去意义，清掉避免它们空转到点。
        for task in watchdogs.values { task.cancel() }
        watchdogs.removeAll()
        for c in waits.values { c.resume(throwing:error) }
    }

    private func failed() {
        input=nil;process=nil
        didCheckRevision=false
        // 进程换了一代：任何「在旧进程上连上的来源」此刻都已经失效。
        processGeneration += 1
        abortAll(.message("MyNAS 搜索进程已断开"))
    }

    /// 主动拆掉核心进程（版本不一致 / 协议被污染时用）。
    ///
    /// 不再继续通讯：协议字段已经对不上，继续下去只会等到 180 秒看门狗，
    /// 或者更糟——拿到一份错位的数据当成正常结果。
    private func terminateHelper() {
        let doomed = process
        input=nil;process=nil
        didCheckRevision=false
        processGeneration += 1
        doomed?.terminate()
    }
    /// 与核心约定的协议修订号。改协议时与 Dart 侧 `coreRevision` 一起加一。
    ///
    /// 3 —— `resultState` 新增 `deviceBusy`（设备未就绪，可重试的中间态），
    ///      结果事件新增 `unparsedCount`。旧核心不会发出这两个字段，
    ///      新版客户端遇到旧核心必须明确报错，而不是把 `deviceBusy` 当成
    ///      未知状态退化成 failed。
    /// 4 —— 结果事件新增 `duplicateCount`（设备重复返回、已被核心合并的条数）。
    ///      同样是「旧核心不会发」的可选字段：缺了就按 0 处理，不影响读取。
    /// 5 —— 错误事件新增 `reason`：适配器写好的中文原因不再被压成空洞的
    ///      `ProtocolViolation`；兜底分支改报 `UnexpectedFailure`。
    /// 6 —— 就绪判据补上另一半：`finished=false` 时的 `total` 是**还在涨的
    ///      中间数**，不是全集。
    ///      旧判据在中间态上放行 → 分页「total 一致性」断言必炸 →
    ///      界面报「设备返回的分页数据不完整（IncompleteResponse）」。
    ///      事件与字段没有增删，但同一输入的结果状态会变（失败 → 正常完成），
    ///      所以仍要升号。
    /// 7 —— `search` 命令新增**可选**字段 `roots`：把本次搜索限定到已授权
    ///      根的子集。缺它 ⇒ 行为与从前完全一致；带了它而旧核心不认识 ⇒
    ///      旧核心会忽略这个限定，表现为「界面显示了限定位置，设备却仍在
    ///      扫全部共享」——所以必须升号，否则这个失配会静默发生。
    public static let expectedCoreRevision = 7

    /// 是否已经核对过修订号（每个核心进程只核对第一条消息）。
    private var didCheckRevision = false

    /// 核对第一条消息上的协议修订号。
    ///
    /// 旧版核心不带 `coreRevision` → 视为不匹配并明确报出来。
    /// 这类「Swift 新版 + 核心旧版」的不同步，原本的表现是**登录毫无反应**：
    /// 请求写进去了，回过来的事件名对不上白名单，continuation 永远不恢复，
    /// 界面既不报错也不超时。有了这道检查，第一条消息就能说清楚。
    private func checkCoreRevisionOnce(_ m: [String: Any]) {
        guard !didCheckRevision else { return }
        didCheckRevision = true
        let actual = m["coreRevision"] as? Int
        guard actual != Self.expectedCoreRevision else { return }
        let actualText = actual.map(String.init) ?? "未知"
        observeProtocol?(["event": "coreRevisionMismatch",
                          "expected": Self.expectedCoreRevision,
                          "actual": actual ?? -1])
        // ★ 不匹配的代价不是「可能出错」，而是**一定**会出错且难以定位：
        // 事件名、字段名、终止条件都可能变了，Swift 会等一个永远不会来的事件，
        // 界面表现是「转圈三分钟然后超时」。所以这里必须立刻失败并拆掉进程，
        // 不再往下通讯。
        abortAll(.message("搜索核心与客户端版本不一致（客户端期望 \(Self.expectedCoreRevision)，核心是 \(actualText)）。请重新安装闪寻。"))
        terminateHelper()
    }

    /// 核心输出了一行我们读不懂的东西 —— 这是**协议被污染**，不是「可以忽略的一行」。
    ///
    /// 旧做法是 `return` / `continue`：那一行若是某个请求的终止事件，
    /// 这个请求就永远等不到头，只能靠 180 秒看门狗兜底。
    /// 用户看到的就是「搜索突然卡住，几分钟后才报失败」。
    private func protocolCorruption(_ reason: String) {
        observeProtocol?(["event": "protocolCorruption", "reason": reason])
        abortAll(.message("与搜索核心的通讯已损坏（\(reason)）。核心已重启，请重试一次。"))
        terminateHelper()
    }

    private func received(_ line: Data) {
        // 核心的每一行都是 `{'protocolVersion':1,'coreRevision':n,'requestID':…,'sourceID':…,
        // 'queryID':…,'event':…}`（见 `bin/harness.dart` 的 `send`）。
        // 因此「不是 JSON」或「缺信封字段」都不是可以跳过的一行，而是通道已损坏。
        guard let object = try? JSONSerialization.jsonObject(with:line) else {
            protocolCorruption("核心输出的一行不是合法 JSON")
            return
        }
        guard let m = object as? [String:Any] else {
            protocolCorruption("核心输出的一行不是 JSON 对象")
            return
        }
        guard m["protocolVersion"] as? Int == 1 else {
            protocolCorruption("核心输出的一行协议版本不是 1")
            return
        }
        guard let id = m["requestID"] as? String else {
            protocolCorruption("核心输出的一行缺少 requestID")
            return
        }
        checkCoreRevisionOnce(m)
        observeProtocol?(m)
        events[id]?(m)
        let event=m["event"] as? String ?? ""
        // 终止事件必须与 Dart 侧实际发出的 event 名称一一对应。
        // 这里踩过一次：Dart 把「登录成功」从 scopeReady 改成 authenticated、
        // 把「选共享」新增为 scopeState，而这个白名单还停在旧名字，
        // 于是 continuation 永不恢复——表现是「连接卡住」「选不了文件夹」，
        // 但底层其实早就返回了。
        let terminal:Set<String> = ["capabilities","trustState","scopeState","searchReturned","disconnected","cancelled","error","certificateTrustRequired"]
        let done = event == "terminal" || terminal.contains(event)
            || (event == "authState" && (m["state"] as? String == "authenticated" || m["state"] as? String == "scopeReady"))
            || event == "controlAck"
            || (event == "sourceState" && m["state"] as? String == "disconnected")
            || (event == "batch" && m["queryID"] as? String == "none")
        if done,let c=pending.removeValue(forKey:id) {
            watchdogs.removeValue(forKey:id)?.cancel()
            let command=commands.removeValue(forKey:id);events.removeValue(forKey:id)
            if event=="error" || (event=="terminal" && command != "search") {
                // 核心的失败要**整条**带出来，不能只留 kind。
                //
                // 只传 kind 时，适配器写好的那句原因（「无法连接 WebDAV 服务
                // （TLS 握手失败）」）在过桥的这一刻就没了 ——
                // 界面只能按 kind 猜，而 `AuthenticationFailed` 这个 kind
                // 既可能是密码错、也可能是协议不对，猜不出真因。
                let payload = m["error"] as? [String: Any]
                let kind = (payload?["kind"] as? String) ?? "NAS 请求失败"
                let reason = payload?["reason"] as? String
                let apiCode = payload?["apiCode"] as? Int
                c.resume(throwing: FlashFindError.coreFailure(kind: kind, reason: reason, apiCode: apiCode))
            }
            else { c.resume(returning:m) }
        }
    }
    public func request(_ command: String,sourceID: String,queryID: String="none",fields:[String:Any]=[:],event:(([String:Any])->Void)?=nil) async throws -> [String:Any] {
        try start(); let id=UUID().uuidString
        var m=fields;m["command"]=command;m["protocolVersion"]=1;m["requestID"]=id;m["sourceID"]=sourceID;m["queryID"]=queryID
        let data=try JSONSerialization.data(withJSONObject:m)+Data([10])
        return try await withCheckedThrowingContinuation { continuation in
            // 必须先确认 input 存在，再登记 continuation。
            // 原来的写法是「先登记 pending，再 input?.write」：核心若正好在这一刻退出，
            // input 为 nil，可选链把 write 整个跳过**且不抛错**，continuation 就永远不会被恢复
            // ——连接流程与搜索都会无限期停住，界面上既不报错也不超时。
            guard let input else {
                discard(id)
                continuation.resume(throwing:FlashFindError.message("NAS 控制通道已断开"))
                return
            }
            pending[id]=continuation;events[id]=event;commands[id]=command
            // 兜底超时。核心自带请求/查询预算，但那只管「还在跑」的情况；
            // 管不到「核心已经返回、只是我们没认出来」——例如事件白名单漏了某个名字。
            // 没有这道保险，一次协议不同步就会变成永久挂起。
            //
            // ★ 定时器必须落在 MainActor 上（OSS-06）：
            //   旧写法是 `let watchdog=DispatchWorkItem { self?.timeOut(id) }` +
            //   `DispatchQueue.global().asyncAfter(deadline:execute:)`，于是 180 秒后
            //   `timeOut(id)` 在**全局队列**上被调用，而它读写的
            //   `pending`/`watchdogs`/`commands`/`events` 全归 MainActor 所有。
            //   响应与超时同时到达时，两边就在同一本字典上并发读改 ——
            //   这不是「可能出错」而是未定义行为：轻则 continuation 漏恢复
            //   （请求永远挂住，界面转圈到天荒地老），重则重复恢复触发运行时崩溃。
            //   `Swift 5 模式编译通过` 从来不代表线程隔离正确。
            //
            //   `Task { }` 在这里创建，继承当前 MainActor 隔离；`Task.sleep` 到期后
            //   仍在 MainActor 上执行，取消也与 `discard`/`abortAll` 走同一套协调。
            let seconds = watchdogSeconds
            watchdogs[id] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.timeOut(id)
            }
            do { try input.write(contentsOf:data) } catch {
                discard(id)
                continuation.resume(throwing:FlashFindError.message("NAS 控制通道不可用"))
            }
        }
    }

    /// 在等响应的请求，各自挂一个兜底看门狗。
    ///
    /// 存放的是 `Task`（而不是 `DispatchWorkItem`）：超时回调必须在 MainActor 上跑，
    /// 见 `request` 里的说明。取消同样走 `Task.cancel()`。
    private var watchdogs: [String: Task<Void, Never>] = [:]

    /// 丢弃一个请求的所有痕迹（含看门狗），防止泄漏。
    private func discard(_ id: String) {
        watchdogs.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)
        events.removeValue(forKey: id)
        commands.removeValue(forKey: id)
    }

    /// 兜底超时触发：以可读错误结束等待，而不是让界面一直转圈。
    ///
    /// 只做一次终态：`pending` 里已经没有这个 id（响应先到了 / 已被 `abortAll` 清掉）
    /// 就直接返回。有了 MainActor 隔离，这一步与 `received` 的
    /// `pending.removeValue` 天然互斥，不会再出现「两个线程同时判定自己该恢复」。
    private func timeOut(_ id: String) {
        guard let stored = pending[id] else { return }
        // 让诊断日志看得见「这次失败是等出来的」：用户报「搜索卡住」时，
        // 协议日志里有这一条，就能把「核心根本没回话」与「我们没认出来」分开。
        observeProtocol?(["event": "watchdogFired", "requestID": id])
        discard(id)
        stored.resume(throwing:FlashFindError.message("NAS 没有响应（\(Int(watchdogSeconds)) 秒）。可在高级诊断里查看协议日志。"))
    }
    public func shutdown() { try? input?.close();input=nil }
}
