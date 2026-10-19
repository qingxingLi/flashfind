// 真实 WebDAV 端到端验证：本地真服务器 / 可切真机。
//
// 用法：
//   dart run test_webdav_live.dart                       # 打本机起的真 WebDAV 服务器
//   dart run test_webdav_live.dart \
//     --base-url http://192.168.2.2:5005 --user X --password Y   # 打真机（明文 HTTP）
//   dart run test_webdav_live.dart ... --evidence <目录>          # 结果同时落盘
//
// ── 为什么要有这个文件（而不是只用 test_adapters.dart 的 B 节）────────────
// test_adapters.dart 的 B 节 fixture 是「写死一份 207 响应」—— 不管请求什么路径都
// 吐同一份 XML。它能证明解析器不崩，但证明不了真实服务端的行为：
//   * 多层目录（list('/') 拿到的子目录，再用它 list 下去）
//   * href 与请求路径的对应（服务器 href 带完整绝对路径，适配器只取末段再重拼）
//   * 真实服务端对目录尾随斜杠的要求（不带 '/' 会 301）
//   * 属性取不到时服务器用第二个 propstat 报 404 的形态
// 这里起的是**真 HTTP 往返的真服务器**，上面每一条都是真实发生的。
//
// ── 这同时是真机校准入口 ──────────────────────────────────────────
// 拿到飞牛 5005 的凭据后，加 --base-url/--user/--password 即可跑同一套用例。
// 真机模式下「精确树」断言自动降级为「结构性」断言（不假设设备上有哪些文件）。
//
// ── 本机通过 ≠ 真机通过 ──────────────────────────────────────────
// 这个脚本在本机全绿，只说明**代码路径**在真实 HTTP 往返下是对的，
// 不代表任何一台真机可用。真机结论必须由真机的那一次运行给出。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'lib/adapter_contract.dart';
import 'lib/adapter_support.dart';
import 'lib/adapters/webdav.dart';
import 'lib/brand_session.dart';
import 'lib/dio_compat.dart';
import 'lib/protocol.dart';

// ───────────────────────────── 断言基座 ─────────────────────────────

int _passed = 0, _failed = 0;
final _failures = <String>[];
final _lines = <String>[];

void _out(String line) {
  _lines.add(line);
  // ignore: avoid_print
  print(line);
}

void _ok(String name) {
  _passed++;
  _out('  ok   $name');
}

void _fail(String name, Object error) {
  _failed++;
  _failures.add('$name :: $error');
  _out('  FAIL $name\n       $error');
}

Future<void> _check(String name, Future<void> Function() body) async {
  try {
    await body();
    _ok(name);
  } catch (error, stack) {
    _fail(
      name,
      '$error\n${stack.toString().split('\n').take(3).join('\n')}',
    );
  }
}

void _expectTrue(bool value, String message) {
  if (!value) throw StateError('期望为真：$message');
}

void _expectEqual(Object? actual, Object? expected, String message) {
  if (actual != expected) {
    throw StateError('$message：期望 $expected，实际 $actual');
  }
}

// ───────────────────────── 本地真 WebDAV 服务器 ─────────────────────────

/// 内存目录树。空目录用 children 为空表示（真实服务器里就是只有一个自身条目）。
class _DavNode {
  _DavNode.dir(this.name, [Map<String, _DavNode>? children])
      : isDir = true,
        size = 0,
        children = children ?? <String, _DavNode>{};

  _DavNode.file(this.name, this.size)
      : isDir = false,
        children = const <String, _DavNode>{};

  final String name;
  final bool isDir;
  final int size;
  final Map<String, _DavNode> children;
}

/// 所有条目共用一个固定的修改时间，方便断言。
const String _gmt = 'Fri, 09 Oct 2026 10:00:00 GMT';

_DavNode _buildTree() => _DavNode.dir('/', {
  '照片': _DavNode.dir('照片', {
    '2026': _DavNode.dir('2026', {
      '春节合影.jpg': _DavNode.file('春节合影.jpg', 2411724),
      '报告 final.pdf': _DavNode.file('报告 final.pdf', 524288),
    }),
    '头像.png': _DavNode.file('头像.png', 81920),
  }),
  '文档': _DavNode.dir('文档'), // 空目录：只回自身一条
  'readme.txt': _DavNode.file('readme.txt', 128),
});

/// 逐段百分号编码，保留 '/'（含尾随）。
String _encHref(String path) =>
    path.split('/').map(Uri.encodeComponent).join('/');

String _esc(String v) => v
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

/// 一条 <D:response>。注意：目录**不输出** getcontentlength ——
/// 适配器的受限解析器只认开闭标签对，不认自闭合，而真实服务器对目录本来也不给长度。
/// 另：文件项额外带一个 404 的 propstat，模拟「部分属性取不到」的真实形态，
/// 用来验证适配器只取含 200 的那个。
String _responseXml(_DavNode node, String href) {
  final b = StringBuffer();
  b.writeln('  <D:response>');
  b.writeln('    <D:href>${_encHref(href)}</D:href>');
  b.writeln('    <D:propstat>');
  b.writeln('      <D:prop>');
  b.writeln('        <D:displayname>${_esc(node.name)}</D:displayname>');
  b.writeln(
    '        <D:resourcetype>'
    '${node.isDir ? '<D:collection/>' : ''}'
    '</D:resourcetype>',
  );
  if (!node.isDir) {
    b.writeln('        <D:getcontentlength>${node.size}</D:getcontentlength>');
  }
  b.writeln(
    '        <D:getcontenttype>'
    '${node.isDir ? 'httpd/unix-directory' : 'application/octet-stream'}'
    '</D:getcontenttype>',
  );
  b.writeln('        <D:getetag>"etag-${node.name.hashCode}"</D:getetag>');
  b.writeln('        <D:getlastmodified>$_gmt</D:getlastmodified>');
  b.writeln('      </D:prop>');
  b.writeln('      <D:status>HTTP/1.1 200 OK</D:status>');
  b.writeln('    </D:propstat>');
  if (!node.isDir) {
    b.writeln('    <D:propstat>');
    b.writeln('      <D:prop><D:creationdate/></D:prop>');
    b.writeln('      <D:status>HTTP/1.1 404 Not Found</D:status>');
    b.writeln('    </D:propstat>');
  }
  b.writeln('  </D:response>');
  return b.toString();
}

/// 起一个真服务器，返回 (server, port, 请求记录)。
Future<(HttpServer, int, List<String>)> _startDavServer({
  required String user,
  required String pass,
}) async {
  final tree = _buildTree();
  final log = <String>[];
  final expected = 'Basic ${base64Encode(utf8.encode('$user:$pass'))}';

  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);

  server.listen((request) async {
    final method = request.method;
    final rawPath = request.uri.path;
    final auth = request.headers.value('authorization');
    log.add('$method ${request.uri.path}${request.uri.query.isEmpty ? '' : '?'} '
        '[depth=${request.headers.value('depth') ?? '-'}] '
        '[auth=${auth == null ? '匿名' : '已认证'}]');

    if (auth != expected) {
      request.response.statusCode = 401;
      request.response.headers
          .set('WWW-Authenticate', 'Basic realm="Restricted"');
      request.response.headers.contentType =
          ContentType.parse('text/plain; charset=utf-8');
      request.response.write('Not Authorized');
      await request.response.close();
      return;
    }

    // 目录不带尾随 '/' → 301（真实 WebDAV 服务的普遍行为）。
    // 适配器的 _fixSlashes 会补斜杠；这里另有一条裸 dio 用例专门确认「不补就会挂」。
    final node = _resolve(tree, rawPath);
    if (node != null && node.isDir && !rawPath.endsWith('/') && rawPath != '/') {
      request.response.statusCode = 301;
      request.response.headers.set('location', '${request.uri.path}/');
      await request.response.close();
      return;
    }

    switch (method) {
      case 'OPTIONS':
        request.response.statusCode = 200;
        request.response.headers.set('DAV', '1,2');
        request.response.headers.set('Allow', 'OPTIONS, GET, PROPFIND');
      case 'PROPFIND':
        if (node == null) {
          request.response.statusCode = 404;
          request.response.headers.contentType =
              ContentType.parse('text/plain; charset=utf-8');
          request.response.write('Not Found');
          break;
        }
        final depth = request.headers.value('depth') ?? '1';
        final body = StringBuffer()
          ..writeln('<?xml version="1.0" encoding="utf-8"?>')
          ..writeln('<D:multistatus xmlns:D="DAV:">');
        // 真实服务器：自身条目**排在第一个**（适配器靠这个跳过自身）。
        body.write(_responseXml(node, rawPath));
        if (depth != '0') {
          final base = rawPath.endsWith('/') ? rawPath : '$rawPath/';
          for (final child in node.children.values) {
            body.write(
              _responseXml(child, '$base${child.name}${child.isDir ? '/' : ''}'),
            );
          }
        }
        body.writeln('</D:multistatus>');
        request.response.statusCode = 207;
        request.response.headers.contentType =
            ContentType.parse('application/xml; charset=utf-8');
        request.response.write(body.toString());
      default:
        request.response.statusCode = 405;
    }
    await request.response.close();
  });

  return (server, server.port, log);
}

/// 按 URL 路径找节点。返回 null 表示不存在。
_DavNode? _resolve(_DavNode root, String rawPath) {
  String decoded;
  try {
    decoded = Uri.decodeFull(rawPath);
  } catch (_) {
    return null;
  }
  final segments =
      decoded.split('/').where((s) => s.isNotEmpty).toList();
  var cursor = root;
  for (final segment in segments) {
    final next = cursor.children[segment];
    if (next == null) return null;
    cursor = next;
  }
  return cursor;
}

// ───────────────────────────── 用例 ─────────────────────────────

class _Target {
  _Target(this.label, this.baseUrl, this.user, this.pass, {required this.strict});
  final String label;
  final String baseUrl;
  final String user;
  final String pass;
  final bool strict;
}

Dio _dioFor(_Target t) => Dio(BaseOptions(
      baseUrl: t.baseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 20),
      sendTimeout: const Duration(seconds: 20),
    ))
  ..allowInsecureHTTP = true;

Future<void> runSuite(_Target t, List<String> requestLog) async {
  _out('\n══ 目标：${t.label}（${t.baseUrl}）'
      '${t.strict ? ' · 精确树断言' : ' · 结构性断言'}');

  final before = requestLog.length;

  await _check('登录：匿名 401 → 升级 Basic → 重试成功', () async {
    final adapter = WebDavAdapter(dio: _dioFor(t));
    final outcome =
        await adapter.login(username: t.user, password: t.pass);
    _expectTrue(outcome is LoginSuccess, '期望登录成功，实际 $outcome');
    _expectTrue(adapter.sessionIdentity != null, '登录后应有会话身份');
    await adapter.logout();
  });

  await _check('握手是真实发生的（日志里能看到匿名首请求）', () async {
    if (!t.strict) {
      // 真机模式下第一次请求也可能被服务端直接接受，不作硬性断言。
      _out('        （真机模式：跳过匿名首请求的硬断言）');
      return;
    }
    final window = requestLog.sublist(before);
    _expectTrue(window.isNotEmpty, '服务器应记录到请求');
    _expectTrue(
      window.any((l) => l.contains('[auth=匿名]')),
      '应有一次匿名请求（401 → 重试的前提），实际日志：$window',
    );
    _expectTrue(
      window.any((l) => l.contains('[auth=已认证]')),
      '应有一次带凭据的请求，实际日志：$window',
    );
  });

  await _check('密码错误 → 返回 LoginRejected（不是抛异常）', () async {
    final adapter = WebDavAdapter(dio: _dioFor(t));
    final outcome =
        await adapter.login(username: t.user, password: '${t.pass}-wrong');
    _expectTrue(outcome is LoginRejected, '期望登录被拒，实际 $outcome');
    if (outcome is LoginRejected) {
      _expectTrue(outcome.reason.isNotEmpty, '拒绝原因不应为空');
    }
  });

  await _check('凭据只走请求头，不进 URL', () async {
    // 适配器全程把口令放在 Authorization；服务器只认头。
    // 若口令被拼进 URL，上面的登录与下面的列目录都会失败。
    final adapter = WebDavAdapter(dio: _dioFor(t));
    await adapter.login(username: t.user, password: t.pass);
    final roots = await adapter.shareRoots();
    _expectTrue(roots.isNotEmpty || !t.strict, '共享根不应为空');
    final window = requestLog.sublist(before);
    for (final line in window) {
      _expectTrue(
        !line.contains(t.pass),
        '请求行里不应出现口令：$line',
      );
    }
    await adapter.logout();
  });

  await _check('列共享根（根下的目录项）', () async {
    final adapter = WebDavAdapter(dio: _dioFor(t));
    await adapter.login(username: t.user, password: t.pass);
    final roots = await adapter.shareRoots();
    final names = roots.map((r) => r.name).toList();
    _out('        共享根：$names');
    if (t.strict) {
      // 注意：Dart 的 Set == Set 是**引用比较**，不能直接比内容。
      _expectTrue(
        names.length == 2 && names.contains('照片') && names.contains('文档'),
        '根下目录应只有 照片/文档 两个（readme.txt 是文件，不该出现），实际 $names',
      );
      for (final r in roots) {
        _expectTrue(
          !r.path.endsWith('/'),
          '共享根路径不应带尾随斜杠，实际 ${r.path}',
        );
      }
    } else {
      _expectTrue(
        roots.every((r) => r.path.isNotEmpty),
        '真机返回的共享根路径不应为空',
      );
    }
    await adapter.logout();
  });

  await _check('列目录（PROPFIND Depth:1）并正确区分目录/文件', () async {
    final adapter = WebDavAdapter(dio: _dioFor(t));
    await adapter.login(username: t.user, password: t.pass);
    final items = await adapter.list('/');
    _out('        根条目：${items.map((i) => "${i.name}${i.isDirectory ? '/' : ''}").toList()}');
    if (t.strict) {
      _expectEqual(items.length, 3, '根下应有 3 个条目');
      _expectTrue(
        items.any((i) => i.name == 'readme.txt' && !i.isDirectory && i.size == 128),
        'readme.txt 应被识别为 128 字节的文件',
      );
      _expectTrue(
        items.any((i) => i.name == '照片' && i.isDirectory),
        '照片 应被识别为目录',
      );
    } else {
      _expectTrue(items.isNotEmpty, '真机根目录不应为空');
    }
    await adapter.logout();
  });

  await _check('多层：进到子目录再列一层', () async {
    final adapter = WebDavAdapter(dio: _dioFor(t));
    await adapter.login(username: t.user, password: t.pass);
    // 关键：路径来自上一层的返回值（真实使用形态），而不是写死。
    final roots = await adapter.shareRoots();
    if (roots.isEmpty) {
      _out('        （该目标根下没有子目录，跳过）');
      await adapter.logout();
      return;
    }
    final first = roots.first;
    final level2 = await adapter.list(first.path);
    _out('        ${first.path} → ${level2.map((i) => "${i.name}${i.isDirectory ? '/' : ''}").toList()}');
    _expectTrue(
      level2.isNotEmpty || !t.strict,
      '${first.path} 下不应为空',
    );
    if (t.strict && first.name == '照片') {
      _expectTrue(
        level2.any((i) => i.name == '2026' && i.isDirectory),
        '照片 下应有子目录 2026',
      );
      _expectTrue(
        level2.any((i) => i.name == '头像.png' && !i.isDirectory),
        '照片 下应有文件 头像.png',
      );
    }
    // 再下钻一层（真机就到此为止，避免递归过深）
    final sub = level2.where((i) => i.isDirectory).toList();
    if (sub.isNotEmpty) {
      final level3 = await adapter.list(sub.first.path);
      _out('        ${sub.first.path} → ${level3.map((i) => i.name).toList()}');
      _expectTrue(level3.isNotEmpty || !t.strict, '${sub.first.path} 下不应为空');
    }
    await adapter.logout();
  });

  await _check('非 ASCII / 空格路径的百分号编码往返', () async {
    if (!t.strict) {
      _out('        （真机模式：无固定样本，仅在上一项里如实报告所见）');
      return;
    }
    final adapter = WebDavAdapter(dio: _dioFor(t));
    await adapter.login(username: t.user, password: t.pass);
    final level2 = await adapter.list('/照片');
    final names = level2.map((i) => i.name).toSet();
    _expectTrue(names.contains('2026'), '中文目录 照片 应能列出，实际 $names');
    final level3 = await adapter.list('/照片/2026');
    final names3 = level3.map((i) => i.name).toSet();
    _expectTrue(
      names3.contains('春节合影.jpg'),
      '中文文件名应正确编码/解码，实际 $names3',
    );
    _expectTrue(
      names3.contains('报告 final.pdf'),
      '含空格的文件名应正确编码/解码，实际 $names3',
    );
    final pdf = level3.firstWhere((i) => i.name == '报告 final.pdf');
    _expectEqual(pdf.size, 524288, '带空格文件的大小');
    await adapter.logout();
  });

  await _check('空目录：只回自身一条，应解析出 0 个子项（不是报错）', () async {
    if (!t.strict) {
      _out('        （真机模式：不假设存在空目录）');
      return;
    }
    final adapter = WebDavAdapter(dio: _dioFor(t));
    await adapter.login(username: t.user, password: t.pass);
    final items = await adapter.list('/文档');
    _expectEqual(items.length, 0, '空目录应返回 0 个子项');
    await adapter.logout();
  });

  await _check('不存在的路径 → PathMissing（不是空列表）', () async {
    final adapter = WebDavAdapter(dio: _dioFor(t));
    await adapter.login(username: t.user, password: t.pass);
    try {
      await adapter.list('/不存在的目录');
      throw StateError('不存在的路径竟然返回了结果');
    } on AdapterFailure catch (e) {
      _expectEqual(e.kind, 'PathMissing', '失败种类');
    }
    await adapter.logout();
  });

  await _check('服务端搜索必须明确报不支持（且不做全盘遍历）', () async {
    final adapter = WebDavAdapter(dio: _dioFor(t));
    await adapter.login(username: t.user, password: t.pass);
    final started = DateTime.now();
    try {
      await adapter.search('报告', roots: const ['/']);
      throw StateError('WebDAV 无服务端搜索，不该返回结果');
    } on AdapterFailure catch (e) {
      _expectEqual(e.kind, 'UnsupportedApi', '失败种类');
    }
    final ms = DateTime.now().difference(started).inMilliseconds;
    _expectTrue(ms < 1000, '必须在本地立刻拒绝，不该先摸网络（实测 ${ms}ms）');
    await adapter.logout();
  });

  await _check('会话层（BrandSession）串起 登录 → 共享 → 列目录 → 结果行', () async {
    final adapter = WebDavAdapter(dio: _dioFor(t));
    final session = BrandSession(
      adapter,
      sourceID: 'webdav-live',
      sourceName: 'WebDAV',
      smbHost: Uri.parse(t.baseUrl).host,
    );
    await session.login(t.user, t.pass, null);
    _expectTrue(session.isAuthenticated, '会话应处于已登录态');
    final shares = await session.shares();
    _expectTrue(shares.isNotEmpty || !t.strict, '共享列表不应为空');
    if (shares.isEmpty) {
      await session.disconnect();
      return;
    }
    await session.selectScopes([shares.first['path']! as String]);
    _expectTrue(session.scopeReady, '选定范围后应 ready');
    final rows = await session.list(shares.first['path']! as String, Cancellation());
    _out('        结果行示例：${rows.isEmpty ? '(空)' : rows.first}');
    for (final row in rows) {
      // 结果行必须与群晖路径逐字段同形（Swift 侧不分支）。
      for (final key in const [
        'id', 'name', 'path', 'fileType', 'size',
        'sourceID', 'sourceName', 'sourceType', 'isOnline', 'canOpen',
      ]) {
        _expectTrue(row.containsKey(key), '结果行缺字段 $key：$row');
      }
      _expectEqual(row['sourceType'], 'nas', 'sourceType');
    }
    // search 在没有服务端搜索能力时，会话层应给出 failed / unsupported，不抛。
    final outcome = await session.search('x', 'q1');
    _out('        会话搜索状态：${outcome.state} / ${outcome.error?.kind}');
    _expectTrue(
      outcome.state == 'failed',
      '会话层搜索结果状态应为 failed，实际 ${outcome.state}',
    );
    await session.disconnect();
  });

  await _check('能力声明：无服务端搜索 + verifiedOnDevice 反映适配器固有状态', () async {
    final caps = WebDavAdapter(dio: _dioFor(t)).capabilities;
    _expectEqual(caps.nativeSearch, false, 'nativeSearch');
    // verifiedOnDevice 是**适配器的固有属性**（真机点亮），
    // 与「本次运行打的是本机服务器还是真机」无关 —— 所以两种模式都断言 true。
    _expectEqual(caps.verifiedOnDevice, true, 'verifiedOnDevice');
    _expectTrue(caps.notes.contains('真机已验证'), 'notes 应写明真机已验证');
    _out('        notes：${caps.notes}');
  });

  if (t.strict) {
    await _check('对照：目录不带尾随斜杠时，服务器确实会 301（证明 _fixSlashes 有用）', () async {
      final dio = _dioFor(t);
      // 必须带**正确的** Basic 头，否则服务器先走 401 分支，走不到 301。
      final basic =
          'Basic ${base64Encode(utf8.encode('${t.user}:${t.pass}'))}';
      try {
        await dio.request<dynamic>(
          '/文档',
          method: 'PROPFIND',
          options: Options(
            method: 'PROPFIND',
            headers: {'depth': '1', 'authorization': basic},
          ),
        );
        throw StateError('裸请求 /文档（无尾随斜杠）竟然没被重定向');
      } on DioException catch (e) {
        _expectTrue(
          e.message.contains('重定向') || e.message.contains('来源'),
          '应报重定向被拒，实际：${e.message}',
        );
        _out('        裸请求确认：${e.message}');
      }
      // 而适配器把路径规范成 '/文档/' 后是能通的（上面「列目录」用例已证）。
    });
  }

  // ── 超时与取消：用「故意慢」的本机服务器，属传输层能力，与具体设备无关 ──
  if (t.strict) {
    final slow = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    slow.listen((request) async {
      await Future<void>.delayed(const Duration(seconds: 5));
      try {
        request.response.statusCode = 200;
        await request.response.close();
      } catch (_) {
        // 客户端已断开，正常。
      }
    });
    final slowBase = 'http://127.0.0.1:${slow.port}';

    await _check('Timeout：预算耗尽即失败，不挂死、不误报成密码错', () async {
      final dio = Dio(BaseOptions(
        baseUrl: slowBase,
        connectTimeout: const Duration(milliseconds: 600),
        receiveTimeout: const Duration(milliseconds: 600),
        sendTimeout: const Duration(milliseconds: 600),
      ))
        ..allowInsecureHTTP = true;
      final adapter = WebDavAdapter(dio: dio);
      final started = DateTime.now();
      final outcome = await adapter.login(username: 'u', password: 'p');
      final ms = DateTime.now().difference(started).inMilliseconds;
      _out('        实测 ${ms}ms（预算 600ms，服务器挂起 5s）');
      _expectTrue(outcome is! LoginSuccess, '不该登录成功，实际 $outcome');
      _expectTrue(ms < 3000, '应在预算附近返回，实测 ${ms}ms');
    });

    await _check('Cancel：令牌触发后立刻失败，不等满预算', () async {
      final dio = Dio(BaseOptions(
        baseUrl: slowBase,
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 20),
        sendTimeout: const Duration(seconds: 20),
      ))
        ..allowInsecureHTTP = true;
      final adapter = WebDavAdapter(dio: dio);
      final token = Cancellation();
      adapter.cancellation = token;
      Timer(const Duration(milliseconds: 300), () => token.cancel('Cancelled'));
      final started = DateTime.now();
      Object? thrown;
      LoginOutcome? outcome;
      try {
        outcome = await adapter.login(username: 'u', password: 'p');
      } catch (error) {
        thrown = error;
      }
      final ms = DateTime.now().difference(started).inMilliseconds;
      _out('        实测 ${ms}ms（预算 20s，300ms 时取消）');
      _expectTrue(outcome is! LoginSuccess, '取消后不该登录成功，实际 $outcome');
      _expectTrue(ms < 5000, '取消应立刻生效，实测 ${ms}ms');
      _expectTrue(
        thrown == null || thrown is CoreError || thrown is AdapterFailure,
        '取消应表现为 CoreError/AdapterFailure，实际 $thrown',
      );
    });

    await slow.close(force: true);
  } else {
    _out('        （真机模式：Timeout / Cancel 属传输层能力，由本机服务器用例覆盖）');
  }

  await _check('Logout：清空会话身份，且不抛异常', () async {
    final adapter = WebDavAdapter(dio: _dioFor(t));
    await adapter.login(username: t.user, password: t.pass);
    _expectTrue(adapter.sessionIdentity != null, '登录后应有会话身份');
    await adapter.logout();
    _expectTrue(adapter.sessionIdentity == null, '登出后应清空会话身份');
  });

  await _check('回归：目录项 path 不带尾随斜杠（否则 Scope 判 UnsafeLogicalPath 整表失败）', () async {
    if (!t.strict) {
      _out('        （真机模式：适配器行为由上一项如实报告）');
      return;
    }
    final adapter = WebDavAdapter(dio: _dioFor(t));
    await adapter.login(username: t.user, password: t.pass);
    final items = await adapter.list('/');
    final dirs = items.where((i) => i.isDirectory).toList();
    _expectTrue(dirs.isNotEmpty, '应有目录项用于本项断言');
    for (final dir in dirs) {
      _expectTrue(
        !dir.path.endsWith('/'),
        '目录项 path 不应带尾随斜杠：${dir.path}',
      );
    }
    // 会话层的跨品牌统一防线（fnos/ugreen 真机返回什么未知，靠这道兜住）。
    _expectEqual(BrandSession.normalizeLogicalPath('/a/b/'), '/a/b', '去尾随斜杠');
    _expectEqual(BrandSession.normalizeLogicalPath('/'), '/', '根保持不变');
    _expectEqual(BrandSession.normalizeLogicalPath('/a/b'), '/a/b', '已规范的不变');
    await adapter.logout();
  });
}

// ───────────────────────────── 主流程 ─────────────────────────────

Future<void> main(List<String> args) async {
  String? baseUrl, user, pass, evidence;
  var passwordFromStdin = false;

  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--base-url' && i + 1 < args.length) {
      baseUrl = args[++i];
    } else if (a == '--user' && i + 1 < args.length) {
      user = args[++i];
    } else if (a == '--password' && i + 1 < args.length) {
      pass = args[++i];
    } else if (a == '--password-stdin') {
      // 与项目里真机脚本的约定一致（run_realnas*.py --password-stdin）：
      // 口令从 stdin 读一行，避免它出现在进程命令行里（ps 可见）。
      passwordFromStdin = true;
    } else if (a == '--evidence' && i + 1 < args.length) {
      evidence = args[++i];
    }
  }

  if (passwordFromStdin) {
    final line = stdin.readLineSync();
    if (line == null || line.isEmpty) {
      _out('错误：指定了 --password-stdin，但 stdin 没有可读的一行');
      exitCode = 2;
      return;
    }
    pass = line;
  }

  final remote = baseUrl != null;
  if (remote && (user == null || pass == null)) {
    _out('错误：指定 --base-url 时必须同时给 --user 与 --password');
    exitCode = 2;
    return;
  }

  _out('闪寻 · WebDAV 真实端到端验证');
  _out('模式：${remote ? "真机（--base-url）" : "本机真 WebDAV 服务器"}');

  HttpServer? server;
  List<String> requestLog = <String>[];
  late _Target target;

  if (remote) {
    // baseUrl 已被 Dart 的类型提升认定非空（remote 由 baseUrl != null 得出），
    // 直接用即可；user / pass 走的是另一条提升路径，这里显式再确认一次。
    final account = user;
    final secret = pass;
    if (account == null || secret == null) {
      _out('内部错误：真机模式缺少凭据');
      exitCode = 2;
      return;
    }
    target = _Target('真机', baseUrl, account, secret, strict: false);
  } else {
    const u = 'nasuser', p = 'local-dav-only';
    final started = await _startDavServer(user: u, pass: p);
    server = started.$1;
    requestLog = started.$3;
    target = _Target(
      '本机真服务器',
      'http://127.0.0.1:${started.$2}',
      u,
      p,
      strict: true,
    );
  }

  final sw = Stopwatch()..start();
  try {
    await runSuite(target, requestLog);
  } finally {
    sw.stop();
     await server?.close(force: true);
  }

  _out('\n通过 $_passed 项，失败 $_failed 项，耗时 ${sw.elapsedMilliseconds}ms');
  if (_failures.isNotEmpty) {
    _out('\n失败明细：');
    for (final f in _failures) {
      _out('  - $f');
    }
  }

  if (evidence != null) {
    final dir = Directory(evidence);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final stamp = DateTime.now().toIso8601String();
    final summary = {
      'mode': remote ? 'remote' : 'local-real-server',
      'baseUrl': target.baseUrl,
      'user': target.user,
      'at': stamp,
      'passed': _passed,
      'failed': _failed,
      'failures': _failures,
    };
    File('${dir.path}/webdav-live-summary.json')
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(summary));
    File('${dir.path}/webdav-live-log.txt').writeAsStringSync(_lines.join('\n'));
    _out('\n证据已写入：${dir.path}');
  }

  exitCode = _failed == 0 ? 0 : 1;
}
