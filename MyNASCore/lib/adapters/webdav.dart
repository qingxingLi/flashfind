// WebDAV 品牌适配器（闪寻 FlashFind，零 pub 依赖）。
//
// 由上游 MyNAS 固定版本 2b1458e205e0 的两个文件移植到闪寻的窄接口 `NasBrandAdapter`：
//   lib/nas_adapters/webdav/webdav_file_system.dart （主要移植对象，314 行）
//   lib/nas_adapters/webdav/webdav_adapter.dart     （Dio / BaseOptions / 超时 / 认证组织，153 行）
//
// ── package:webdav_client 的替代（不引包）──────────────────────────
// 上游依赖 `webdav_client: ^1.2.2`。移植前对 pub-cache 里的包源码逐一核对，
// **实际被上游用到的**能力只有下面这些（其余 mkdir/remove/rename/copy/read/write/
// writeFromFile 属于写操作，窄接口不需要，不移植）：
//
//   上游调用点 (webdav_file_system.dart)      包内实现                         HTTP 自实现
//   ---------------------------------------  -------------------------------  -----------------------------------
//   :114 / :137  _client.readDir(path)       client.dart:64  readDir           PROPFIND <path>，Depth:1，要求 207
//   :209         _client.read(path)          client.dart:155 read              GET（仅文件流用；本适配器不移植）
//   adapter :71  _client.ping()              client.dart:51  ping              OPTIONS '/'，Depth:0，要求 200
//   adapter :66  setConnectTimeout(30000)    client.dart:39                    → BaseOptions.connectTimeout
//   adapter :67  setSendTimeout(60000)       client.dart:43                    → BaseOptions.sendTimeout
//   adapter :68  setReceiveTimeout(60000)    client.dart:47                    → BaseOptions.receiveTimeout
//   adapter :48  webdav.newClient(url,..)    client.dart:220 newClient         → 本适配器构造时注入的 Dio
//   adapter :54  _client.c.httpClientAdapter  webdav_dio.dart:38               → dio_compat 的 HttpClient（不在此声明）
//
// 这些方法在包内的真实 wire 语义（逐字保留的依据）：
//   * ping   → webdav_dio.dart:160 wdOptions：`OPTIONS /`，仅加头 `depth: 0`；client.dart:53 要求 statusCode==200。
//   * readDir→ client.dart:65 先 fixSlashes(path)（补前导+尾随 '/'），再 wdPropfind(self,path,true,fileXmlStr)：
//              webdav_dio.dart:181 方法 PROPFIND，body=fileXmlStr，
//              headers: depth:1 / content-type:application/xml;charset=UTF-8 /
//                       accept:application/xml,text/xml / accept-charset:utf-8 / accept-encoding:(空)；
//              webdav_dio.dart:190 要求 statusCode==207，否则抛响应错误。
//   * 认证   → auth.dart:46 Basic：`Authorization: Basic base64(user:pass)`；
//              webdav_dio.dart:91 首次以 NoAuth 发出，若 401 则读 `WWW-Authenticate`：
//                - 含 basic  → 升级为 BasicAuth 并**重试一次**（self.auth = BasicAuth(...)）；
//                - 含 digest → 升级为 DigestAuth（本移植**不实现 Digest**，见下）。
//   * 解析   → xml.dart:31 toFiles：见下方「受限 XML 提取器」区块。
//   * 时间串 → utils.dart:34 str2LocalTime：仅接受 "... GMT" 六段式，转本地时间。
//   * 路径   → utils.dart:106 fixSlashes / :114 join / :119 path2Name 逐字等价。
//
// 硬约束遵循：无 `import 'package:...'`；appL10n.xxx → 中文文案；logger.* → _log.*；
// StateError / _WebDavFileNotFound → AdapterFailure；不移植写操作与缩略图；
// 不把口令拼进 URL（只走 Authorization 头）。
//
// ── PROPFIND 受限 XML 提取器：能力边界（重要）───────────────────────
// 闪寻核心零 pub 依赖，`dart:core` 也没有 XML 解析器（不能引 `package:xml`），
// 因此这里用**正则**做受限提取。它**能**处理（覆盖 RFC 4918 + 常见服务端的 Depth:1
// 多状态响应）：
//   * 元素名带简单命名空间前缀（`D:` / `d:` / 无前缀），开闭标签前缀可不同；
//   * `<response>` 块内的 `<href>` / `<propstat>` / `<status>` / `<prop>` 及
//     resourcetype / getcontentlength / getcontenttype / getetag / creationdate /
//     getlastmodified 六个属性元素（按上游 field 顺序取用）；
//   * `<D:resourcetype><D:collection/></D:resourcetype>` 与自闭合 `<D:resourcetype/>`；
//   * href 的百分号编码（沿用上游 `Uri.decodeFull`）。
//   * href / 属性文本里的五个命名实体：&amp; &lt; &gt; &quot; &apos;。
// 它**不能**处理（一旦解析不出条目即抛 `ProtocolViolation`，**绝不静默返回空列表**）：
//   * CDATA 段 `<![CDATA[...]]>`（其内容不会被解码）；
//   * 数值字符引用（如 `&#xD;`）与上面五者之外的命名实体；
//   * 由属性承载语义的元素（本器只看元素文本，不看属性）；
//   * 前缀含 `:` 之外分隔符、或元素名含非 ASCII 的文档；
//   * 单行内 `>` 出现在属性值里的畸形文档（`[^>]*` 会被提前截断）；
//   * 注释 `<!-- <response> -->` 中恰好出现标签字样的文档（会被误匹配）。
// 另：本器对命名空间是**宽松**的（不校验前缀--URI 绑定），这与上游 xml 包
// `namespace: '*'` 的行为一致，属有意保留。
//
// ── 真机对照样本（主控只读探测；未认证、无写入/删除/加锁）─────
// 真机：一台飞牛 fnOS 设备，5005 端口开放的是真正的 WebDAV。
//
//   $ curl -s -i -m 8 -X PROPFIND -H 'Depth: 1' http://<设备地址>:5005/
//   HTTP/1.1 401 Unauthorized
//   Content-Type: text/plain; charset=utf-8
//   Www-Authenticate: Basic realm="Restricted"
//   X-Content-Type-Options: nosniff
//   Content-Length: 15
//   (body) Not Authorized
//
//   $ curl -s -i -m 8 -X PROPFIND -H 'Depth: 0' http://<设备地址>:5005/   -> 同上 401
//   $ curl -s -i -m 8 -X OPTIONS  -H 'Depth: 0' http://<设备地址>:5005/   -> 同上 401
//   $ curl -s -i -m 8                            http://<设备地址>:5005/   -> 同上 401
// 结论：(a) 该端口确是 Basic 认证的 WebDAV；(b) 无论 OPTIONS/PROPFIND/GET，未认证时
// 返回**完全一致**的 401 + `WWW-Authenticate: Basic realm="Restricted"`，证明本适配器
// 首次匿名请求 → 读 WWW-Authenticate → 升级 Basic → 重试的握手路径是必需的。
// 限制：因**未获授权**，本次未拿到任何认证后的 207 Multi-Status 真实样本；下方
// _parsePropfind 用一份**合成**样本自测，凡与真机不符处均列入「待确认」。
//
// 合成对照样本（非真机，仅说明解析器期望形态；前缀大小写/换行均可）：
//   <?xml version="1.0" encoding="utf-8"?>
//   <D:multistatus xmlns:D="DAV:">
//     <D:response>
//       <D:href>/dav/</D:href>
//       <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype>
//         <D:getlastmodified>Sun, 06 Nov 1994 08:49:37 GMT</D:getlastmodified>
//       </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
//     </D:response>
//     <D:response>
//       <D:href>/dav/%E7%85%A7%E7%89%87/</D:href>
//       <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype>
//         <D:getlastmodified>Mon, 07 Nov 1994 09:00:00 GMT</D:getlastmodified>
//       </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
//     </D:response>
//   </D:multistatus>
import 'dart:convert';

import '../adapter_contract.dart';
import '../adapter_support.dart';
import '../dio_compat.dart';
import '../error_kinds.dart';
import '../protocol.dart';
import '../upstream_file_types.dart' show FileItem;

/// 适配器日志入口。上游是全局 logger 并落盘 app.log；此处只写 stderr 且默认静默。
final _log = Logger();

/// 上游: webdav/xml.dart:6 —— PROPFIND 请求体，**逐字保留**（含单引号 xmlns 与制表符缩进）。
const String _propfindBody = '''<d:propfind xmlns:d='DAV:'>
			<d:prop>
				<d:displayname/>
				<d:resourcetype/>
				<d:getcontentlength/>
				<d:getcontenttype/>
				<d:getetag/>
				<d:getlastmodified/>
			</d:prop>
		</d:propfind>''';

/// 上游: webdav/utils.dart:8 —— str2LocalTime 认识的英文月份缩写。
const Map<String, String> _months = {
  'jan': '01',
  'feb': '02',
  'mar': '03',
  'apr': '04',
  'may': '05',
  'jun': '06',
  'jul': '07',
  'aug': '08',
  'sep': '09',
  'oct': '10',
  'nov': '11',
  'dec': '12',
};

/// 可选的简单命名空间前缀（如 `D:` / `d:`）。上游 xml 包用 `namespace: '*'` 宽松匹配。
const String _nsPrefixPattern = r'[A-Za-z_][\w.\-]*:';

/// resourcetype 内出现 `<collection/>`（带任意前缀）即判定为目录。
const String _collectionPattern = r'<(?:[A-Za-z_][\w.\-]*:)?collection\b';

/// 上游: webdav/xml.dart:101 —— webdav_client 的 `File`（内部结构，不对外暴露）。
class _WebdavEntry {
  const _WebdavEntry({
    required this.path,
    required this.name,
    required this.isDir,
    required this.size,
    required this.mimeType,
    required this.eTag,
    this.modifiedTime,
    this.createdTime,
  });

  final String path;
  final String name;
  final bool isDir;
  final int size;
  final String mimeType;
  final String eTag;
  final DateTime? modifiedTime;
  final DateTime? createdTime;

  @override
  String toString() =>
      '_WebdavEntry(path=$path, isDir=$isDir, size=$size, mime=$mimeType, '
      'eTag=$eTag, mTime=$modifiedTime, cTime=$createdTime)';
}

/// WebDAV 品牌适配器。
///
/// 构造：`Dio` 由外部注入（内含 baseUrl，等价上游 `ConnectionConfig.baseUrl`）。
/// WebDAV 常用明文 HTTP（真机 5005 即 http），因此来源配置须显式设置
/// `dio.allowInsecureHTTP = true`（dio_compat 的安全策略，不在本适配器内绕过）。
/// 超时沿用上游：connect 30s / send 60s / receive 60s，请在构造 Dio 的 BaseOptions 上设置。
class WebDavAdapter implements NasBrandAdapter {
  WebDavAdapter({required Dio dio}) : _dio = dio;

  final Dio _dio;

  Cancellation? _cancel;
  String? _username;
  String? _password;

  /// 上游 webdav_dio.dart:99 的 `self.auth`：协商出的 Basic 头，登录后持久化。
  String? _authHeader;

  String? _identity;

  @override
  String get vendor => 'webdav';

  @override
  String? get sessionIdentity => _identity;

  /// harness 在每次查询前注入取消令牌。这里同时下发给 dio 兼容层，
  /// 让在飞的请求被真实 abort（而不是只让 Future 晚点返回）。
  @override
  set cancellation(Cancellation token) {
    _cancel = token;
    _dio.cancellation = token;
  }

  /// 能力声明。
  ///
  /// `verifiedOnDevice = true` —— **有真机证据**，不是「移植完就点亮」。
  /// 已验证范围仅此一台设备与该账号，`notes` 里逐条写明验到什么、没验什么。
  @override
  BrandCapabilities get capabilities => const BrandCapabilities(
    nativeSearch: false,
    verifiedOnDevice: true,
    querySemantics:
        'WebDAV 协议不提供服务端搜索；按契约抛 UnsupportedApi，'
        '绝不回退成全盘递归遍历（那会在大型 NAS 上把设备拖垮）。',
    notes:
        '真机已验证（验证端口 5005）：匿名 OPTIONS 得 401 + WWW-Authenticate: Basic '
        '→ 升级 Basic → 重试 200；'
        'PROPFIND Depth:1 得 207 Multi-Status 并正确解析（对无此属性的条目，'
        '服务器用第二个 propstat 报 404，解析器只取含 200 的 propstat）；'
        '空格路径与中文路径的百分号编码/解码正确；'
        '404 映射为 PathMissing、401/403 映射为 SessionExpired；'
        '结果行与群晖逐字段同形（含 openTarget）。'
        '搜索为 UnsupportedApi（WebDAV 无服务端搜索）。'
        '已知限制：仅实现 Basic，不实现 Digest（上游支持）——只发 Digest 挑战的设备会抛 UnsupportedApi；'
        '响应解析为受限正则提取器，对 CDATA / 数值字符引用 / 非 D: 前缀等形态'
        '可能失败并按 ProtocolViolation 报错。'
        '已验证范围仅此一台设备与该账号。',
  );

  // ─────────────────────────── 登录 ───────────────────────────

  /// 上游: webdav_adapter.dart:39-92（connect）+ webdav_client client.dart:51（ping）。
  ///
  /// 真机语义：首次匿名 `OPTIONS /`（Depth:0）通常得到 401 + `WWW-Authenticate: Basic`，
  /// 由 [_send] 按 webdav_dio.dart:91 升级为 Basic 后重试；重试仍非 200 即判登录失败。
  @override
  Future<LoginOutcome> login({
    required String username,
    required String password,
    String? otpCode,
  }) async {
    _identity = null;
    // 重置认证状态：等价上游每次 connect 里 newClient 的初始 NoAuth 态
    // （webdav_client client.dart:225 auth: Auth(...) → AuthType.NoAuth）。
    _authHeader = null;
    _username = username;
    _password = password;
    _cancel?.check();

    _log
      ..i('WebDavAdapter: 开始连接')
      ..i('WebDavAdapter: 目标地址 => ${Logger.safeUrl(_dio.baseUrl)}')
      ..i('WebDavAdapter: 用户名 => $username');

    try {
      // 上游: webdav_adapter.dart:71 `_client!.ping()`；webdav_dio.dart:160 头 depth: 0。
      final response = await _send(
        'OPTIONS',
        _urlFor('/'),
        headers: const {'depth': '0'},
      );
      final status = response.statusCode ?? 0;
      _log.i('WebDavAdapter: ping(OPTIONS /) status=$status');

      if (status == 200) {
        // OPTIONS 通过**不等于密码正确**——不少服务器对匿名 OPTIONS 也回 200，
        // 凭据根本没被碰过。曾因此出现「假登陆」：账号密码错了照样显示已登录，
        // 直到列目录才莫名失败。所以紧跟着对同一个根发一次**带凭据**的
        // PROPFIND Depth:0，把验证做实；失败类别与下面 OPTIONS 的分诊一致。
        final check = await _send(
          'PROPFIND',
          _urlFor('/'),
          data: _propfindBody,
          contentType: 'application/xml;charset=UTF-8',
          headers: const {
            'depth': '0',
            'accept': 'application/xml,text/xml',
            'accept-charset': 'utf-8',
          },
        );
        final checkStatus = check.statusCode ?? 0;
        _log.i('WebDavAdapter: 凭据验证(PROPFIND depth:0) status=$checkStatus');
        if (checkStatus == 200 || checkStatus == 207) {
          // 上游: webdav_adapter.dart:84 `'webdav-${DateTime.now().millisecondsSinceEpoch}'`。
          // 窄接口要求「同一账号重登必须换一个身份」，毫秒时间戳天然保证每次不同。
          _identity = 'webdav-${DateTime.now().millisecondsSinceEpoch}';
          _log.i('WebDavAdapter: 连接成功（凭据已验证）');
          return LoginSuccess(identity: _identity!);
        }
        if (checkStatus == 401) {
          return const LoginRejected('账号或密码不正确', apiCode: 401);
        }
        if (checkStatus == 403) {
          return const LoginRejected('该账号没有访问此位置的权限', apiCode: 403);
        }
        if (checkStatus == 404) {
          return const LoginRejected(
            'WebDAV 路径不存在——请检查「路径」填写（OpenList / Alist 通常是 /dav）。',
            apiCode: 404,
          );
        }
        if (checkStatus == 405) {
          return const LoginRejected(
            '这个地址上没有 WebDAV 服务（服务器拒绝了列目录请求）。'
            'OpenList / Alist 的 WebDAV 端点通常在 /dav 子路径，请填到「路径」里。',
            apiCode: 405,
          );
        }
        if (checkStatus >= 300 && checkStatus < 400) {
          return LoginRejected(
            '服务器把这个地址重定向到了别处（HTTP $checkStatus）。'
            '最常见的原因：开着「明文 HTTP」但服务要求加密连接——请关掉这个开关再试。',
            apiCode: checkStatus,
          );
        }
        return LoginRejected(
          'WebDAV 服务未返回可用状态（HTTP $checkStatus）',
          apiCode: checkStatus,
        );
      }
      // 上游 ping 只认 200，其余一律是失败；这里给出更可读的中文原因。
      if (status == 401) {
        return const LoginRejected('账号或密码不正确', apiCode: 401);
      }
      if (status == 403) {
        return const LoginRejected('该账号没有访问此位置的权限', apiCode: 403);
      }
      if (status == 405) {
        // 与 _readDir 的 405 同因：站点根是 Web 界面不是 WebDAV。
        return const LoginRejected(
          '这个地址上没有 WebDAV 服务（服务器拒绝了探测请求）。'
          'OpenList / Alist 的 WebDAV 端点通常在 /dav 子路径，请填到「路径」里。',
          apiCode: 405,
        );
      }
      if (status >= 300 && status < 400) {
        // 实测：http 打 https 端口时 nginx 回 302。明文开关该关。
        return LoginRejected(
          '服务器把这个地址重定向到了别处（HTTP $status）。'
          '最常见的原因：开着「明文 HTTP」但服务要求加密连接——请关掉这个开关再试。',
          apiCode: status,
        );
      }
      return LoginRejected('WebDAV 服务未返回可用状态（HTTP $status）', apiCode: status);
    } on DioException catch (error) {
      _cancel?.check(); // 取消不能被吞掉
      _log.e('WebDavAdapter: 连接失败', error);
      if (_isServiceRedirect(error)) {
        // 开着「明文 HTTP」去打一个 https 端口时，nginx 会回 302 → https
        // （实测于 openlist.demo-nas.example）。用户看到的就是这个现象，
        // 「拒绝跟随」只是安全事实，必须把可操作的动作（关开关）说出来。
        return const LoginRejected(
          '服务器把这个地址重定向到了别处，闪寻不自动跟随。'
          '最常见的原因：开着「明文 HTTP」但服务要求加密连接——请关掉这个开关再试。',
          apiCode: 301,
        );
      }
      return LoginRejected('无法连接 WebDAV 服务（${error.message}）');
    }
  }

  // ───────────────────────── 共享根 ─────────────────────────

  /// WebDAV 没有「共享」这一协议概念，其可授权范围就是已配置的 baseUrl 根。
  /// 与 fnos 适配器同构：把根目录下的**目录项**作为候选共享根返回。
  /// 若 baseUrl 直接指向单个分享，则这里返回的是该分享下的子目录 —— 属已知歧义（见待确认）。
  @override
  Future<List<ShareRoot>> shareRoots() async {
    _cancel?.check();
    _log.i('WebDavAdapter: 枚举共享根（PROPFIND 根目录，取其中目录项）');
    final entries = await list('/');
    final dirs = entries.where((entry) => entry.isDirectory).toList();
    if (dirs.isEmpty) {
      // 「连上了但 0 个可搜索位置」曾只给一句「账号确实没有共享目录」，
      // 用户明明在网页上看得见文件夹。把证据说清：根目录有没有条目、
      // 该把「路径」填到哪一层。
      throw AdapterFailure(ErrorKind.emptyScope,
        entries.isEmpty
            ? '登录成功，但 WebDAV 根目录是空的。'
                '如果你的文件在某个子路径（例如 OpenList 的某个存储）里，'
                '请把「路径」填到那一层再连。'
            : '登录成功：WebDAV 根目录下有 ${entries.length} 个条目，但没有一个是文件夹。'
                '如果你的文件在某个子路径里，请把「路径」填到那一层再连。',
      );
    }
    return dirs
        .map(
          (entry) => ShareRoot(
            name: entry.name,
            // 上游 dir 路径带尾随 '/'（xml.dart:99），这里规范成无尾随，
            // 否则 '/a/' 会被 Scope.validate 判为含空段（UnsafeLogicalPath）。
            path: _stripTrailingSlash(entry.path),
          ),
        )
        .toList();
  }

  // ───────────────────────── 列目录 ─────────────────────────

  /// 上游: webdav_file_system.dart:109-128 listDirectory。
  @override
  Future<List<FileItem>> list(String path) async {
    // 上游: webdav_file_system.dart:111 —— 空路径规整为根。
    final normalizedPath = path.isEmpty ? '/' : path;
    _log.d('WebDavFileSystem: listDirectory => $normalizedPath');

    try {
      // 上游: webdav_file_system.dart:113 —— 同样用 _withRetry 包裹（仅对可重试错误）。
      return await _withRetry(() async {
        final entries = await _readDir(normalizedPath);
        return entries.map(_toFileItem).toList();
      }, action: 'listDirectory');
    } on DioException catch (error) {
      _cancel?.check();
      throw _translateDio(error, '列目录');
    }
  }

  /// 上游: webdav_file_system.dart:114 `_client.readDir(path)` →
  /// webdav_client client.dart:64 → webdav_dio.dart:178 wdPropfind。
  Future<List<_WebdavEntry>> _readDir(String logicalPath) async {
    final webPath = _fixSlashes(logicalPath); // 上游 client.dart:65
    final url = _urlFor(webPath);

    // 上游: webdav_dio.dart:181-188 —— 方法 PROPFIND + 逐字保留的请求头。
    // 注意 content-type 走 Options.contentType（dio_compat 会跳过 headers 里的同名键，
    // 因为它由 contentType 单独下发），行为与上游一致。
    final response = await _send(
      'PROPFIND',
      url,
      data: _propfindBody,
      contentType: 'application/xml;charset=UTF-8',
      headers: const {
        'depth': '1',
        'accept': 'application/xml,text/xml',
        'accept-charset': 'utf-8',
        'accept-encoding': '',
      },
    );

    final status = response.statusCode ?? 0;
    // 上游: webdav_dio.dart:190 —— 只接受 207 Multi-Status。
    if (status == 207) {
      return _parsePropfind(response.data ?? '', webPath);
    }
    if (status == 401 || status == 403) {
      _identity = null;
      throw AdapterFailures.sessionExpired(status);
    }
    if (status == 404) {
      throw AdapterFailures.pathMissing('WebDAV 路径不存在：$logicalPath');
    }
    if (status == 405) {
      // 真机实测（openlist.demo-nas.example）：对站点根 PROPFIND
      // 正是 405——那台服务的 Web 界面在根上，WebDAV 端点在 /dav。
      // 用户看到裸 405 无从下手，必须把「去填路径」直接说出来。
      throw AdapterFailures.unsupported(
        '这个地址上没有 WebDAV 目录服务（服务器拒绝了目录查询）。'
        'OpenList / Alist 的 WebDAV 端点通常在 /dav 子路径，请填到「路径」里再连。',
      );
    }
    if (status == 429) {
      // 同一台服务实测：无凭据、错凭据的 PROPFIND /dav 也全是 429 ——
      // 这是服务器侧限流，与账号密码无关。客户端重试只会延长限制，
      // 文案必须明确劝停，而不是让人反复点「连接」。
      throw const AdapterFailure(ErrorKind.rateLimited,
        '服务器在限流：请求过于频繁（HTTP 429），与账号密码无关。'
        '请等几分钟再试；反复点「连接」只会让限制持续更久。',
        apiCode: 429,
      );
    }
    if (status >= 300 && status < 400) {
      // 实测同一台服务：http 打 443 时 nginx 回 302 → https。
      // 用户开着明文开关打 https 端口就是这个现象，直接告诉他关开关。
      throw AdapterFailures.protocolViolation(
        '服务器把这个地址重定向到了别处（HTTP $status）。'
        '最常见的原因：开着「明文 HTTP」但服务要求加密连接——请关掉这个开关再试。',
      );
    }
    throw AdapterFailures.protocolViolation(
      'WebDAV 服务没有返回目录列表（HTTP $status）',
    );
  }

  // ───────────────────────── 搜索 ─────────────────────────

  /// 上游: webdav_file_system.dart:296 `search(...) => []`（返回空即静默吞掉）。
  /// 契约要求：设备没有服务端搜索时**必须**抛 UnsupportedApi，且**不得**回退成
  /// 客户端递归遍历 —— 上游那个「返回空列表」的写法正是契约要修掉的坑。
  @override
  Future<List<FileItem>> search(String query, {required List<String> roots}) async {
    _cancel?.check();
    _log.w('WebDavAdapter: search 被调用，但 WebDAV 无服务端搜索');
    throw AdapterFailures.unsupported('WebDAV 不提供服务端搜索');
  }

  // ─────────────────────────── 登出 ───────────────────────────

  /// 上游: webdav_adapter.dart:94-106 disconnect —— 只是关闭文件系统的 Dio。
  /// WebDAV Basic 认证没有服务端会话需要注销，故这里只清空本地认证状态；
  /// 注入的 Dio 归调用方所有，不在此处置为 closed。
  @override
  Future<void> logout() async {
    _authHeader = null;
    _identity = null;
    _username = null;
    _password = null;
    _log.i('WebDavAdapter: 已清除会话状态');
  }

  // ─────────────────────── 传输与认证 ───────────────────────

  /// 上游: webdav_dio.dart:91-134 —— 首次（或未持 Basic 时）请求后处理 401：
  /// 读 `WWW-Authenticate`，含 basic 则升级为 Basic 并**重试一次**。
  Future<Response<String>> _send(
    String method,
    String url, {
    Object? data,
    Map<String, dynamic>? headers,
    String? contentType,
  }) async {
    var response = await _request(
      method,
      url,
      data: data,
      headers: headers,
      contentType: contentType,
    );

    if (response.statusCode == 401) {
      final challenge =
          response.headers.value('www-authenticate')?.toLowerCase() ?? '';
      // 上游也支持 Digest（auth.dart:53）；本移植按任务要求只实现 Basic，
      // Digest 明确报 UnsupportedApi，不静默降级、不猜测。
      if (challenge.contains('digest') && !challenge.contains('basic')) {
        throw AdapterFailures.unsupported('WebDAV 服务要求 Digest 认证，当前仅实现 Basic');
      }
      if (challenge.contains('basic') && _authHeader == null) {
        if (_username == null || _password == null) {
          throw AdapterFailures.authFailed('缺少用于 WebDAV Basic 认证的账号或密码');
        }
        // 上游: webdav_dio.dart:106 `self.auth = BasicAuth(...)` —— 持久化后重试。
        _authHeader = _basicHeader();
        response = await _request(
          method,
          url,
          data: data,
          headers: headers,
          contentType: contentType,
        );
      }
    }
    return response;
  }

  /// 上游: webdav_dio.dart:54-89 req —— 组头（含 authorization）并发请求。
  /// 说明：上游默认 responseType=json；dio_compat 的 json 分支对非 JSON 正文（真机
  /// 401 正文是 `Not Authorized` 纯文本）会抛「响应不是合法 JSON」，故这里改用 plain，
  /// 与上游「正文按原文返回」的效果等价。
  Future<Response<String>> _request(
    String method,
    String url, {
    Object? data,
    Map<String, dynamic>? headers,
    String? contentType,
  }) {
    _cancel?.check();
    return _dio.request<String>(
      url,
      method: method,
      data: data,
      options: Options(
        method: method,
        headers: {
          ...?headers,
          // 上游: auth.dart:46 —— 口令只进 Authorization 头，绝不拼进 URL。
          if (_authHeader != null) 'authorization': _authHeader,
        },
        contentType: contentType,
        responseType: ResponseType.plain,
        // 自行判定状态码：401 必须留给 401→Basic 握手，不能被 dio 提前当失败抛掉。
        validateStatus: (status) => true,
      ),
    );
  }

  /// 上游: auth.dart:46-49 BasicAuth.authorize。
  String _basicHeader() =>
      'Basic ${base64Encode(utf8.encode('${_username ?? ''}:${_password ?? ''}'))}';

  // ─────────────────────── 错误与重试 ───────────────────────

  /// 上游: webdav_file_system.dart:55-93 _withRetry（maxRetries=2，退避 500ms*attempt）。
  Future<T> _withRetry<T>(
    Future<T> Function() operation, {
    int maxRetries = 2,
    String? action,
  }) async {
    Object? lastError;
    StackTrace? lastStackTrace;

    for (var attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        return await operation();
      } catch (e, st) {
        lastError = e;
        lastStackTrace = st;
        if (!_isRetryableError(e)) rethrow; // 上游: webdav_file_system.dart:71
        if (attempt < maxRetries) {
          _log.w('WebDavFileSystem: ${action ?? "操作"}失败，重试 ($attempt/$maxRetries)');
          await Future<void>.delayed(Duration(milliseconds: 500 * attempt));
        }
      }
    }

    // 上游此处走 AppError.handle 上报；闪寻无等价物，仅落诊断日志。
    _log.e('WebDavFileSystem.${action ?? "操作"}', lastError ?? lastStackTrace);
    throw lastError!;
  }

  /// 上游: webdav_file_system.dart:96-107 _isRetryableError（逐字保留判定集合）。
  bool _isRetryableError(Object e) {
    if (e is DioException) {
      return e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.connectionError;
    }
    final msg = e.toString().toLowerCase();
    return msg.contains('connection') ||
        msg.contains('timeout') ||
        msg.contains('socket');
  }

  /// dio_compat 对 3xx 一律判失败且**不带 response**（见 dio_compat.dart:334）。
  bool _isServiceRedirect(DioException error) =>
      error.type == DioExceptionType.badResponse &&
      error.message.contains('重定向');

  /// 把 DioException 翻成中文可读的 AdapterFailure。3xx 按任务要求显式判定并给明确错误。
  AdapterFailure _translateDio(DioException error, String action) {
    if (_isServiceRedirect(error)) {
      // 例：请求 `/dir` 被 301 到 `/dir/`。上游靠 fixSlashes 规避；若仍发生则明确报错。
      // 明文打 https 端口也会走到这里（302），必须点出明文开关。
      return AdapterFailures.protocolViolation(
        '服务器把这个地址重定向到了别处（$action），闪寻不自动跟随。'
        '若服务在别的子路径请改「路径」；若开着「明文 HTTP」请关掉它再试。',
      );
    }
    final status = error.response?.statusCode;
    if (status == 401) return AdapterFailures.sessionExpired(status);
    if (status == 403) return AdapterFailures.permissionDenied('该账号没有访问此位置的权限', status);
    if (status == 404) return AdapterFailures.pathMissing('$action：WebDAV 路径不存在（HTTP 404）');
    if (status == 405) return AdapterFailures.unsupported('WebDAV 服务不支持该操作（HTTP 405）');
    return AdapterFailures.network('$action 失败：${error.message}');
  }

  // ────────────────────── 映射与路径工具 ──────────────────────

  /// 上游: webdav_file_system.dart:115-126 —— FileItem 映射（字段一一对应）。
  ///
  /// ★ 与上游的唯一有意差异：**目录项的 path 去掉尾随 '/'**。
  /// 上游 xml.dart:99 给目录拼出的 path 是 `'<请求路径><名字>/'`（带尾随斜杠），
  /// 而闪寻的 `Scope.validate` 会把含空段的路径判为 `UnsafeLogicalPath` ——
  /// 于是**用户每往下浏览一层目录，整份列表就会失败**。
  /// `shareRoots()` 早先已单独 strip 过一次（见那里的注释），但 list 这条路径漏了；
  /// 本机真服务器用例（test_webdav_live.dart）把它暴露出来。
  FileItem _toFileItem(_WebdavEntry f) {
    final fileName = PathCompat.basename(f.path);
    return FileItem(
      name: fileName.isEmpty ? f.name : fileName,
      path: _stripTrailingSlash(f.path),
      isDirectory: f.isDir,
      size: f.size,
      modifiedTime: f.modifiedTime,
      createdTime: f.createdTime,
      extension: f.isDir ? null : PathCompat.extension(f.name),
    );
  }

  /// 上游: webdav/utils.dart:106 fixSlashes —— 补前导与尾随 '/'。
  String _fixSlashes(String value) {
    var v = value.startsWith('/') ? value : '/$value';
    if (!v.endsWith('/')) v = '$v/';
    return v;
  }

  /// 上游: webdav/utils.dart:114 join —— rtrim(base,'/') + '/' + ltrim(path,'/')。
  String _joinUrl(String base, String path) {
    var b = base;
    while (b.endsWith('/')) b = b.substring(0, b.length - 1);
    var p = path;
    while (p.startsWith('/')) p = p.substring(1);
    return '$b/$p';
  }

  /// 上游: webdav_dio.dart:83 —— `${join(self.uri, path)}`。
  String _urlFor(String webPath) => _joinUrl(_dio.baseUrl, webPath);

  String _stripTrailingSlash(String value) {
    var v = value;
    while (v.length > 1 && v.endsWith('/')) v = v.substring(0, v.length - 1);
    return v;
  }

  // ─────────────── 受限 PROPFIND XML 提取器 ───────────────

  /// 上游: webdav/xml.dart:31-117 WebdavXml.toFiles（skipSelf 与字段顺序逐字保留）。
  ///
  /// 上游 process：遍历所有 `<response>`；对每个 response，取其 `<propstat>` 中
  /// `<status>` 含 '200' 者，在其 `<prop>` 内解析字段；第一个 200-prop 视为「自身」
  /// 条目被跳过（必须是目录，否则上游抛 `xml parse error(405)`）。
  List<_WebdavEntry> _parsePropfind(String xml, String requestPath) {
    final responses = _blocks(xml, 'response');
    if (responses.isEmpty) {
      // 契约硬要求：解析不出条目**必须**报 ProtocolViolation，绝不静默返回空列表。
      throw AdapterFailures.protocolViolation(
        'PROPFIND 响应里没有任何 <response> 条目（受限解析器无法识别的 XML 形态）',
      );
    }

    final entries = <_WebdavEntry>[];
    var skipSelf = true;
    try {
      for (final response in responses) {
        final href = _firstText(response, 'href') ?? '';
        for (final propstat in _blocks(response, 'propstat')) {
          // 上游: xml.dart:46 —— 只看 status 含 '200' 的 propstat。
          final status = _firstText(propstat, 'status');
          if (status == null || !status.contains('200')) continue;

          for (final prop in _blocks(propstat, 'prop')) {
            // 上游: xml.dart:49-54 —— resourcetype/collection → isDir。
            final resType = _firstText(prop, 'resourcetype');
            final isDir = resType != null && RegExp(_collectionPattern).hasMatch(resType);

            // 上游: xml.dart:57-63 —— 跳过自身条目。
            if (skipSelf) {
              skipSelf = false;
              if (isDir) break;
              throw AdapterFailures.protocolViolation('XML 解析错误（405）');
            }

            // 上游: xml.dart:66-94 —— 按 mimeType / size / eTag / cTime / mTime 顺序取字段。
            final mimeType = _firstText(prop, 'getcontenttype') ?? '';
            var size = 0;
            if (!isDir) {
              final sizeText = _firstText(prop, 'getcontentlength');
              if (sizeText != null) {
                final parsed = int.tryParse(sizeText.trim());
                if (parsed == null) {
                  throw AdapterFailures.protocolViolation(
                    'getcontentlength 不是整数：$sizeText',
                  );
                }
                size = parsed;
              }
            }
            final eTag = _firstText(prop, 'getetag') ?? '';
            final createdText = _firstText(prop, 'creationdate');
            final createdTime = createdText == null
                ? null
                : DateTime.parse(createdText.trim()).toLocal();
            final modifiedTime = _str2LocalTime(_firstText(prop, 'getlastmodified'));

            // 上游: xml.dart:97-99 —— href 解码后取末段，path 用**请求的逻辑路径**重拼。
            final decodedHref = href.isEmpty ? '' : Uri.decodeFull(href);
            final name = _path2Name(decodedHref);
            final filePath = '$requestPath$name${isDir ? '/' : ''}';

            entries.add(
              _WebdavEntry(
                path: filePath,
                name: name,
                isDir: isDir,
                size: size,
                mimeType: mimeType,
                eTag: eTag,
                modifiedTime: modifiedTime,
                createdTime: createdTime,
              ),
            );
            break; // 上游: xml.dart:111 —— 一个 prop 处理完即跳出。
          }
        }
      }
    } on AdapterFailure {
      rethrow;
    } catch (error) {
      // 任何格式问题（坏日期、坏编码、坏整数…）统一收敛为 ProtocolViolation。
      throw AdapterFailures.protocolViolation('PROPFIND 响应解析失败：$error');
    }
    return entries;
  }

  /// 匹配一个元素块并捕获其内文；前缀可不同、可无前缀。
  RegExp _elementRegex(String tag) => RegExp(
    '<(?:$_nsPrefixPattern)?$tag\\b[^>]*>(.*?)</(?:$_nsPrefixPattern)?$tag>',
    dotAll: true,
  );

  List<String> _blocks(String xml, String tag) =>
      _elementRegex(tag).allMatches(xml).map((m) => m.group(1)!).toList();

  String? _firstText(String xml, String tag) {
    final match = _elementRegex(tag).firstMatch(xml);
    return match == null ? null : _unescapeXml(match.group(1)!);
  }

  /// 仅解码五个命名实体（数值引用不处理，已在文件头声明为不支持）。
  /// `&amp;` 放最后，避免把 `&amp;lt;` 二次解码成 `<`。
  String _unescapeXml(String value) {
    if (!value.contains('&')) return value;
    return value
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&amp;', '&');
  }

  /// 上游: webdav/utils.dart:34-54 str2LocalTime（仅接受 "... GMT" 六段式）。
  DateTime? _str2LocalTime(String? value) {
    if (value == null) return null;
    final lowered = value.toLowerCase();
    if (!lowered.endsWith('gmt')) return null;
    final parts = lowered.split(' ');
    if (parts.length != 6) return null;
    final month = _months[parts[2]];
    if (month == null) return null;
    return DateTime.parse(
      '${parts[3]}-$month-${parts[1].padLeft(2, '0')}T${parts[4]}Z',
    ).toLocal();
  }

  /// 上游: webdav/utils.dart:119-129 path2Name。
  String _path2Name(String path) {
    var str = path;
    while (str.endsWith('/')) str = str.substring(0, str.length - 1);
    final index = str.lastIndexOf('/');
    if (index > -1) str = str.substring(index + 1);
    if (str == '') return '/';
    return str;
  }
}
