// Phase 6.4b-0 ②：**按路径直接取元数据**的能力探针。
//
// 运行：
//   cd MyNASCore && dart probe_metadata_path.dart
//
// ── 这个探针回答什么，不回答什么 ────────────────────────────────
// 回答：对一个「已知的 source_id + relative_path」，各来源**要发什么请求**才能拿到
//      元数据、**能拿到哪些字段**、**文件不在了会怎样**。
// 不回答：真机兼容性。群晖/WebDAV 两节是「真适配器 + 真报文」，报文是本机 fixture
//      按协议形状给的 —— 与真机的一致性要靠 6.4b-1 的真机确认补
//      （脚本末尾打印了那条命令）。
//
// 为什么现在就要跑这个：`get_metadata` 的 response schema 不能凭想象写。
// 只能收「所有支持来源都稳定给得出」的字段，其余一律 null（null ≠ 0 / ≠ epoch）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'lib/adapter_contract.dart';
import 'lib/adapters/webdav.dart';
import 'lib/dio_compat.dart';
import 'lib/mock_transport.dart';
import 'lib/protocol.dart';
import 'lib/synology_api.dart';
import 'lib/upstream_file_types.dart';

void head(String text) {
  // ignore: avoid_print
  print('\n## $text');
}

void line(String text) {
  // ignore: avoid_print
  print('   $text');
}

/// 把 `FileItem` 摊平成「字段 → 值」的一行。**空值也要打印**：
/// 契约的关键不是「有 size」，而是「没有 size 时它是什么」。
///
/// ★ 时间一律带 `isUtc` 打印：群晖给的是 UTC，WebDAV 给的是**本地时间且不带偏移**，
/// 两者直接 `toIso8601String()` 出来长得一样，混在一起就是线上的时间错。
String fields(FileItem item) {
  String show(Object? value) => value == null ? 'null' : '$value';
  final mtime = item.modifiedTime;
  return '{name=${item.name}, isDir=${item.isDirectory}, size=${item.size}, '
      'mtime=${show(mtime?.toIso8601String())}${mtime == null ? '' : (mtime.isUtc ? 'Z(utc)' : ' (local!)')}, '
      'mime=${show(item.mimeType)}}';
}

// ─────────────────────────────────────────────────────────────
// A. 群晖：真 SynologyApi，只看它到底发了什么、拿回了什么
Future<void> synology() async {
  head('A. 群晖（真 SynologyApi + 录制/构造的设备回包）');

  final transport = MockTransport();
  final api = SynologyApi(transport, 'src-probe', requestBudget: const Duration(seconds: 5));
  final token = Cancellation();
  await api.discover(token);
  await api.login('probe', 'probe', token);

  final page = await api.listFiles('/允许共享/目标目录', 0, token);
  final list = transport.calls.lastWhere((c) => c.api == 'SYNO.FileStation.List' && c.method == 'list');
  line('直查一条路径要发的请求：POST ${list.path}  api=${list.api} method=${list.method}');
  line('参数：folder_path=${list.parameters['folder_path']}  limit=${list.parameters['limit']}');
  line('★ additional=${list.parameters['additional']}   ← 大小与时间就靠它');
  line('回包行数=${page.files.length}');
  for (final f in page.files.take(2)) {
    line('  ${f.name}  size=${f.size ?? 'null'}  mtime=${f.modifyTime?.toIso8601String() ?? 'null'}  type=${f.type}');
  }
  line('→ 结论：群晖的「按路径直查」= 列**父目录**一页（不是 stat），字段由 additional 决定。');

  // 设备不给 additional 时，字段是不是变成 0 / epoch？这才是冻结 schema 的关键。
  final bare = MockTransport(hook: (request, cancel) async {
    if (request.api == 'SYNO.FileStation.List' && request.method == 'list') {
      return {
        'success': true,
        'data': {
          'files': [
            {'name': '无附加字段.txt', 'path': '/允许共享/目标目录/无附加字段.txt', 'isdir': false},
          ],
          'offset': 0,
          'total': 1,
        },
      };
    }
    return null;
  });
  final api2 = SynologyApi(bare, 'src-probe-bare', requestBudget: const Duration(seconds: 5));
  await api2.discover(Cancellation());
  await api2.login('probe', 'probe', Cancellation());
  final page2 = await api2.listFiles('/允许共享/目标目录', 0, Cancellation());
  final only = page2.files.single;
  line('设备不返回 additional 时：size=${only.size ?? 'null'}  mtime=${only.modifyTime?.toIso8601String() ?? 'null'}');
  line('→ 结论：群晖缺字段得到的是 null。**不是 0、不是 1970**。');

  // 文件不在了：设备给一个空 files 数组。
  final empty = MockTransport(hook: (request, cancel) async {
    if (request.api == 'SYNO.FileStation.List' && request.method == 'list') {
      return {
        'success': true,
        'data': {'files': <Object?>[], 'offset': 0, 'total': 0},
      };
    }
    return null;
  });
  final api3 = SynologyApi(empty, 'src-probe-empty', requestBudget: const Duration(seconds: 5));
  await api3.discover(Cancellation());
  await api3.login('probe', 'probe', Cancellation());
  final page3 = await api3.listFiles('/允许共享/目标目录', 0, Cancellation());
  line('父目录里找不到那一条时：files=${page3.files.length}  total=${page3.total}');
  line('→ 结论：「路径不在」= 空列表（正常回包），不是异常 → 应映射成 file_not_found。');
}

// ─────────────────────────────────────────────────────────────
// B. WebDAV：真 WebDavAdapter + 本机真 HTTP 服务器
Future<void> webdav() async {
  head('B. WebDAV（真 WebDavAdapter + 本机真 HTTP fixture）');

  const user = 'probe', pass = 'probe-only';
  final expectedBasic = 'Basic ${base64Encode(utf8.encode('$user:$pass'))}';
  var body = _propfindFull;
  final seen = <String>[];

  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    if (request.headers.value('authorization') != expectedBasic) {
      request.response.statusCode = 401;
      request.response.headers.set('WWW-Authenticate', 'Basic realm="probe"');
      await request.response.close();
      return;
    }
    if (request.method == 'PROPFIND') {
      seen.add('${request.method} ${request.uri.path} depth=${request.headers.value('depth')}');
      request.response.statusCode = 207;
      request.response.headers.contentType = ContentType.parse('application/xml; charset=utf-8');
      request.response.write(body);
    } else {
      request.response.statusCode = 200;
    }
    await request.response.close();
  });

  final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:${server.port}'))..allowInsecureHTTP = true;
  final adapter = WebDavAdapter(dio: dio);
  final outcome = await adapter.login(username: user, password: pass);
  line('登录：$outcome');

  final items = await adapter.list('/允许共享/目标目录');
  line('直查一次父目录发出的请求：${seen.last}');
  line('★ 是 PROPFIND depth=1（列父目录），不是 depth=0 的 stat');
  for (final item in items) {
    line('  ${fields(item)}');
  }

  // 设备不给 getcontentlength / getlastmodified。
  body = _propfindBare;
  final bare = await adapter.list('/允许共享/目标目录');
  for (final item in bare) {
    line('缺 getcontentlength/getlastmodified 时：${fields(item)}');
  }
  line('→ ★ 结论（本轮最要紧的一条）：WebDAV 把「设备没说」折成了 size=0，');
  line('   而群晖保留 null。5.5 的 `FileItem.size` 是**非空 int**，它表达不了「未知」。');
  line('   所以 `get_metadata` 不能直接复用 `FileItem`：它的返回值里 size 必须是 `Int64?`，');
  line('   否则一个 0 字节文件与一个「服务器没说」的文件在 Agent 眼里完全一样。');

  // 文件不在了：entry 根本不在回包里。
  body = _propfindEmpty;
  final empty = await adapter.list('/允许共享/目标目录');
  line('父目录回包里没有那一条时：items=${empty.length}');
  line('→ 结论：与群晖一致——「不在」是一个正常回包里的空结果。');
  line('→ ★ 时间口径：群晖的 mtime 带 Z（UTC），WebDAV 出来的是**本地时间且不带偏移**；'
      '两者都 `toIso8601String()` 时长得一样。schema 必须钉死 UTC ISO8601（带 Z），'
      '否则同一份元数据在两条来源上差一个时区却看不出来。');

  await adapter.logout();
  await server.close(force: true);
}

const _propfindFull = '''<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/%E5%85%81%E8%AE%B8%E5%85%B1%E4%BA%AB/%E7%9B%AE%E6%A0%87%E7%9B%AE%E5%BD%95/</D:href>
    <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>
    <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
  <D:response>
    <D:href>/%E5%85%81%E8%AE%B8%E5%85%B1%E4%BA%AB/%E7%9B%AE%E6%A0%87%E7%9B%AE%E5%BD%95/%E9%A2%84%E7%AE%97%202026.xlsx</D:href>
    <D:propstat><D:prop><D:resourcetype/>
      <D:getcontentlength>9216</D:getcontentlength>
      <D:getlastmodified>Fri, 09 Oct 2026 11:30:00 GMT</D:getlastmodified>
      <D:getcontenttype>application/vnd.openxmlformats-officedocument.spreadsheetml.sheet</D:getcontenttype>
    </D:prop>
    <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
</D:multistatus>''';

const _propfindBare = '''<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/%E5%85%81%E8%AE%B8%E5%85%B1%E4%BA%AB/%E7%9B%AE%E6%A0%87%E7%9B%AE%E5%BD%95/</D:href>
    <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>
    <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
  <D:response>
    <D:href>/%E5%85%81%E8%AE%B8%E5%85%B1%E4%BA%AB/%E7%9B%AE%E6%A0%87%E7%9B%AE%E5%BD%95/%E6%97%A0%E5%AD%97%E6%AE%B5.bin</D:href>
    <D:propstat><D:prop><D:resourcetype/></D:prop>
    <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
</D:multistatus>''';

const _propfindEmpty = '''<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/%E5%85%81%E8%AE%B8%E5%85%B1%E4%BA%AB/%E7%9B%AE%E6%A0%87%E7%9B%AE%E5%BD%95/</D:href>
    <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>
    <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
</D:multistatus>''';

// ─────────────────────────────────────────────────────────────
// C. QNAP / 绿联：拿不到真机凭据，只能记录**代码事实**（明确标注，不冒充实测）
void brandStaticFacts() {
  head('C. QNAP / 绿联（静态事实：读适配器代码，未在真机确认）');
  line('QNAP   list → filesize ?? size；时间取自 modifyTime/createTime；size 可为 null');
  line('绿联   list → file["size"] 可能缺省；时间取自 file["time"] / modify_time');
  line('→ 两家都**没有** stat/单文件查询接口：按路径直查同样退化成「列父目录再挑一条」。');
  line('→ 字段可用性随固件/版本变化 ⇒ size 与 modified 在 schema 里必须可空。');
}

Future<void> main() async {
  // ignore: avoid_print
  print('# Phase 6.4b-0 ②：Provider 按路径直接取元数据的能力探针');
  await synology();
  await webdav();
  brandStaticFacts();
  head('D. 本机（真文件）见同一份证据的 local 段：stat 与 mdls 逐字段比对');
  head('真机确认（6.4b-1 开工前跑，需要账号密码，不写进仓）');
  line(r'FLASHFIND_E2E_NAS_HOST=… FLASHFIND_E2E_NAS_USER=… FLASHFIND_E2E_NAS_PASSWORD=… \');
  line(r'  swift test --filter RealNASE2ETests --only-use-versions-from-resolved-file');
}
