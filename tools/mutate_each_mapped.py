#!/usr/bin/env python3
"""逐条证红：一次只应用一条新变异，只跑对应的测试类。

`red_proof.py` 把两百多条变异一起打上去，只能证明「期望的用例都红了」；
它证明不了「这一条变异是被哪条用例抓住的」。新加的变异跨了多个文件、多个测试类，
`mutate_each.py` 的「一个文件一个类」不够用，所以这里按
「变异名 → 测试类 + 期望变红的用例」显式登记。

目前登记的是 Phase 5.5（SDK 装配层）与 Phase 6.1（Unix Socket 传输层）新增的变异。

用法（必须带 TOOLCHAINS，否则 require_swift_61 会先拦下来）：
    TOOLCHAINS=org.swift.612202505261a python3 tools/mutate_each_mapped.py
退出码 0 = 每条变异都让登记过的用例全部变红，且源码逐字节还原。
"""
import hashlib
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

CLIENT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(CLIENT / 'tools'))
import red_proof as rp  # noqa: E402

# 变异名 → (测试类, 期望变红的用例集合)
EXPECT = {
    '启动日志写进 stdout': (
        'MCPStdioTests', {'testStdoutCarriesOnlyProtocolFrames',
                          'testStartupWritesNothingButTheResponse'}),
    'tools/list 少一个 Tool': (
        'MCPHandlerTests', {'testToolsListIsExactlyTheCatalog',
                            'testEveryCatalogParameterIsCarriedIntoTheSchema'}),
    # 参数全丢不影响「成功正文原样返回」——那条由「结果正文被适配层改写」抓。
    '入参不翻译（全丢）': (
        'MCPHandlerTests', {'testCallToolForwardsTheToolNameAndRawArguments',
                            'testUnsupportedJSONTypesSurviveAsUnsupported'}),
    '错误码被抹平': (
        'MCPHandlerTests', {'testFailureIsNotAProtocolError',
                            'testLinkFailureCodeIsForwardedUnchanged'}),
    # v0.18 撤回 `facts`：这条变异换成它的当代形态——判定不读实时设置。
    '权限事实被写死为关闭': (
        'AuthorityServiceTests', {'testListSourcesReturnsOnlyAllowedSources',
                                  'testRevokingASourceTakesEffectOnTheNextRequest'}),
    '协议版本被手写': (
        'MCPBoundaryTests', {'testProtocolVersionIsNeverHardcoded'}),
    'limit 上限没进 schema': (
        'MCPHandlerTests', {'testEveryCatalogParameterIsCarriedIntoTheSchema'}),
    'SDK 渗进 Router': (
        'MCPBoundaryTests', {'testTheSDKIsImportedInExactlyThreeFiles',
                             'testBusinessLayersDoNotKnowTheSDK'}),
    'Router 说 JSON-RPC 错误号': (
        'MCPBoundaryTests', {'testTheRouterNeverSpeaksJSONRPC'}),
    '连不上执行端假装成功': (
        'MCPHandlerTests', {'testUnreachableLinkNeverPretendsToSucceed'}),

    # ---- Phase 6.1：Unix Socket 传输层（2026-10-20）----
    'IPC 目录权限放宽': (
        'AuthoritySocketTests', {'testDirectoryIsOwnerOnly'}),
    'socket 权限放宽': (
        'AuthoritySocketTests', {'testSocketIsOwnerOnly'}),
    '第二个实例抢走 socket': (
        'AuthoritySocketTests', {'testSecondInstanceDoesNotStealTheSocket'}),
    '探活失败也算活着': (
        'AuthoritySocketTests', {'testAConnectedButSilentSocketCountsAsStale'}),
    '请求上限不生效': (
        'AuthoritySocketTests', {'testOversizedRequestIsRejected'}),
    '读空闲超时不生效': (
        'AuthoritySocketTests', {'testIdleConnectionIsClosed'}),
    '响应上限不生效': (
        'AuthoritySocketTests', {'testOversizedResponseBecomesAnError'}),
    '总预算不生效': (
        'AuthoritySocketTests', {'testSlowAuthorityTimesOut'}),
    '响应不回原 id': (
        'AuthoritySocketTests', {'testResponseEchoesTheRequestID'}),
    # 6.2 的反向错误：App 相信报文里的 source_ids。
    # 只能由「另一个进程伪造来源」那条抓——它是唯一绕过助手直连 socket 的用例。
    'App 相信报文里的 source_ids': (
        'AuthorityServiceTests', {'testForgedSourceIDsFromAnotherProcessAreStillDenied'}),
    # `source_ids: null` 被丢掉之后，App 会把它当成「没传」。往返属性测试是唯一
    # 能在「两侧映射各写一份」的情况下抓住它的用例。
    'null 参数被当成没传': (
        'AuthorityWireTests', {'testArgumentMappingSurvivesTheWireRoundTrip'}),
    '整数解成 double': (
        'AuthorityWireTests', {'testIntegersStayIntegers'}),
    '没有正文也算成功': (
        'AuthorityWireTests', {'testMissingResultIsNotASuccess'}),
    # ---- Phase 6.2：权限判定收回 App authority（2026-10-20）----
    '设置不现读（用默认值）': (
        'AuthorityServiceTests', {'testListSourcesReturnsOnlyAllowedSources',
                                  'testRevokingASourceTakesEffectOnTheNextRequest'}),
    # 注意：排序那条用例里三个来源**全部**已授权，所以它抓不到这条变异（实测 MISS 过一次）。
    '未授权来源也出现在 list_sources': (
        'AuthorityServiceTests', {'testUnauthorizedSourceNeverAppearsInListSources',
                                  'testListSourcesReturnsOnlyAllowedSources'}),
    'list_sources 不排序': (
        'AuthorityServiceTests', {'testListSourcesIsSortedBySourceID'}),
    '每请求判两次权限': (
        'AuthorityServiceTests', {'testRoutingHappensExactlyOncePerRequest'}),
    '未知 op 回 invalid_argument': (
        'AuthoritySocketTests', {'testUnknownOperationIsRejectedAsUnknownTool'}),
    '助手又引用了 Router': (
        'MCPBoundaryTests', {'testHelperSourcesDoNotReferencePermissionOrRouting'}),
    '报文层重新带上授权范围': (
        'MCPBoundaryTests', {'testWireCarriesNoAuthorizationScope'}),
    'AuthoritySmoke 进了 products': (
        'MCPBoundaryTests', {'testAuthoritySmokeIsNotAProduct'}),
    '打包脚本拷了开发期工具': (
        'MCPBoundaryTests', {'testPackagingScriptDoesNotCopyDevTools'}),
    '结果正文被适配层改写': (
        'MCPHandlerTests', {'testSuccessPayloadIsReturnedVerbatim'}),

    # ---- Phase 6.3a：FileID / owner / locate 返回结构（2026-10-20）----
    # golden 是跨版本兼容的唯一保险：前像一动它必须红，否则「昨天给的 id 今天全废」没人发现。
    'file_id 前像里没有来源': (
        'FileIDTests', {'testTheSourceIsPartOfTheIdentity', 'testGoldenIDsPinTheHashRule'}),
    '前像分隔符换成 0x00': (
        'FileIDTests', {'testTheSeparatorIsUnitSeparator',
                        'testPreimageIsTheDocumentedByteSequence',
                        'testGoldenIDsPinTheHashRule'}),
    'file_id 生成大写 hex': (
        'FileIDTests', {'testMakeProducesPrefixAndThirtyTwoLowercaseHex',
                        'testParseAcceptsWhatMakeProduces'}),
    'file_id 不归一化 Unicode': (
        'FileIDTests', {'testComposedAndDecomposedFormsProduceTheSameID'}),
    '相对路径安全判定被放宽': (
        'FileIDTests', {'testUnsafePathsAreRejected'}),
    # 形状判定搬进 FileID 之后，「放宽校验」只能改 parse 自己（Router 里已经没有这个分支）。
    'file_id 不校验形状': (
        'FileIDTests', {'testParseRejectsEverythingElse'}),
    # ★ 这条行为完全正确，只有「格式只有一个出处」那条结构测试抓得住。
    'Router 又自带形状规则': (
        'FileIDTests', {'testTheRouterDoesNotCarryASecondShapeRule'}),
    '坏 file_id 被兜成默认 id': (
        'ToolRouterTests', {'testFileIDShapeIsEnforced'}),
    # owner：固定 sessionID、落成 .ui、不夹长度（这条在批跑里被前一条遮住，只能单跑）。
    'owner 变成固定 sessionID': (
        'MCPOwnerTests', {'testEachWireRequestBecomesItsOwnOwner',
                          'testTwoDifferentHostileIDsStayDistinct'}),
    'owner 落成 .ui': (
        'MCPOwnerTests', {'testTheMCPOwnerIsNeverTheUIOwner'}),
    '不可信 id 不夹长度': (
        'MCPOwnerTests', {'testAnOverlongOrHostileIDIsBounded'}),
    '报文 id 不过河': (
        'AuthoritySocketTests', {'testTheRequestIDReachesTheService'}),
    # locate 返回结构：字段名、warnings、reasons、分数、绝对路径、顺序、truncated。
    'locate 结果没有 warnings 内容': (
        'LocateResponseTests', {'testWarningsAreCarriedVerbatim'}),
    'reasons 被改写成大写': (
        'LocateResponseTests', {'testTheHitValuesAreCarriedVerbatim'}),
    '分数越界不判': (
        'LocateResponseTests', {'testAScoreOutsideZeroToOneCannotBecomeAResult'}),
    '绝对路径不判': (
        'LocateResponseTests', {'testAnAbsolutePathCannotBecomeAResult'}),
    'locate 结果被重排': (
        'LocateResponseTests', {'testTheResultOrderIsPreserved'}),
    # ---- Phase 6.3b-0（2026-10-20）：truncated 的语义只有一处赋值 ----
    # 这一行既是「还有更多结果」的唯一判定点，也是四条边界用例的唯一抓手。
    # 因此「改成 false / wasClamped / true」三条与批跑里的 `>=` 锚在同一行，
    # 批跑时只能留一条（见 red_proof.SINGLE_ONLY），其余三条在这里一条一条证红。
    'truncated 写死 false': (
        'LocateResponseTests', {'testHavingOneMoreCandidateThanTheLimitIsTruncated'}),
    'truncated 退回「参数被钳位」': (
        'LocateResponseTests', {'testAClampedLimitIsNotATruncatedResult'}),
    'truncated 恒 true': (
        'LocateResponseTests', {'testThreeHitsUnderTheLimitAreNotTruncated',
                                'testExactlyTheLimitIsNotTruncated'}),
    'relative_path 退回老名字 path': (
        'LocateResponseTests', {'testEveryHitCarriesExactlyTheFrozenKeys',
                                'testRetiredFieldsDoNotComeBack',
                                'testTheHitValuesAreCarriedVerbatim'}),

    # ---- Phase 6.3b-1（2026-10-21）：传输层 SIGPIPE（只能单跑）----
    # 这两条变异**不能进批跑**：变异体下 `swift test` 会在那一处收到真的 SIGPIPE
    # 并终止整轮（实测 249 条假 MISS）。所以在这里一条一条跑。
    #
    # 第一条把 `--filter` 收窄到**单条用例**：整个 `AuthoritySocketTests` 里还有
    # 别的用例会写向已关闭的对端，进程会先死，具名红就永远出不来。
    'socket 不关 SIGPIPE': (
        'AuthoritySocketTests/testSocketsAreCreatedWithSIGPIPESuppressed',
        {'testSocketsAreCreatedWithSIGPIPESuppressed'}),
    # 第二条走结构测试：`MCPBoundaryTests` 不碰 socket，进程活着，断言具名失败。
    # 它的**行为**证明（客户端提前断开 → 前面那个用例）只能由批跑之外的人工
    # 单跑复现，症状就是 signal 13；结构测试守的是「那一行还在、位置还对」。
    'accepted 连接不关 SIGPIPE': (
        'MCPBoundaryTests', {'testTheAcceptedSocketSuppressesSIGPIPEToo'}),

    # ---- Phase 6.3b-1（2026-10-21）：locate 真执行 ----
    # 执行聚合的每条变异由哪条用例抓住。批跑（red_proof.EXPECTED）只证明
    # 「期望的用例都红了」，这里证明「每一条变异被哪条用例抓」。
    '执行层提前砍到 limit': (
        'LocateExecutionTests', {'testOneMoreCandidateThanTheLimitIsTruncatedOnTheProductionPath'}),
    '超时伪装成连不上': (
        'LocateExecutionTests', {'testATimedOutSourceIsReportedAsTimeoutNotUnavailable'}),
    '失败来源不进 warnings': (
        'LocateExecutionTests', {'testOneSourceFailingYieldsResultsAndAWarning',
                                 'testACancelledSourceIsReportedEvenWhenAnotherSourceSucceeded'}),
    '预算到期折成不可用': (
        'LocateExecutionTests', {'testASingleTimedOutSourceKeepsItsOwnCode',
                                 'testATimedOutSourceIsReportedAsTimeoutNotUnavailable'}),
    '凭据失效折成不可用': (
        'LocateExecutionTests', {'testAuthRequiredWinsOverUnavailable'}),
    '参数问题说成掉线': (
        'LocateExecutionTests', {'testABlockedSourceIsAnArgumentProblemNotAnOutage'}),
    # ★ 单跑才红：批跑里被「空结果被当成失败」遮住（见 LocateExecutionTests 里
    # testACancelledSourceIsReportedEvenWhenAnotherSourceSucceeded 的注释）。
    '取消当成空结果': (
        'LocateExecutionTests', {'testACancelledSearchIsNeverAnEmptySuccess'}),
    '错误优先级取反': (
        'LocateExecutionTests', {'testAuthRequiredWinsOverUnavailable',
                                 'testTimeoutOutranksUnavailableWhenEverythingFails'}),
    # 串行时「取代」没有对象可取消——只有并发的那个会真的被打断。
    # ★ 6.4a 起 `locate_many` 也走这条：5 条子查询同 owner，取代会把前 4 条取消。
    # ★ 两个抓手在**两个测试类**里，所以这里是正则并集：只写 `LocateExecutionTests`
    #   时 `--filter` 根本不会跑 `LocateManyExecutionTests`，那条 MISS 是假 MISS
    #   （用例压根没被执行，2026-10-21 实测：报「实际变红 []」却只有并发那条红）。
    '同会话请求互相取代': (
        'LocateExecutionTests|LocateManyExecutionTests',
        {'testTwoConcurrentRequestsFromOneSessionDoNotCancelEachOther',
         'testFiveSubQueriesOnOneSourceAllComeBack'}),
    # ★ 服务层的那条断言（testEachWireRequestReachesTheProviderAsItsOwnOwner）
    # 在 AuthorityServiceTests——它是给「服务自己造固定 owner」那类变异的；
    # 这条变异改的是执行层，按类过滤只跑 LocateExecutionTests。
    'MCP 冒充 GUI owner': (
        'LocateExecutionTests', {'testTwoMCPRequestsOnTheSameSourceQueueRatherThanCancel'}),
    # ★ 走确定性单测：老的抓手 testTheExecutorUsesOnlyTheProvidersInTheSnapshot
    # 依赖字典序（values.first 随机），是碰运气——2026-10-21 换成快照的身份断言。
    '句柄不按 id 取': (
        'AuthorizedSourceSnapshotTests',
        {'testTheExecutionHandleIsFetchedBySourceIDNotByWhicheverComesFirst'}),
    '同分不按路径升序': (
        'LocateExecutionTests', {'testTiesAreBrokenByPathSoTheOrderIsReproducible'}),
    '去重被短路': (
        'LocateExecutionTests', {'testDuplicateRowsForOnePathAreMerged'}),
    '名字档距被缩小': (
        'LocateExecutionTests', {'testASharperNameMatchOutranksAFresherFile'}),
    '三年前也叫近期修改': (
        'LocateExecutionTests', {'testAnOldFileDoesNotClaimToBeRecentlyModified'}),
    '时间过滤只判有无': (
        'LocateExecutionTests', {'testModifiedAfterDropsUndatedRows'}),
    'source_id 取自结果行': (
        'LocateExecutionTests', {'testTheSourceIDComesFromTheSnapshotNotFromTheRow'}),
    '越界路径被修好': (
        'LocateExecutionTests', {'testEscapingPathsAreDroppedNotRepaired'}),
    '超预算不停搜索': (
        'LocateExecutionTests', {'testAnOverBudgetSourceIsCancelled'}),
    '空结果被当成失败': (
        'LocateExecutionTests', {'testAnEmptyButCompletedSearchIsASuccess'}),

    # ---- Phase 6.3b-3（2026-10-21）：NAS 共享名 / 来源根（六条契约）----
    # 这里每条变异都对应**一条具名用例**：被否掉的那个方案（剥掉共享名）
    # 会同时让 ① 与 ② 红——② 正是「两个共享撞成同一个身份」的现场。
    'canonical 剥掉第一段（当成设备根）': (
        'NASProviderContractTests', {'testASharePathKeepsItsShareSegmentThroughTheWholeChain',
                                     'testTwoSharesUnderTheSameSourceKeepDistinctFileIDs'}),
    '单段路径也算空': (
        'NASProviderContractTests', {'testTheShareRootItselfIsAValidRelativePath'}),
    'Provider 不按 scope 收口': (
        'NASProviderContractTests', {'testAPathOutsideTheAuthorizedScopesIsDropped'}),
    '结果行允许 ..': (
        'NASProviderContractTests', {'testADotDotRowCrossingSharesIsRejectedNotRepaired'}),

    # ---- Phase 6.3b-4（2026-10-21）：产品装配（真 App + 真 Helper）----
    # 两条都只有产品级跨进程 E2E 抓得到：GUI 搜索那条路自己会套本机范围、
    # 会自己传执行句柄，所以 Core 测试与 6.3b-1 的装配测试都碰不到这里。
    # 单跑要起 GUI 进程（约 25 s/条），不进批跑。
    'MCP 执行侧不套本机搜索范围': (
        'ProductAssemblyE2ETests', {'testTheRealAppServesLocateOverStdioAndRecoversAfterRestart'}),
    'MCP 来源不传执行句柄': (
        'ProductAssemblyE2ETests', {'testTheRealAppServesLocateOverStdioAndRecoversAfterRestart'}),

    # ---- Phase 6.4a（2026-10-21）：locate_many / search + #26 ----
    # 这些条都锚在 `submitAndWait` / `runMany` 上，批跑能抓到，但「是谁抓的」
    # 只有单跑说得清：`LocateManyExecutionTests` 里有多条用例会长得很像。
    'locate_many 分组按查询词排序': (
        'LocateManyExecutionTests', {'testGroupsFollowTheInputOrderNotTheCompletionOrder'}),
    '每条子查询各领一张预算券': (
        'LocateManyExecutionTests', {'testTheSubQueriesShareOneBudgetInsteadOfOneEach'}),
    # 券自身的算术：`remaining()` 恒等于 budget 时上一条抓不到（wait 同一瞬间起步）。
    '预算券永不消耗': (
        'LocateManyExecutionTests',
        {'testTheBudgetCouponShrinksWithTheClockInsteadOfStayingFull'}),
    '每组窗口不截断': (
        'LocateManyExecutionTests', {'testEveryGroupHasItsOwnTruncatedWindow'}),
    '空组被丢掉': (
        'LocateManyExecutionTests', {'testAQueryWithoutHitsStillGetsAnEmptyGroup'}),
    'search 偷偷过滤目录': (
        'SearchExecutionTests', {'testFoldersAreReturnedWithKindFolder'}),
    'search 结果带上 score': (
        'SearchExecutionTests', {'testEachHitHasExactlyFiveFields'}),
    'search 不按档位排序': (
        'SearchExecutionTests', {'testHitsAreOrderedByLexicalRankThenPath'}),
    # #26 的具名抓手是**结构测试**：产品 E2E 那条也会红，但它要起 GUI 进程，
    # 且批跑里可能被别的原因染红——归因交给这一条。
    '本机全局关闭被授权重新打开': (
        'AIAccessSettingsSurfaceTests',
        {'testTheLocalSwitchGatesJudgementWithoutPruningTheAuthorization'}),

    # ---- Phase 6.4b-0（2026-10-21）：映射表 `FileReferenceStore` ----
    # 五条都锚在同一个文件的相邻区域，批跑能抓到但「是谁抓的」只有单跑说得清。
    # 每条的具名抓手就是它要守的那条性质本身，不是「顺便也红了」。
    '映射表写前不校验路径与身份': (
        'FileReferenceStoreTests',
        {'testAnUnsafePathIsRejectedInsteadOfRepaired',
         'testAnIDThatDoesNotBelongToThePathIsRejected'}),
    '映射表读回不校验坏行': (
        'FileReferenceStoreTests',
        {'testALookupRefusesACorruptRowInsteadOfHandingOutThePath',
         'testACorruptRowThatNoLongerMatchesItsIDIsAlsoRefused'}),
    '查不到的 id 被判成错误': (
        'FileReferenceStoreTests', {'testAnUnknownIDIsNilInsteadOfAnError'}),
    '批量注册逐条提交': (
        'FileReferenceStoreTests', {'testOneBadEntryRollsBackTheWholeBatch'}),
    '映射表预留 metadata 列': (
        'FileReferenceStoreTests',
        {'testTheTableHasExactlyTheThreeFrozenColumns',
         'testTheTableDoesNotSmuggleInMetadataOrHistoryColumns'}),

    # ---- Phase 6.4b-1（2026-10-21）：`get_metadata` ----
    # ★ 前两条是本轮最要盯的：它们改的是「对外能不能兑现 id」与「权限会不会被绕过」，
    # 而这类变异在批跑里最容易因为「别的用例先红了」而拿不到明确归属。
    # ★ 三个 Tool 的落盘是三份代码，所以是三条变异、三个各自的名字。
    #   合成一条时只有第一处会被删掉，另两个 Tool 的用例在逐条里根本不红
    #   （2026-10-21 实测：109/110 的那一条 MISS 就是它）。
    'locate 不登记就返回结果': (
        'GetMetadataExecutionTests',
        {'testLocateRegistersTheIdsItReturns',
         'testAStoreThatCannotWriteFailsTheWholeCall'}),
    'search 不登记就返回结果': (
        'GetMetadataExecutionTests', {'testSearchRegistersTheIdsItReturns'}),
    'locate_many 不登记就返回结果': (
        'GetMetadataExecutionTests',
        {'testLocateManyRegistersEveryGroup',
         'testLocateManyRegistersEveryGroupInOneTransaction'}),
    '登记失败照样回成功': (
        'GetMetadataExecutionTests', {'testAStoreThatCannotWriteFailsTheWholeCall'}),
    '映射冲突被静默覆盖': (
        'FileReferenceStoreTests',
        {'testAnExistingMappingIsNeverOverwritten',
         'testOneConflictRollsBackTheWholeBatch',
         'testThereIsNoUpsertAnywhereInTheStore',
         # ★ 这条用例原先比的是 `String ==`（Swift 会做规范化等价，NFD == NFC），
         #   覆盖发生时照样是绿的；改成比 utf8 字节之后才进得来。
         'testTheFirstByteFormWinsAndTheSecondIsNotAnError'}),
    '冲突被当成幂等': (
        'FileReferenceStoreTests', {'testAnExistingMappingIsNeverOverwritten'}),
    'get_metadata 不查本次 scope': (
        'GetMetadataExecutionTests', {'testRevokingTheSourceDeniesTheNextCall'}),
    'metadata 绕过冻结句柄': (
        'GetMetadataExecutionTests',
        {'testAnUnavailableSourceDoesNotBorrowAnotherSourcesHandle'}),
    'get_metadata 停在未实现': (
        'AuthorityServiceTests', {'testGetMetadataIsNoLongerNotImplemented'}),
    '未知大小折成 0': (
        'GetMetadataExecutionTests', {'testAnUnknownSizeIsNullNotZero'}),
    '未知时间折成 1970': (
        'GetMetadataExecutionTests', {'testAnUnknownTimeIsNullNotEpoch'}),
    '目录也报大小': (
        'ProviderMetadataTests', {'testALocalFolderHasNoSize'}),
    '直查只要包含就算命中': (
        'ProviderMetadataTests', {'testAPrefixIsNotAMatch'}),
    '直查忽略大小写': (
        'ProviderMetadataTests', {'testCaseIsSignificantSoThereIsNoFuzzyMatch'}),
    # build 29（BUG-112-02）：这两条与批跑里的「首帧也等读空闲超时」锚在
    # `readLine` 的同一行，只能单跑。各守一种退化：
    #   · 中途停顿改用整段预算 → 回到一半卡住要拖到总预算才报错
    #   · 每块都续命          → 分段慢速发送能把一次请求拖成任意长
    '中途停顿改用整段预算': (
        'AuthoritySocketTests', {'testAStallAfterTheFirstChunkStillUsesTheIdleTimeout'}),
    '每块都续命不受总预算': (
        'AuthoritySocketTests', {'testDribbledChunksCannotExtendTheTotalBudget'}),
    # build 29（BUG-112-03）：这条必须「按事件限量」+「不翻页」同时成立才复现故障
    # （只改一处是零效应，两道防线各自兜住），所以锚点跨了循环头到调用点，
    # 与批跑的 ㊿₂₂ 抢同一段代码 ⇒ 只能单跑。
    'recent 先限量再去重': (
        'RecentExecutionTests', {'testOneFileFloodingHistoryDoesNotEvictAnother'}),
    # build 29（BUG-112-01）：归一/解软链这条与批跑的 ㊿₁₀₁（判定反向）**互相抵消**，
    # 两个错误叠起来结论恰好正确 ⇒ 只能单跑。单跑时两条用例才有名有姓地红。
    '读范围不归一也不解软链': (
        'LocalReadScopeTests',
        {'testDotDotIsNormalisedBeforeComparison',
         'testSymbolicLinkEscapingTheFolderIsRejected'}),
    '直查不列父目录': (
        'ProviderMetadataTests', {'testNasMetadataPicksTheExactEntry'}),
    '没连上也照样问设备': (
        'ProviderMetadataTests', {'testADisconnectedSourceIsUnavailableNotNotFound'}),
    # ---- 下面四条是补登记：它们的用例原先只进了批跑的 EXPECTED，
    #      却没有能打红它们的变异 → 批跑 9 条永久 MISS（2026-10-21 实测）。
    '直查把没给大小折成 0': (
        'ProviderMetadataTests', {'testADeviceThatGivesNoSizeYieldsNil'}),
    '0 字节当成没给大小': (
        'GetMetadataExecutionTests', {'testAZeroByteFileReportsZeroNotNull'}),
    '有入口不走队列': (
        'FileReferenceStoreTests', {'testEveryEntryPointGoesThroughOneSerialQueue'}),
    'get_metadata 又给回绝对路径': (
        'GetMetadataExecutionTests', {'testTheResponseCarriesExactlySevenFields'}),

    # ---- Phase 7（2026-10-21）：History + recent ----
    # ★ 批跑只证明「期望的用例都红了」；这里证明「每一条变异被哪条用例抓」。
    #   Phase 7 新增的变异跨 4 个文件、3 个测试类，必须显式登记。
    #
    # 7c 写者（三条，各自一份代码，不能合成一条）：
    'locate 不记 located': (
        'RecentExecutionTests', {'testLocatedCoversOnlyTheReturnedWindow',
                                 'testRepeatedLocateInOneSessionRecordsLocatedOnce'}),
    'search 不记 located': (
        'RecentExecutionTests', {'testSearchRecordsLocatedForTheHitsItReturns'}),
    'locate_many 不记 located': (
        'RecentExecutionTests', {'testLocateManyRecordsLocatedForEveryGroup'}),
    'get_metadata 不记 metadata': (
        'RecentExecutionTests', {'testGetMetadataRecordsEverySuccessfulCall'}),
    'metadata 记成 located': (
        'RecentExecutionTests', {'testGetMetadataRecordsEverySuccessfulCall'}),
    # ★ 与 `locate 不记 located` 锚在同一段 ⇒ 只能单跑。
    '历史写失败也让 locate 失败': (
        'RecentExecutionTests', {'testLocateStillSucceedsWhenHistoryCannotBeWritten'}),
    # 7d recent：
    'recent 不看本次 scope': (
        'RecentExecutionTests', {'testRecentDropsSourcesThatAreNoLongerAuthorized',
                                 'testSourceIDsTightenRecentAndNeverWiden'}),
    'recent 不跳过 stale': (
        'RecentExecutionTests', {'testRecentSkipsStaleReferencesAndWarns'}),
    'recent 退化成空列表': (
        'RecentExecutionTests', {'testRecentReturnsWhatLocateJustReturned'}),
    # ✗ 'recent 不去重' 已删除（build 29）：SQL 收敛 + `seen` + 翻页三道防线，
    #   删掉任意一处都被另外两道兜住 ⇒ 零效应，证不出红来。
    'recent 多给字段': (
        'RecentExecutionTests', {'testTheRecentHitCarriesExactlyFiveFields'}),
    'recent 库坏了也返回空': (
        'RecentExecutionTests', {'testRecentFailsWhenTheHistoryStoreIsBroken'}),
    'recent 没库时报错': (
        'RecentExecutionTests', {'testRecentIsEmptyNotAnErrorWhenHistoryIsNotAttached'}),
    'recent 谎称不可用': (
        'RecentExecutionTests', {'testRecentReturnsAnEmptyListWhenNothingHasBeenSeen'}),
    # 7b 库：
    # ★ 与批跑里的 `located 去重扩到 metadata` 锚在同一行 ⇒ 单跑。
    'located 去重形同虚设': (
        'HistoryStoreTests', {'testLocatedIsRecordedOncePerSessionPerFile'}),
    '去重键去掉 session': (
        'HistoryStoreTests', {'testTwoHelperSessionsDoNotShareTheLocatedDedup'}),
    '加回快照列与绝对路径列': (
        'HistoryStoreTests', {'testTheRowCarriesExactlyEightColumns',
                              'testTheRowCarriesNoSizeOrTimeSnapshot'}),
    'recent 的 source 过滤失效': (
        'HistoryStoreTests', {'testRecentHonoursTheSourceFilter'}),
    'recent 的时间窗反了': (
        'HistoryStoreTests', {'testRecentHonoursWithinDays'}),
    'recent 的 limit 失效': (
        'HistoryStoreTests', {'testRecentLimitBoundsTheCandidateSet'}),
    'clear 不真删': (
        'HistoryStoreTests', {'testClearEmptiesEveryEvent'}),
    'HistoryStore 有入口不走队列': (
        'HistoryStoreTests', {'testEveryEntryPointGoesThroughOneSerialQueue'}),
    '动作集合多一个': (
        'HistoryStoreTests', {'testTheActionSetIsExactlyLocatedAndMetadata'}),
    # 7e 生命周期：
    '每日闸门记不住': (
        'HistoryMaintenanceTests', {'testTheSecondRunOnTheSameDayTouchesNothing',
                                    'testANewDayOpensTheGateAgain'}),
    '每日闸门永不放行': (
        'HistoryMaintenanceTests', {'testTheFirstRunPrunesForReal',
                                    'testANewDayOpensTheGateAgain'}),
    '没库也算失败': (
        'HistoryMaintenanceTests', {'testNoHistoryStoreIsNotAFailure'}),
    # 7a 标签：
    '每次调用换 session': (
        'HistoryContextTests', {'testTheSessionIdIsStableWithinOneHelperProcess'}),
    '空标签不降级': (
        'HistoryContextTests', {'testALabelOfOnlyNoiseFallsBackToUnknown'}),
    '版本为空也拼斜杠': (
        'HistoryContextTests', {'testAClientWithoutAVersionKeepsTheBareName'}),
    '客户端名不 trim': (
        'HistoryContextTests', {'testAClientWithoutANameIsUnknownWithALaunchStamp'}),
    '名字与版本写反': (
        'HistoryContextTests', {'testTheAgentIdComesFromTheClientInfo'}),
    # ★ 这里**没有** `context 多带一个键` 这条：多带一个 `case` 会让
    #   `HistoryContext` 直接编译失败（`CodingKey case` 必须有对应的存储属性），
    #   而变异得是「能编过的错实现」，否则红证跑不出红、只会把整套测试打挂。
    #   `testTheContextCarriesExactlyTwoKeys` 由批跑里的 `context 键名写错` 守着
    #   （改原始键名 ⇒ 键集合对不上 ⇒ 该用例红），不缺覆盖。
    'HistoryContext 引用判定概念': (
        'HistoryContextTests', {'testTheSessionIdIsNeverTheRequestId'}),
    # wire：
    'context 混进 args': (
        'HistoryContextTests', {'testTheRidesNextToArgsNotInsideThem'}),
    '缺 context 就报错': (
        'HistoryContextTests', {'testARequestWithoutContextIsNotAnError'}),
    '编码时丢掉 context': (
        'HistoryContextTests', {'testBothLabelsSurviveTheRoundTrip'}),

    # ---- Phase 9-lite：AI 设置页（2026-10-22）----
    # 批跑里已经覆盖了 9-lite 的多数变异（页名、助手状态、历史文案、接线），
    # 这里只登记**只能单跑**的那一条：它与 ㊿₅₅（AI 页改名）锚在同一行。
    # ★ 顺序被挪后不会有编译错误，所以它是能编过的错实现，适合证红。
    'AI 页排到高级后面': (
        'SettingsIATests', {'testSettingsPaneHasAtMostFourPages',
                            'testAIIsItsOwnPaneAndSitsBeforeAdvanced'}),

    # ---- Phase 9-lite 追加：接入提示词（2026-10-22）----
    # 批跑里已覆盖其余十一条（写死路径、工具列表、参数、三步、隐私、闸、复制）。
    # 这条只能单跑：与 ㊿₇₂ 锚在 `helperPath(forAppAt:)` 同一行。
    # ★ 它也是「零效应变异」的教科书案例：换成「字符串拼 /Contents/…」**打不红**，
    #   因为 `URL.path` 会把尾部斜杠吃掉，两种写法结果一模一样（已实测）。
    #   能真改坏路径的是前导斜杠 ⇒ 拼出 `闪寻.app//Contents/…`。
    '路径拼出双斜杠': (
        'MCPIntegrationPromptTests', {'testTheHelperPathNeverDoublesASlash'}),

    # ---- Phase 10 追加：Helper 身份 + 打包签名顺序（2026-10-22）----
    # 这六条批跑里都能抓到，但「是谁抓的」值得单独钉：五条锚在同一个 plist 的不同键上，
    # 一条锚在打包脚本的两行顺序上。它们的共同点是**只有发出去才错**——
    # 编译得过、跑起来也对，错的只有 `serverInfo.version` 或别人机器上的 Gatekeeper。
    'Helper 版本落后一格': (
        'HelperPackagingTests', {'testHelperVersionMatchesTheApp'}),
    # ★ 这条**故意登记两条用例**：构建号留空既让「键非空」那条红，也让「两份一致」
    #   那条红（主 plist 有 build，派生副本没有）。如果实际只红了其中一条，
    #   说明我对影响的判断错了，逐条会报 MISS —— 这正是要它报出来的。
    'Helper 构建号留空': (
        'HelperPackagingTests',
        {'testBothVersionKeysAreActuallyFilled', 'testHelperVersionMatchesTheApp'}),
    'Helper 标识符写死': (
        'HelperPackagingTests', {'testHelperIdentifierIsDerivedFromTheApp'}),
    'Helper 可执行名对不上': (
        'HelperPackagingTests', {'testHelperExecutableNameMatchesThePackagedFileName'}),
    'Helper plist 混进 App 键': (
        'HelperPackagingTests', {'testHelperPlistCarriesOnlyBundleIdentityKeys'}),
    '先签 App 再签 Helper': (
        'MCPBoundaryTests', {'testPackagingScriptSignsHelperBeforeTheApp'}),

    # ---- Phase 11-lite 追加：客户端 capability 兼容清洗（2026-10-22）----
    # ★ 「清洗层空转」必须单跑：它在批跑里会让其余五条清洗变异全部落在打死代码上，
    #   于是那些用例反而变绿（掩蔽型假绿）。单跑时它名的红是两条——
    #   规则层（解码成功那条）与传输层（receive 出口那条）。
    '清洗层空转': (
        'ClientCapabilitySanitizerTests',
        {'testCodexInitializeDecodesAfterSanitizing',
         'testSanitizingTransportRewritesIncomingInitialize'}),
    '只留非字符串值': (
        'ClientCapabilitySanitizerTests',
        {'testMixedExperimentalKeepsStringEntriesOnly',
         'testCodexInitializeDecodesAfterSanitizing'}),
    '合规报文也重编码': (
        'ClientCapabilitySanitizerTests',
        {'testStringValuedExperimentalIsLeftByteIdentical'}),
    # ★ 这条在批跑里由 ㊿₉₁ 与它自己都能打红（空转时“畸形形态没被删”同样成立），
    #   单跑时只登记它自己该红的那一条。
    '非对象 experimental 不删': (
        'ClientCapabilitySanitizerTests',
        {'testNonObjectExperimentalIsDroppedEntirely'}),
    '清洗后丢换行': (
        'ClientCapabilitySanitizerTests', {'testTrailingNewlineIsPreserved'}),
    # ★ 这条抓的是装配失误（`main.swift` 少包一层）。它在批跑里也是红的——
    #   包装整层被摘掉以后，清洗器再怎么写都影响不到握手。逐条登记是为了
    #   「红得有名有姓」：批跑里红的是几十条变异共同造成的，单跑这条才唯一归因。
    '忘了换 SanitizingTransport': (
        'MCPStdioTests', {'testCodexShapeInitializeIsAccepted'}),
    # ㊿₉₈ 搜索结束不摘槽位（2026-10-22 现场）：两个方向一起登记，
    # 因为它们只在**换 owner** 时才现形，单跑一条会把另一个方向漏掉。
    '搜索结束不摘槽位': (
        'NASSourceSlotReleaseTests',
        {'testAnotherOwnerCanSearchAfterTheQueryCompleted',
         'testTheUICanSearchAfterAnMCPQueryCompleted'}),
    # OTP 指路（2026-10-22 用户报「详情界面不弹 OTP」）：两条各红一条，互不干扰——
    #   改标题引用只影响「含本名」那条；把「6 位数字」说成「验证码」只影响另一条。
    '取消弹窗后那句提示不指「连接」按钮': (
        'ConnectionFailureTextTests', {'testTheOTPRetryHintPointsAtAButtonThatStillExists'}),
    '取消弹窗后那句提示不说填几位': (
        'ConnectionFailureTextTests', {'testTheOTPRetryHintSaysWhatToTypeAndHowToComeBack'}),
    # 全部登录路径统一弹窗（2026-10-22 用户要求）：App 层靠源码结构测试守。
    '向导 OTP 失败只写状态不弹窗': (
        'AppLayerStructureTests', {'testWizardFailurePromptsWhenTheDeviceNeedsOTP'}),
    '弹窗拿到码不自动续连': (
        'AppLayerStructureTests', {'testWizardPromptsForOTPAndContinuesOnItsOwn'}),
    '向导自己再造一个 OTP 弹窗': (
        'AppLayerStructureTests', {'testWizardPromptsForOTPAndContinuesOnItsOwn'}),
    # 关窗后闪退（2026-10-22 用户报「OTP 账号点登录后闪退」）：
    #   · 判定取反 → 「没窗口要放回」与「有窗口别抢焦点」两条同时红；
    #   · 理由写空 → 只红第三条。一条变异打红两条是被允许的，只要每条用例都归得了因。
    '关窗后判定反了：有窗口才放回浮窗': (
        'LastWindowClosePolicyTests',
        {'testRestoresTheSearchPanelWhenNoOtherWindowIsVisible',
         'testDoesNotStealFocusWhenAnotherWindowIsStillOpen'}),
    '禁用自动终止的理由写成空串': (
        'LastWindowClosePolicyTests',
        {'testAutomaticTerminationIsDisabledWithANonEmptyReason'}),
}


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def failed_tests(output: str) -> set:
    out = set()
    for line in output.splitlines():
        if "]' failed (" not in line:
            continue
        inner = line.split("'", 2)[1]
        out.add(inner.rsplit(' ', 1)[-1].rstrip(']'))
    return out


def main() -> int:
    if not rp.require_swift_61():
        return 1

    targets = [m for m in rp.MUTATIONS if m[0] in EXPECT]
    missing = set(EXPECT) - {m[0] for m in targets}
    if missing:
        print(f'FAIL 登记了但 red_proof 里没有这些变异：{sorted(missing)}')
        return 1

    backup = Path(tempfile.mkdtemp(prefix='ff-55-each-'))
    before = {p: sha(p) for p in {m[1] for m in targets}}
    for path in before:
        shutil.copy2(path, backup / path.name)

    failures = 0
    try:
        for name, path, old, new in targets:
            test_class, expected = EXPECT[name]
            text = path.read_text(encoding='utf-8')
            if old not in text:
                print(f'FAIL 标记没找到：{name}（{path.name}）')
                failures += 1
                continue

            path.write_text(text.replace(old, new, 1), encoding='utf-8')
            # ★ 与 `red_proof.py` 同样钉住依赖：不钉会重解析并把 `Package.resolved`
            #   里冻结的版本改掉（2026-10-21 实测过六条 pin 一起漂）。
            result = subprocess.run(['swift', 'test', '--filter', test_class,
                                     '--only-use-versions-from-resolved-file'],
                                    cwd=CLIENT, capture_output=True, text=True)
            red = failed_tests(result.stdout + result.stderr)
            path.write_text(text, encoding='utf-8')

            hit = expected & red
            if hit == expected:
                print(f'RED  {name} → {"、".join(sorted(hit))}')
            else:
                failures += 1
                print(f'MISS {name}：没有变红 {sorted(expected - red)}'
                      f'（实际变红 {sorted(red)}）')
    finally:
        for path in before:
            shutil.copy2(backup / path.name, path)
        shutil.rmtree(backup, ignore_errors=True)
        same = all(sha(p) == before[p] for p in before)
        print('还原后 SHA-256 逐字节一致：', same)
        if not same:
            failures += 1

    print(f'{len(targets) - failures}/{len(targets)} 条变异逐条证红')
    return 0 if failures == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
