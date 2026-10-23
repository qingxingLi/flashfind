import XCTest
@testable import FlashFindCore

/// 搜索管线：多来源并发、取消、防抖，以及 NAS 结果的路径安全。
///
/// 全部用可脚本化的假 Provider / 假传输层驱动，不起进程、不连网络
/// （末尾一条除外，它要的是编译好的核心可执行文件）。
///
/// 锁的是「一次搜索从头到尾只有一个 queryID」这条链：迟到的旧事件、
/// 被取代的旧查询都必须被丢掉，否则界面会显示上一次的结果。

private let nasFixtureSource = SearchSource(id: "nas-fixture", name: "NAS 来源",
                                            type: .nas, displayName: "NAS 来源")

private func nasFixtureConfig() -> NASSourceConfig {
    NASSourceConfig(id: nasFixtureSource.id, name: nasFixtureSource.name, vendor: .synology,
                    host: "192.168.1.96", port: 5001, username: "nasuser", scope: "/示例共享")
}

/// 测试闸门：让「取消发生在批次到达之前」变成**确定的顺序**，而不是靠 sleep 赌调度。
///
/// 为什么需要：CI 的 macOS runner 负载高，`sleep(10ms)` 完全可能拖到 60ms 之后才醒，
/// 于是批次先到、取消后到，用例断言「迟到批次被丢掉」时看到非空事件就红了。
/// 这类红跟产品无关，但会挡住发布——而且只在 CI 出现，本机永远复现不了。
///
/// 所以让假 Provider 在**发事件之前**停下来等人放行：测试先确认它已停在闸门前、
/// 再取消、最后放行，迟到批次一定是在取消之后才发出的。
@MainActor private final class ScriptGate {
    private(set) var arrived = false
    var open = false

    func enterAndWait() async {
        arrived = true
        for _ in 0..<20_000 {
            if open { return }
            await Task.yield()          // 让出主线程，测试才能继续跑
        }
    }
}

@MainActor private final class ScriptProvider: SearchProvider {
    let source:SearchSource
    var delay:UInt64
    var fail:Bool
    /// 给了闸门就等它放行再发事件（见 `ScriptGate` 的说明）。
    var gate:ScriptGate?
    var cancelled=[UUID]()
    init(_ source:SearchSource,delay:UInt64=0,fail:Bool=false) { self.source=source;self.delay=delay;self.fail=fail }
    func cancel(queryID:UUID) { cancelled.append(queryID) }
    func search(_ text:String,queryID:UUID,emit:@escaping @MainActor(ProviderEvent)->Void) async {
        try? await Task.sleep(nanoseconds:delay)
        if let gate { await gate.enterAndWait() }
        // Deliberately emit even after cancellation to challenge Coordinator guards.
        emit(ProviderEvent(queryID:queryID,sourceID:source.id,results:fail ? [] : [SearchResult(id:source.id+text,name:text,relativePath:"/fixture/"+text,sourceID:source.id,sourceName:source.name,kind:"file",size:nil,localURL:nil)],state:fail ? .failed : .completed))
    }
}
@MainActor private final class FixtureBridge: MyNASBridgeTransport {
    var requests=[String](), messages=[[String:Any]]()
    var state="completed",error:String?,files=[[String:Any]]()
    func request(_ command:String,sourceID:String,queryID:String,fields:[String:Any],event:(([String:Any])->Void)?) async throws -> [String:Any] {
        requests.append(command);messages.append(fields)
        if command=="discover" { return ["event":"capabilities"] }
        if command=="login" { return ["event":"authState","state":"scopeReady"] }
        if command=="search" {
            event?(["event":"batch","sourceID":sourceID,"queryID":queryID,"files":files])
            var m:[String:Any]=["resultState":state,"isComplete":state=="completed"]
            if let error { m["error"]=["kind":error] };return m
        }
        return ["event":"controlAck"]
    }
}

final class NASSearchPipelineTests:XCTestCase {
    @MainActor func testFastLocalDoesNotWaitForNASAndNASFailureRetainsLocal() async {
        let local=ScriptProvider(.local),nas=ScriptProvider(nasFixtureSource,delay:150_000_000,fail:true),c=SearchCoordinator(providers:[local,nas])
        var events=[ProviderEvent]();c.search("资料") { events.append($0) }
        try? await Task.sleep(nanoseconds:50_000_000)
        XCTAssertEqual(events.map(\.sourceID),["local_mac"])
        try? await Task.sleep(nanoseconds:180_000_000)
        XCTAssertEqual(events.flatMap(\.results).count,1);XCTAssertEqual(events.last?.state,.failed)
    }
    @MainActor func testFastNASDoesNotWaitForLocalAndLocalFailureRetainsNAS() async {
        let local=ScriptProvider(.local,delay:150_000_000,fail:true),nas=ScriptProvider(nasFixtureSource),c=SearchCoordinator(providers:[local,nas])
        var events=[ProviderEvent]();c.search("odoo") { events.append($0) }
        try? await Task.sleep(nanoseconds:50_000_000)
        XCTAssertEqual(events.first?.sourceID,nasFixtureSource.id)
        try? await Task.sleep(nanoseconds:180_000_000)
        XCTAssertEqual(events.flatMap(\.results).count,1);XCTAssertEqual(events.last?.state,.failed)
    }
    @MainActor func testNewQueryRejectsDeliberatelyLateOldEvents() async {
        let p=ScriptProvider(.local,delay:80_000_000),c=SearchCoordinator(providers:[p]);var old=[ProviderEvent](),new=[ProviderEvent]()
        let first=c.search("旧") { old.append($0) };try? await Task.sleep(nanoseconds:10_000_000)
        let second=c.search("新") { new.append($0) }
        // ★ 等待窗口必须覆盖**两段**：旧查询还要跑完它剩下的 ~70 ms，新查询才被放
        //   进 provider，然后它自己也要 80 ms。旧实现在取消时立刻清空槽位，新查询
        //   会马上并行开跑，所以 120 ms 就够——但那是「同一来源两个活跃请求」，
        //   正是 §1.6 要禁止的。这里等 200 ms 是为了等正确的串行行为。
        try? await Task.sleep(nanoseconds:200_000_000)
        XCTAssertTrue(old.isEmpty);XCTAssertEqual(new.map(\.queryID),[second]);XCTAssertTrue(p.cancelled.contains(first));XCTAssertNotEqual(first,second)
    }
    /// 防抖：连续输入 `o`→`od`→`odoo` 只应产生一次 NAS 查询，而本地来源每次都立即执行。
    ///
    /// 防抖**不是**为规避设备退化，而是避免无谓的远端请求：
    /// 每敲一个字母都往 NAS 发一次查询，用户拿不到更多结果，设备却要多跑两轮。
    @MainActor func testDebounceCollapsesRemoteCallsButKeepsLocalImmediate() async {
        let local=ScriptProvider(.local),nas=ScriptProvider(nasFixtureSource)
        let c=SearchCoordinator(providers:[local,nas])
        var events=[ProviderEvent]()
        c.searchDebounced("o") { events.append($0) }
        try? await Task.sleep(nanoseconds:80_000_000)
        // 本地不等防抖窗口就已经出结果。
        XCTAssertFalse(events.filter { $0.sourceID=="local_mac" }.isEmpty)
        let localAfterFirst = events.filter { $0.sourceID=="local_mac" }.count
        c.searchDebounced("od") { events.append($0) }
        c.searchDebounced("odoo") { events.append($0) }
        try? await Task.sleep(nanoseconds:900_000_000)
        // 本地每次输入都执行。
        XCTAssertGreaterThan(events.filter { $0.sourceID=="local_mac" }.count, localAfterFirst)
        // NAS 只在最后一次输入后触发一次。
        XCTAssertEqual(events.filter { $0.sourceID==nasFixtureSource.id }.count, 1)
        // 被取代的旧查询要取消，但**只取消真正提交过的那一份**。
        //
        // 旧实现（P3 之前）在 `supersede` 里对全部 provider 无条件 cancel，
        // 于是防抖窗口内被丢掉的那次输入也会产生一条取消记录 → 这里是 2。
        // P3 改成按 owner 记「上一轮真正提交的 queryID」，变成 1——但那个 1 仍然
        // 是**广播**：`o` 那一轮的 queryID 被发给 NAS，而 NAS 从头到尾没收到过
        // 任何 search（它在 600 ms 防抖窗口内就被 `od` 取代了）。
        //
        // 现在取消只作用于 running / cancelling / queues 里**真实存在**的条目，
        // 所以对 NAS 的取消是 **0**：这条 provider 上根本没有它的请求。
        // 这不是退化——`provider.cancel` 不保证幂等，给一个从未发出的查询发取消
        // 既没有意义，还会让「取消了几次」的诊断计数变脏。
        XCTAssertEqual(nas.cancelled.count, 0)
    }
    /// 回车提交走 search()，必须立即发起，不等防抖窗口。
    @MainActor func testImmediateSearchSkipsDebounce() async {
        let nas=ScriptProvider(nasFixtureSource),c=SearchCoordinator(providers:[nas])
        var events=[ProviderEvent]()
        c.search("odoo") { events.append($0) }
        try? await Task.sleep(nanoseconds:120_000_000)
        XCTAssertEqual(events.count, 1)
        // 首次提交不应触发取消
        XCTAssertEqual(nas.cancelled.count, 0)
    }
    /// 路径边界：跨共享与路径穿越都必须被拒绝，且不得泄漏候选挂载路径。
    ///
    /// 这三道防护是 Finder 打开的安全基础：
    /// 来源校验 + RelativePath.validate + 解析后仍在挂载根之下。
    @MainActor func testFinderPathBoundaryRejectsTraversalAndForeignShare() async throws {
        let provider = NASSearchProvider(bridge: FixtureBridge(), config: nasFixtureConfig(), port: 5001)
        let foreign = SearchResult(id: "x", name: "p", relativePath: "/etc/passwd",
                                   sourceID: nasFixtureSource.id, sourceName: "NAS 来源",
                                   kind: "file", size: nil, localURL: nil)
        do { _ = try await provider.verifiedFileURL(foreign); XCTFail("跨共享必须拒绝") } catch {}
        let traversal = SearchResult(id: "y", name: "p", relativePath: "/示例共享/../../etc/passwd",
                                     sourceID: nasFixtureSource.id, sourceName: "NAS 来源",
                                     kind: "file", size: nil, localURL: nil)
        do { _ = try await provider.verifiedFileURL(traversal); XCTFail("路径穿越必须拒绝") } catch {}
        let other = SearchResult(id: "z", name: "p", relativePath: "/示例共享/a.txt",
                                 sourceID: "local_mac", sourceName: "本机",
                                 kind: "file", size: nil, localURL: nil)
        do { _ = try await provider.verifiedFileURL(other); XCTFail("非本来源必须拒绝") } catch {}
    }
    /// 结果解析只接受授权共享下的规范路径，并拒绝含NUL 的路径。
    @MainActor func testResultParserRejectsOutOfScopeRows() {
        let provider = NASSearchProvider(bridge: FixtureBridge(), config: nasFixtureConfig(), port: 5001)
        let outside: [String: Any] = ["path": "/home/other/secret.txt", "name": "s", "id": "a",
                        "sourceID": nasFixtureSource.id, "fileType": "file"]
        XCTAssertNil(provider.result(outside), "授权共享外的路径必须丢弃")
        // 含 NUL 的路径（JSON 中编码为 \u0000）
        let nul: [String: Any] = ["path": "/示例共享/a\u{0000}b.txt", "name": "n", "id": "b",
                                  "sourceID": nasFixtureSource.id, "fileType": "file"]
        XCTAssertNil(provider.result(nul), "含 NUL 的路径必须丢弃")
        let eaDir: [String: Any] = ["path": "/示例共享/子/@eaDir/x", "name": "d", "id": "c",
                     "sourceID": nasFixtureSource.id, "fileType": "folder"]
        XCTAssertNil(provider.result(eaDir), "@eaDir 伪影目录必须丢弃")
        let ok: [String: Any] = ["path": "/示例共享/odoo项目资料/odoo.txt", "name": "odoo.txt", "id": "d",
                  "sourceID": nasFixtureSource.id, "fileType": "file", "size": 1318]
        XCTAssertNotNil(provider.result(ok), "正常结果必须保留")
    }
    /// 取消之后才到的批次必须被丢掉。
    ///
    /// 顺序由闸门**保证**（见 `ScriptGate`），不再用 sleep 时长赌调度：
    /// ① 假 Provider 停在闸门前 → ② 取消 → ③ 放行，批次此刻才发出。
    @MainActor func testCancelRejectsDelayedBatches() async {
        let p=ScriptProvider(.local),gate=ScriptGate(),c=SearchCoordinator(providers:[p])
        p.gate=gate
        var events=[ProviderEvent]()
        let id=c.search("odoo") { events.append($0) }
        var spins=0
        while !gate.arrived && spins<20_000 { spins+=1; await Task.yield() }
        XCTAssertTrue(gate.arrived, "假 Provider 没有进到闸门前，用例前提不成立")
        c.cancel()
        gate.open=true                              // 迟到批次现在才发
        try? await Task.sleep(nanoseconds:20_000_000)
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(p.cancelled,[id])
    }
    @MainActor func testSingleCharacterBlocksOnlyNAS() async throws {
        let bridge=FixtureBridge(),nas=NASSearchProvider(bridge:bridge,config:nasFixtureConfig(),port:5001),local=ScriptProvider(.local),c=SearchCoordinator(providers:[nas,local]);var events=[ProviderEvent]()
        c.search("e") { events.append($0) };try? await Task.sleep(nanoseconds:40_000_000)
        XCTAssertEqual(events.first(where:{$0.sourceID==nas.source.id})?.state,.blocked)
        XCTAssertEqual(events.first(where:{$0.sourceID==local.source.id})?.results.count,1)
        XCTAssertFalse(bridge.requests.contains("search"))
    }
    @MainActor func testLegalZeroCompletesWithoutDegradationAndSeparateBudgets() async throws {
        let b=FixtureBridge(),p=NASSearchProvider(bridge:b,config:nasFixtureConfig(),port:5001);_=try await p.discover();try await p.login(account:"fixture",password:"fixture-only")
        var events=[ProviderEvent]();await p.search("zzz不存在xyz",queryID:UUID()) { events.append($0) }
        XCTAssertEqual(events.last?.state,.completed);XCTAssertTrue(events.last?.isTerminal==true)
        XCTAssertEqual(b.messages[0]["requestBudgetMs"] as? Int,30_000);XCTAssertEqual(b.messages[0]["queryBudgetMs"] as? Int,60_000)
        _=try await p.discover();XCTAssertEqual(b.requests.filter{$0=="discover"}.count,1)
    }
    @MainActor func testTimeoutIsDistinctAndEntersCooldownWithoutFallback() async throws {
        let b=FixtureBridge(),p=NASSearchProvider(bridge:b,config:nasFixtureConfig(),port:5001);_=try await p.discover();try await p.login(account:"fixture",password:"fixture-only");b.state="timedOut"
        var events=[ProviderEvent]();await p.search("资料",queryID:UUID()) { events.append($0) };XCTAssertEqual(events.last?.state,.timedOut)
        await p.search("odoo",queryID:UUID()) { events.append($0) };XCTAssertEqual(events.last?.state,.degraded)
        XCTAssertEqual(b.requests.filter{$0=="search"}.count,1);XCTAssertFalse(b.requests.contains("list"))
    }
    @MainActor func testCooldownAllowsOneLaterSuccessfulRetry() async throws {
        var time=Date(timeIntervalSince1970:1000)
        let b=FixtureBridge(),p=NASSearchProvider(bridge:b,config:nasFixtureConfig(),port:5001,now:{time});_=try await p.discover();try await p.login(account:"fixture",password:"fixture-only")
        b.state="timedOut";var events=[ProviderEvent]();await p.search("资料",queryID:UUID()) { events.append($0) }
        await p.search("资料",queryID:UUID()) { events.append($0) };XCTAssertEqual(b.requests.filter{$0=="search"}.count,1)
        time=time.addingTimeInterval(16);b.state="completed";await p.search("资料",queryID:UUID()) { events.append($0) }
        XCTAssertEqual(events.last?.state,.completed);XCTAssertEqual(b.requests.filter{$0=="search"}.count,2)
    }
    @MainActor func testMalformedEvidenceThenEmptyIsSuspectedWithoutTraversal() async throws {
        var time=Date(timeIntervalSince1970:1000)
        let b=FixtureBridge(),p=NASSearchProvider(bridge:b,config:nasFixtureConfig(),port:5001,now:{time});_=try await p.discover();try await p.login(account:"fixture",password:"fixture-only")
        b.state="failed";b.error="ProtocolViolation";var events=[ProviderEvent]();await p.search("资料",queryID:UUID()) { events.append($0) }
        time=time.addingTimeInterval(16);b.state="completed";b.error=nil;await p.search("资料",queryID:UUID()) { events.append($0) }
        XCTAssertEqual(events.last?.state,.degraded);XCTAssertFalse(b.requests.contains("list"))
    }
    @MainActor func testUnknownMetadataAndUnsafeNASPath() {
        let p=NASSearchProvider(bridge:FixtureBridge(),config:nasFixtureConfig(),port:5001)
        let m:[String:Any]=["id":"test","name":"not-present.txt","path":"/示例共享/not-present.txt","fileType":"text","sourceID":p.source.id]
        let row=p.result(m);XCTAssertNil(row?.size);XCTAssertNil(row?.modifiedDate);XCTAssertEqual(row?.canOpen,false);XCTAssertEqual(row?.sourceType,.nas)
        var bad=m;bad["path"]="/示例共享/../secret";XCTAssertNil(p.result(bad));bad["path"]="/other/file";XCTAssertNil(p.result(bad))
    }
    /// AOT 核心的取消与分页：被取消的查询不许再吐结果，后续查询不受影响。
    ///
    /// 这是唯一一条跑**真核心进程**的用例（mock 传输层在核心内部，不走网络）：
    /// 取消是否真的传达下去、分页是否按 `total` 收尾，只有真进程说了算。
    /// 握手顺序 `discover → login → selectScope` 一步都不能省：
    /// 登录与搜索范围是解耦的，少了 `selectScope` 核心会回 `needsAuth`。
    ///
    /// 核心可执行文件是 `scripts/build.sh core` 的产物，不进版本控制；
    /// 缺产物就跳过——没有产物却让它「通过」，等于假装验过一条真协议路径。
    @MainActor func testCancelledQueryYieldsNoBatchesAndNextQueryCompletes() async throws {
        guard let root = coreResourceRoot() else { throw XCTSkip("缺少已编译的 MyNAS 核心，先跑 scripts/build.sh core") }
        let stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ff2-mock-bridge-\(UUID().uuidString)", isDirectory: true)
        let bridge=MyNASProcessBridge(executable:root.appendingPathComponent("bin/mynas-core"),stateDirectory:stateDirectory)
        defer { bridge.shutdown(); try? FileManager.default.removeItem(at: stateDirectory) }
        var protocolEvents=[[String:Any]]();bridge.observeProtocol={protocolEvents.append($0)}
        let discovered=try await bridge.command("discover",sourceID:nasFixtureSource.id,fields:["mode":"mock","vendor":"synology","endpoint":"https://192.168.1.96:5001","scope":"/允许共享","mockCount":451,"mockDelayMs":100])
        XCTAssertEqual(discovered["mockOnly"] as? Bool,true)
        _=try await bridge.command("login",sourceID:nasFixtureSource.id,fields:["account":"fixture","password":"fixture-only"])
        _=try await bridge.command("selectScope",sourceID:nasFixtureSource.id,fields:["scopes":["/允许共享"]])
        let a=UUID().uuidString,b=UUID().uuidString;var oldCount=0,nextCount=0
        let task=Task { try await bridge.command("search",sourceID:nasFixtureSource.id,queryID:a,fields:["query":"资料"]) { m in oldCount += (m["files"] as? [Any])?.count ?? 0 } }
        try? await Task.sleep(nanoseconds:50_000_000)
        _=try await bridge.command("cancel",sourceID:nasFixtureSource.id,queryID:a)
        let next=try await bridge.command("search",sourceID:nasFixtureSource.id,queryID:b,fields:["query":"odoo"]) { m in nextCount += (m["files"] as? [Any])?.count ?? 0 }
        let old=try await task.value
        XCTAssertEqual(oldCount,0);XCTAssertEqual(nextCount,451)
        XCTAssertEqual(next["resultState"] as? String,"completed");XCTAssertEqual(next["cleanupState"] as? String,"cleaned");XCTAssertEqual(next["reportedTotal"] as? Int,451)
        XCTAssertEqual(old["resultState"] as? String,"cancelled");XCTAssertEqual(old["cleanupState"] as? String,"cleaned")
        _=try await bridge.command("disconnect",sourceID:nasFixtureSource.id)
    }
}

/// 已编译核心的资源根：优先用 `FF_MYNAS_RESOURCE_ROOT`，否则退回 `Resources/MyNAS`。
private func coreResourceRoot() -> URL? {
    if let path = ProcessInfo.processInfo.environment["FF_MYNAS_RESOURCE_ROOT"] {
        return URL(fileURLWithPath: path)
    }
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // FlashFindCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // client
        .appendingPathComponent("Resources/MyNAS")
    let binary = root.appendingPathComponent("bin/mynas-core")
    guard FileManager.default.fileExists(atPath: binary.path) else { return nil }
    return root
}
