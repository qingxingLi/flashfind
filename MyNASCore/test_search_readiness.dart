// 搜索「就绪判据」与「行级解析」的回归测试 —— 全部在本机用脚本化传输层跑。
//
// ── 为什么专门要有这个文件 ─────────────────────────────────────────
// 真机实测：两台群晖源搜「报告」都报 `ProtocolViolation`，
// 界面写「设备返回的内容不符合预期（反向代理或登录门户页也可能造成这个现象）」。
// 那句话把人往代理/网关方向带了很久，而真实原因是**客户端自己**的两处判断：
//
//   1. 分页响应里检查了 `finished`，而 `finished=false` 是**合法中间态**
//      （抓到的 HAR 里就有 `finished=false` 且 `total=70` 的样本）。
//      后果：设备在分页期间仍在继续扫描 → 第一页被判死 → 已就绪的 203 条
//      结果全部作废、界面显示 0 条。证据形态：`reportedTotal=203`、`fetchedCount=0`。
//
//   2. 把「`finished=true` 却没有 `total`」交给 requireInt 去抛协议违规，
//      于是「设备还没算完」被显示成「搜索失败」。证据形态：`reportedTotal=null`。
//      权威结论明确：**就绪判据必须是「拿到 total」，而不是 finished**；
//      且这种形态禁止显示成「没有找到文件」。
//
// 这里的每个场景都对应这两条里的某一个，或者对应一并修的边界
// （坏行不能毁掉整次搜索、游标必须按设备返回行数推进、name 缺失要能兜底）。
//
// ── 复搜仍然失败，但失败点已经不同 ─────────────────────────────────
// 复搜仍然失败，但诊断轨迹（新增了 `errorApi`/`errorMethod`/`unparsedCount`）
// 给出了新证据：
//   · 一台设备：`reportedTotal=203`、`fetchedCount=0`、
//     `detail=结果里出现了重复路径` → 重复在**第一页内部**
//     （见本文件末尾的说明）。
//   · 另一台：`errorApi=SYNO.FileStation.Search`、`errorMethod=list`、
//     `reportedTotal=null`，且 `detail=native:ProtocolViolation` ——
//     这个 `native:` 前缀只可能来自证书固定传输层，也就是**原生助手**
//     在「响应体不可用」那一支上报的（它把「空响应 / 超 256KB / 非 JSON」
//     压成了同一个状态）。因此就绪轮询那一次请求改用 limit=1。
//
// ── 就绪判据补上另一半 ───────────────────────────
// 用户报障：在设备上搜「测试」报「搜索失败—设备返回的分页数据不完整
// （错误类型 IncompleteResponse）」，且「第二次搜索可能会解决」。
//
// 探针复刻客户端时序（start → limit=1 轮询 → limit=200 分页）实测到：
//   · 就绪轮询永远拿到仍在上涨的 total 且 `finished=false`（33~103），
//     第一页拿到的却是最终全集（239）；
//   · 另一台设备上同形态：30/70/150 → 203。
//
// 结论：权威结论「拿到 total 才敢当全集」只对了一半——
// **`finished=false` 时的 total 不是全集**。旧判据 `total != null`
// 在中间态上放行，让分页的 total 一致性断言必炸。
//
// 修法：就绪 = 有 total **且** `finished != false`；「还在扫描」单独给
// 24 轮预算（实测 1~2 轮收敛，用时 0.2~1.6s），并在同一探针上验证通过。
//
// 用户说的「第二次搜索可能会解决」也由此解释：确有轮次第一次轮询就已
// finished=true（搜索在请求抵达前跑完），那种 race 下旧判据能碰对。
//
// 运行：dart run test_search_readiness.dart
import 'dart:io';

import 'lib/core.dart';
import 'lib/protocol.dart';
import 'lib/synology_api.dart';

// ─────────────────────────── 脚本化传输层 ───────────────────────────

/// 按 `api/method` 排队返回预置响应；同一 key 排到底后重复最后一条。
///
/// 它替代真实设备，但**不替代被测代码**：`SynologyApi` 与 `SynologyCore`
/// 走的还是产品代码，只是网络那一段被换掉了。
class ScriptedTransport implements Transport {
  final Map<String, List<Map<String, dynamic>>> script;
  final List<WireRequest> calls = [];
  ScriptedTransport(this.script);

  @override
  Future<Map<String, dynamic>> send(WireRequest request, Cancellation cancellation) async {
    cancellation.check();
    calls.add(request);
    final key = '${request.api}/${request.method}';
    final queue = script[key];
    if (queue == null || queue.isEmpty) {
      throw CoreError('UnexpectedCall', api: request.api, method: request.method);
    }
    return queue.length == 1 ? queue.first : queue.removeAt(0);
  }

  /// 某个方法被调用的次数。
  int countOf(String api, String method) =>
      calls.where((c) => c.api == api && c.method == method).length;

  /// 第 n 次该方法调用的请求字段（用于断言分页参数与游标推进）。
  WireRequest nthOf(String api, String method, int n) =>
      calls.where((c) => c.api == api && c.method == method).elementAt(n);
}

// ─────────────────────────── 响应构造 ───────────────────────────

Map<String, dynamic> _descriptors() => {
      'success': true,
      'data': {
        'SYNO.API.Auth': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 7},
        'SYNO.FileStation.Info': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 2, 'requestFormat': 'JSON'},
        'SYNO.FileStation.List': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 2, 'requestFormat': 'JSON'},
        'SYNO.FileStation.Search': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 2, 'requestFormat': 'JSON'},
        'SYNO.FileStation.Download': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 2, 'requestFormat': 'JSON'},
      }
    };

Map<String, dynamic> _data(Map<String, dynamic> data) => {'success': true, 'data': data};

/// 一条正常的 DSM 文件行。
Map<String, dynamic> row(String name, {bool isDir = false, Object? size = 12, Object? mtime = 1750000000}) => {
      'name': name,
      'path': '/share/$name',
      'isdir': isDir,
      'additional': {
        if (size != null) 'size': size,
        if (mtime != null) 'time': {'mtime': mtime, 'crtime': mtime},
        'type': isDir ? 'dir' : 'file',
      },
    };

Map<String, dynamic> _page({
  required int total,
  required int offset,
  bool? finished,
  required List<Map<String, dynamic>> files,
}) =>
    _data({
      'total': total,
      'offset': offset,
      if (finished != null) 'finished': finished,
      'files': files,
    });

/// n 条互不重名的行（用于复刻真机的整页规模，而不必手写 200 条）。
List<Map<String, dynamic>> rows(int n, {String prefix = 'f'}) =>
    List.generate(n, (i) => row('$prefix$i.txt'));

/// 「设备未就绪」的确切形态：**有 finished，没有 total/offset/files**。
///
/// 这不是随手编的形状 —— 它就是真机上 `reportedTotal=null` 那一次收到的响应，
/// 逐字节一致。
Map<String, dynamic> _notReady() => _data({'finished': true});

// ─────────────────────────── 夹具 ───────────────────────────

/// 建好一个「已发现 / 已登录 / 已授权 / 已选范围」的核心，返回它和传输层。
///
/// [scanningPollLimit] 可覆盖「设备还在扫描」的轮询预算，用来在测试里
/// 快速走到预算耗尽那一支（默认 24 轮 × 500ms，跑完要十几秒）。
Future<(SynologyCore, ScriptedTransport)> _connected(
  List<Map<String, dynamic>> searchListQueue, {
  int scanningPollLimit = 24,
}) async {
  final transport = ScriptedTransport({
    'SYNO.API.Info/query': [_descriptors()],
    'SYNO.API.Auth/login': [_data({'sid': 'SID-1', 'synotoken': 'TOKEN-1'})],
    'SYNO.API.Auth/logout': [_data(<String, dynamic>{})],
    'SYNO.FileStation.Info/get': [_data({'is_manager': false})],
    'SYNO.FileStation.List/list_share': [
      _data({
        'total': 1,
        'offset': 0,
        'shares': [
          {'path': '/share', 'name': 'share'}
        ],
      })
    ],
    'SYNO.FileStation.Search/start': [_data({'taskid': 'TASK-1'})],
    'SYNO.FileStation.Search/list': searchListQueue,
    'SYNO.FileStation.Search/stop': [_data(<String, dynamic>{})],
    'SYNO.FileStation.Search/clean': [_data(<String, dynamic>{})],
  });
  final api = SynologyApi(transport, 'src-1', requestBudget: const Duration(seconds: 5));
  final token = Cancellation();
  await api.discover(token);
  await api.login('u', 'p', token);
  await api.authorize(token);
  final core = SynologyCore(api, null,
      sourceName: '测试 NAS',
      smbHost: 'nas.example',
      pollInterval: const Duration(milliseconds: 1),
      scanningPollLimit: scanningPollLimit,
      queryBudget: const Duration(seconds: 10));
  await core.selectScopes(token, ['/share']);
  return (core, transport);
}

// ─────────────────────────── 断言 ───────────────────────────

int _passed = 0, _failed = 0;

Future<void> _check(String title, Future<void> Function() body) async {
  try {
    await body();
    _passed++;
    stdout.writeln('  ✅ $title');
  } catch (error) {
    _failed++;
    stdout.writeln('  ❌ $title');
    stdout.writeln('     $error');
  }
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError(message);
}

// ─────────────────────────── 场景 ───────────────────────────

Future<void> main() async {
  stdout.writeln('搜索就绪判据与行级解析回归测试');

  // ★ 真机上量到的形态：轮询就绪（total=203），分页响应带 finished=false。
  //   旧实现在这里判死，整份结果作废。这是要修的头号缺陷。
  await _check('分页响应带 finished=false 时**不能**判死（真机形态）', () async {
    final (core, transport) = await _connected([
      _page(total: 3, offset: 0, finished: true, files: const []),
      _page(total: 3, offset: 0, finished: false, files: [row('a.txt'), row('b.txt'), row('c.txt')]),
    ]);
    final out = await core.search('报告', 'q1');
    _expect(out.state == 'completed', '应正常完成，实际 ${out.state} / ${out.error?.kind}');
    _expect(out.reportedTotal == 3, 'reportedTotal 应为 3，实际 ${out.reportedTotal}');
    _expect(out.files.length == 3, '应发布 3 条结果，实际 ${out.files.length}');
    _expect(out.fetchedCount == 3, 'fetchedCount 应为 3，实际 ${out.fetchedCount}');
    // 分页必须显式带 200 条上限（不是沿用轮询的 limit=0）。
    final page = transport.nthOf('SYNO.FileStation.Search', 'list', 1);
    _expect(page.fields['limit'] == '200', '分页 limit 应为 200，实际 ${page.fields['limit']}');
    // 结果行仍与群晖同形：Swift 侧不需要为这类修复分支。
    final first = out.files.first;
    _expect(first['sourceName'] == '测试 NAS', '结果行应带 sourceName');
    _expect(first['openTarget'] != null, '结果行应带 openTarget');
    _expect(transport.countOf('SYNO.FileStation.Search', 'start') == 1, '只应提交一次搜索任务');
  });

  // ★★ **推翻本条旧断言**（原表述为「total 已存在时即使
  // finished=false 也应立刻取页（就绪=total）」）。
  //
  // 真机实测证明那条结论只对了一半：`finished=false` 时的 `total` 是
  // **「目前已发现数」，还会继续涨**。示例设备（192.168.1.88:5003，双根
  // /示例共享文件夹 + /项目资料，关键词「测试」）10/10 轮：
  //   就绪轮询 limit=1  → total=33~103、finished=false
  //   第一页 limit=200  → total=239、finished=true
  // 于是分页第一条一致性断言必炸 → IncompleteResponse「设备返回的分页数据
  // 不完整」，这就是用户报障的那一句。示例设备（/示例共享，「报告」）同形态：
  // total=30/70/150 → 203。
  //
  // 现在：还在扫描就继续等，等到设备声明算完之后再拿 total 当全集。
  // 「拿到 total 才敢当全集」那一半依然成立（见下面 deviceBusy 用例）。
  await _check('finished=false 时的 total 是中间数，必须继续等', () async {
    final (core, transport) = await _connected([
      // 就绪轮询 #1：设备还在扫，只发现了 7 条
      _page(total: 7, offset: 0, finished: false, files: const []),
      // 就绪轮询 #2：扫完了，全集 12 条
      _page(total: 12, offset: 0, finished: true, files: const []),
      // 分页唯一一页：与最终全集一致
      _page(total: 12, offset: 0, finished: true, files: rows(12)),
    ]);
    final out = await core.search('报告', 'q2a');
    _expect(out.state == 'completed', '应正常完成，实际 ${out.state} / ${out.error?.kind}');
    _expect(out.reportedTotal == 12, 'reportedTotal 必须是最终全集 12，'
        '不能是中间数 7，实际 ${out.reportedTotal}');
    _expect(out.files.length == 12, '应发布 12 条结果，实际 ${out.files.length}');
    _expect(transport.countOf('SYNO.FileStation.Search', 'list') == 3,
        '应轮询 2 次 + 取页 1 次，实际 list 调用 '
        '${transport.countOf('SYNO.FileStation.Search', 'list')} 次');
    // 分页请求带的就是最终全集那一档 limit/offset
    final page = transport.nthOf('SYNO.FileStation.Search', 'list', 2);
    _expect(page.fields['offset'] == '0', '分页 offset 应为 0，实际 ${page.fields['offset']}');
  });

  // 同一机制按真机数值放大复刻：239 条、两页（200 + 39）。
  // 这一条直接锁死用户报障的那个组合（双根 + 「测试」+ 239 条）。
  await _check('真机同构放大：total 33→239，跨两页取完且不报 IncompleteResponse', () async {
    final (core, _) = await _connected([
      _page(total: 33, offset: 0, finished: false, files: const []),
      _page(total: 239, offset: 0, finished: true, files: const []),
      _page(total: 239, offset: 0, finished: true, files: rows(200)),
      _page(total: 239, offset: 200, finished: true, files: rows(39, prefix: 'g')),
    ]);
    final out = await core.search('测试', 'q2a2');
    _expect(out.state == 'completed', '应正常完成，实际 ${out.state} / ${out.error?.kind}');
    _expect(out.reportedTotal == 239, 'reportedTotal 应为 239，实际 ${out.reportedTotal}');
    _expect(out.files.length == 239, '应发布 239 条，实际 ${out.files.length}');
    _expect(out.fetchedCount == 239, 'fetchedCount 应为 239，实际 ${out.fetchedCount}');
    _expect(out.duplicateCount == 0, '不应有重复，实际 ${out.duplicateCount}');
  });

  // 设备始终不声明结束：等到扫描预算耗尽，按**可重试的中间态**收场
  // （deviceBusy），既不是协议违规、也不是 0 条结果。
  await _check('一直 finished=false → 扫描预算耗尽后归为 deviceBusy', () async {
    final (core, _) = await _connected(
        [_page(total: 5, offset: 0, finished: false, files: const [])],
        scanningPollLimit: 3);
    final out = await core.search('报告', 'q2a3');
    _expect(out.state == 'deviceBusy', '应归为 deviceBusy，实际 ${out.state} / ${out.error?.kind}');
    _expect(out.error?.kind == 'ResultsNotReady',
        '底层错因应为 ResultsNotReady，实际 ${out.error?.kind}');
    _expect(out.files.isEmpty, '未就绪不应发布任何结果，实际 ${out.files.length}');
  });

  // 反过来：设备说「还没算完」且**没给 total**，那就应当继续等，等到了再取页。
  await _check('既无 total 又说 finished=false 时继续轮询，随后正常完成', () async {
    final (core, transport) = await _connected([
      _data({'finished': false}),
      _page(total: 1, offset: 0, finished: true, files: const []),
      _page(total: 1, offset: 0, finished: true, files: [row('only.txt')]),
    ]);
    final out = await core.search('报告', 'q2b');
    _expect(out.state == 'completed', '应正常完成，实际 ${out.state} / ${out.error?.kind}');
    _expect(out.files.length == 1, '应发布 1 条结果，实际 ${out.files.length}');
    _expect(transport.countOf('SYNO.FileStation.Search', 'list') == 3,
        '应当轮询一次、就绪取页一次，共 3 次 list');
  });

  // ★ 真机群晖源的形态：finished=true 但没有 total。
  //   它是「设备未就绪」，既不是失败、更不是 0 条结果。
  await _check('finished=true 但无 total → 归类为 deviceBusy，不是失败', () async {
    final (core, _) = await _connected([_notReady()]);
    final out = await core.search('报告', 'q3');
    _expect(out.state == 'deviceBusy', '应归类为 deviceBusy，实际 ${out.state}');
    _expect(out.error?.kind == 'ResultsNotReady', '错因应为 ResultsNotReady，实际 ${out.error?.kind}');
    _expect(out.reportedTotal == null, '未就绪时不能报出 total');
    _expect(out.files.isEmpty, '未就绪时不该有结果');
    // 未就绪不是协议违规：把它报成 ProtocolViolation 会把排查引向代理/网关。
    _expect(out.error?.kind != 'ProtocolViolation', '不能退化成 ProtocolViolation');
    // 错因必须带上是哪个 API/方法挂的 —— 这是诊断不能缺的关键字段。
    _expect(out.error?.api == 'SYNO.FileStation.Search', '错因要带 api');
    _expect(out.error?.method == 'list', '错因要带 method');
  });

  // 未就绪时**不换新任务**： 证明同一 taskid 重试无效，
  // 但堆重试会加重设备侧退化窗口，所以这里只做一次性判定。
  await _check('未就绪时不盲目换新任务（避免加重设备退化窗口）', () async {
    final (core, transport) = await _connected([_notReady()]);
    await core.search('报告', 'q4');
    _expect(transport.countOf('SYNO.FileStation.Search', 'start') == 1,
        '不该反复创建新搜索任务，实际 ${transport.countOf('SYNO.FileStation.Search', 'start')} 次');
  });

  // 坏行不能毁掉整次搜索：跳过 + 计数，其余结果照常发布。
  await _check('部分行无法解析时跳过并计数，其余结果照常返回', () async {
    final broken = <String, dynamic>{'path': '/share/broken.txt', 'isdir': false}; // 缺 name（有 path 可兜底）
    final noIsDir = <String, dynamic>{'name': 'x.bin', 'path': '/share/x.bin'}; // 缺 isdir，无法判定文件/目录
    final (core, transport) = await _connected([
      _page(total: 3, offset: 0, finished: true, files: const []),
      _page(total: 3, offset: 0, finished: true, files: [row('good.txt'), noIsDir, row('good2.txt')]),
    ]);
    final out = await core.search('报告', 'q5');
    _expect(out.state == 'completed', '应正常完成，实际 ${out.state} / ${out.error?.kind}');
    _expect(out.files.length == 2, '应发布 2 条可解析结果，实际 ${out.files.length}');
    _expect(out.unparsedCount == 1, '应如实上报 1 条被跳过，实际 ${out.unparsedCount}');
    _expect(out.fetchedCount == 3, 'fetchedCount 应含被跳过的行（3），实际 ${out.fetchedCount}');
    // 游标必须按**设备返回**的行数推进：否则 offset 少走一格会重复取回同一批数据。
    _expect(transport.countOf('SYNO.FileStation.Search', 'list') == 2,
        '跳过一行后仍应只取一页（offset 按原始行数推进），实际取了 '
        '${transport.countOf('SYNO.FileStation.Search', 'list') - 1} 页');
    _expect(broken.isNotEmpty, '（占位，避免未使用变量）');
  });

  // name 缺失必须能从 path 兜底 —— 上游注释写明这是真实会发生的形态，
  // 而旧实现把兜底写在了 requireString 抛出之后，是永不执行的死代码。
  await _check('行缺少 name 时从 path 兜底（上游本就预期会缺）', () async {
    final nameless = <String, dynamic>{
      'path': '/share/照片 2026.docx',
      'isdir': false,
      'additional': {'size': 10, 'type': 'file'},
    };
    final (core, _) = await _connected([
      _page(total: 1, offset: 0, finished: true, files: const []),
      _page(total: 1, offset: 0, finished: true, files: [nameless]),
    ]);
    final out = await core.search('报告', 'q6');
    _expect(out.state == 'completed', '应正常完成，实际 ${out.state} / ${out.error?.kind}');
    _expect(out.files.length == 1, '这一行应当被救回来，而不是丢掉');
    _expect(out.files.first['name'] == '照片 2026.docx',
        'name 应从 path 末段兜底，实际 ${out.files.first['name']}');
  });

  // 哨兵值/类型不符的 size 与时间戳不该让整行、更不该让整次搜索失败。
  await _check('size 为字符串、mtime 为负数时记作「未知」而不致命', () async {
    final odd = <String, dynamic>{
      'name': 'odd.bin',
      'path': '/share/odd.bin',
      'isdir': false,
      'additional': {
        'size': '12', // 类型不符
        'time': {'mtime': -1, 'crtime': -1}, // 哨兵值
        'type': 'file',
      },
    };
    final (core, _) = await _connected([
      _page(total: 1, offset: 0, finished: true, files: const []),
      _page(total: 1, offset: 0, finished: true, files: [odd]),
    ]);
    final out = await core.search('报告', 'q7');
    _expect(out.state == 'completed', '应正常完成，实际 ${out.state} / ${out.error?.kind}');
    _expect(out.files.length == 1, '这一行应当保留');
    _expect(out.files.first['size'] == null, '未知大小应为 null，不能用 0 冒充');
    _expect(out.files.first['modifiedDate'] == null, '未知时间应为 null');
  });

  // 一整页都解析不出来 = 响应形态变了，必须明确报错，绝不能当成「没有结果」。
  await _check('整页都无法解析 → 明确报错，而不是静默显示 0 条', () async {
    final (core, _) = await _connected([
      _page(total: 2, offset: 0, finished: true, files: const []),
      _page(total: 2, offset: 0, finished: true, files: [
        {'path': '/share/a'},
        {'name': 'b', 'path': '/share/b'},
      ]),
    ]);
    final out = await core.search('报告', 'q8');
    _expect(out.state == 'failed', '应报失败，实际 ${out.state}');
    _expect(out.error?.kind == 'IncompleteResponse', '错因应为 IncompleteResponse，实际 ${out.error?.kind}');
    _expect(out.error?.detail?.contains('均无法解析') == true,
        '错因要说清是整页无法解析，实际 ${out.error?.detail}');
  });

  // 分页 total 与就绪时报告的不一致：这是真正的正确性风险，必须报错。
  await _check('分页 total 与就绪时不一致 → IncompleteResponse', () async {
    final (core, _) = await _connected([
      _page(total: 3, offset: 0, finished: true, files: const []),
      _page(total: 5, offset: 0, finished: true, files: [row('a'), row('b'), row('c')]),
    ]);
    final out = await core.search('报告', 'q9');
    _expect(out.state == 'failed', '应报失败，实际 ${out.state}');
    _expect(out.error?.kind == 'IncompleteResponse', '错因应为 IncompleteResponse，实际 ${out.error?.kind}');
  });

  // ─────────── 设备返回重复路径 ───────────
  //
  // 真机上那一台源（`reportedTotal=203`、`fetchedCount=0`）证明重复出现在
  // **第一页内部**：`fetchedCount` 在去重循环之后才累加，若重复来自页间重叠，
  // 第一页就会先把 fetchedCount 加到 200。所以这是「设备把同一条结果给了两遍」，
  // 不是「我们的 offset 算错了」。旧实现把它当成 ProtocolViolation，
  // 于是「设备多给了一条」就让整份结果作废。

  await _check('设备在第一页内返回重复路径 → 去重并计数，不作废整次搜索', () async {
    final (core, _) = await _connected([
      _page(total: 4, offset: 0, finished: true, files: const []),
      _page(total: 4, offset: 0, finished: true, files: [
        row('a.txt'), row('b.txt'), row('a.txt'), row('c.txt'),
      ]),
    ]);
    final out = await core.search('报告', 'q10');
    _expect(out.state == 'completed', '应正常完成，实际 ${out.state} / ${out.error?.kind}');
    _expect(out.files.length == 3, '同一条路径只发布一次，实际 ${out.files.length}');
    _expect(out.duplicateCount == 1, '应如实上报 1 条重复，实际 ${out.duplicateCount}');
    // fetchedCount 记的是**设备原始返回**数量，含重复行；它与 duplicateCount
    // 一起才能回答「设备到底给了多少行、其中多少是重的」。
    _expect(out.fetchedCount == 4, 'fetchedCount 应含重复行（4），实际 ${out.fetchedCount}');
    _expect(out.unparsedCount == 0, '重复不是「解析失败」，不能混进 unparsedCount');
  });

  await _check('整页都是已见过的路径 → DirectoryUnstable，不静默少给结果', () async {
    final (core, _) = await _connected([
      _page(total: 4, offset: 0, finished: true, files: const []),
      _page(total: 4, offset: 0, finished: true, files: [row('a.txt'), row('b.txt')]),
      // offset 回显正确、total 一致，但内容与上一页完全相同 ——
      // 设备没有真的按 offset 推进。继续下去只会一直取回同一批数据。
      _page(total: 4, offset: 2, finished: true, files: [row('a.txt'), row('b.txt')]),
    ]);
    final out = await core.search('报告', 'q11');
    _expect(out.state == 'failed', '应报失败，实际 ${out.state}');
    _expect(out.error?.kind == 'DirectoryUnstable', '错因应为 DirectoryUnstable，实际 ${out.error?.kind}');
    // 但已经拿到的两页结果照样保留并发布过 —— 报错不等于把结果抹掉。
    _expect(out.files.length == 2, '已发布的结果不该被撤回，实际 ${out.files.length}');
  });

  await _check('就绪轮询用 limit=1，不再用语义未验证的 limit=0', () async {
    final (core, transport) = await _connected([
      _page(total: 1, offset: 0, finished: true, files: const []),
      _page(total: 1, offset: 0, finished: true, files: [row('only.txt')]),
    ]);
    final out = await core.search('报告', 'q12');
    _expect(out.state == 'completed', '应正常完成，实际 ${out.state} / ${out.error?.kind}');
    final poll = transport.nthOf('SYNO.FileStation.Search', 'list', 0);
    _expect(poll.fields['limit'] == '1',
        '就绪轮询的 limit 应为 1（只要 total，响应体越小越好），实际 ${poll.fields['limit']}');
    // 分页仍必须是 200：就绪轮询的改动不能顺手把分页也改小。
    final page = transport.nthOf('SYNO.FileStation.Search', 'list', 1);
    _expect(page.fields['limit'] == '200', '分页 limit 仍应是 200，实际 ${page.fields['limit']}');
  });

  stdout.writeln('');
  stdout.writeln('通过 $_passed 项，失败 $_failed 项');
  if (_failed > 0) exitCode = 1;
}
