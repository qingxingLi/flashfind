// 威联通 QNAP (QTS / File Station) 品牌适配器（闪寻 FlashFind，零 pub 依赖）。
//
// 由上游 MyNAS 固定版本 2b1458e205e0 的三个文件移植到闪寻的窄接口
// `NasBrandAdapter`：
//   lib/nas_adapters/qnap/api/qnap_api.dart        （主要移植对象，676 行）
//   lib/nas_adapters/qnap/qnap_file_system.dart    （QnapFile → FileItem 的映射，192 行）
//   lib/nas_adapters/qnap/qnap_adapter.dart        （Dio / BaseOptions / 超时 / 会话组织，189 行）
//
// ── 协议形态：CGI，参数走 query string ────────────────────────────
// QNAP 走 CGI：登录 /cgi-bin/authLogin.cgi，文件操作 /cgi-bin/filemanager/utilRequest.cgi，
// 系统信息 /cgi-bin/management/manaRequest.cgi。参数以 **query string** 传
// （上游用 `_dio.options.baseUrl` 手工拼 URL，见 qnap_api.dart:271/337/361）。
//
//   会话标识 `sid` 会出现在 query 里 —— 这是**会话标识不是口令**，允许保留；
//   但**登录口令只进 POST body**（form-urlencoded），绝不拼进 URL（qnap_api.dart:39-48）。
//
// 超时沿用上游 qnap_adapter.dart：由外部构造 Dio 的 BaseOptions 设置
// （connect / send / receive），本适配器不改动传输层超时。
//
// ── 与上游的取舍（硬约束）─────────────────────────────────────────
//   1. 零 pub 依赖：只 import `dart:convert` 与本项目本地文件。
//   2. appL10n.xxx → 含义相同的中文文案；不移植整张字符串表。
//   3. logger.i/d/w/e → _log.i/d/w/e（文件顶部 `final _log = Logger();`）。
//   4. 上游 StateError / ServerException → AdapterFailure；常用场景用 AdapterFailures。
//   5. wire 语义逐字保留：HTTP 方法、CGI 端点、参数名、响应字段名、错误码表、
//      分页语义、多候选解析顺序。
//   6. 只实现窄接口需要的 login / shareRoots / list / search / logout /
//      capabilities / cancellation。**不移植** 上传、mkdir、delete、rename、copy、
//      缩略图、媒体服务（getDownloadUrl / getMediaStreamUrl / getThumbnailUrl /
//      listMediaFiles / uploadFile / writeFileData / createFolder / deleteFiles /
//      rename / copyFiles / moveFiles）。getSystemInfo 仅服务于上游的 ServerInfo，
//      窄接口没有这个形状，故一并省略。
//   7. 不新增上游没有的端点或参数猜测。
//
// ── 一处**有意偏离上游**的传输细节（保留判定逻辑，仅换读法）─────────
// 上游 `_request` (qnap_api.dart:482-540) 用 dio 默认的 JSON 解析，拿到 `data` 后
// 判定：`data is String && (含 '<html' 或 'login')` → 会话失效。但闪寻的 dio 兼容层
// 在 `ResponseType.json` 下遇到非 JSON 正文（真机 QNAP 的登录页/XML 正文）会**先**
// 抛 `DioException('响应不是合法 JSON')`，上游那段 HTML/login 嗅探将永远走不到。
// 因此这里把 `_request` 与登录读成 `ResponseType.plain`（拿到原始字符串），
// **再逐字执行上游的判定顺序**（空 → HTML/login → JSON 对象错误字段 → status）。
// 判定集合、字段名、比较全部不变，只是把「解析任务」从 dio 挪到这里，以保真。
//
// ── 诚实边界（无真机）────────────────────────────────────────────
// **没有 QNAP 真机可用**，以下均为上游源码级事实，未在设备上校准：
//   * 登录 /cgi-bin/authLogin.cgi：上游把响应当作 JSON Map 读 `authPassed`/`authSid`；
//     而 QTS 的 authLogin.cgi 默认返回 **XML**（`<authPassed>1</authPassed>`）。
//     上游是否另配了 JSON 转换未知，故本适配器按上游逐字读 Map，并容忍数字字符串。
//   * 2FA 判定 `need_otp == 1 || authCode == 5` 逐字保留。
//   * 列目录 `func=get_list`（分页 pageSize=500）与共享 `func=get_tree`、
//     搜索 `func=search` 的响应字段 `datas[].filename/filesize/isfolder/epochmt/...`
//     全部取自上游 QnapFile.fromJson，未在真机核对字段类型。
// 因此 capabilities.verifiedOnDevice=false（搜索实现照搬了上游，故 nativeSearch=true，
import 'dart:convert';

import '../adapter_contract.dart';
import '../adapter_support.dart';
import '../dio_compat.dart';
import '../error_kinds.dart';
import '../protocol.dart';
import '../upstream_file_types.dart' show FileItem;

/// 适配器日志入口。上游是全局 logger 并落盘 app.log；此处只写 stderr 且默认静默。
final _log = Logger();

/// 上游: qnap/api/qnap_api.dart:556-573 —— 登录解析的内部结果（sealed，不对外暴露）。
sealed class _QnapAuthResult {
  const _QnapAuthResult();
}

/// 上游: qnap/api/qnap_api.dart:561-564
class _QnapAuthSuccess extends _QnapAuthResult {
  const _QnapAuthSuccess({required this.sid});
  final String sid;
}

/// 上游: qnap/api/qnap_api.dart:566-569
class _QnapAuthFailure extends _QnapAuthResult {
  const _QnapAuthFailure({required this.error, this.code});
  final String error;
  final int? code;
}

/// 上游: qnap/api/qnap_api.dart:571-573
class _QnapAuthRequires2FA extends _QnapAuthResult {
  const _QnapAuthRequires2FA();
}

/// 上游: qnap/api/qnap_api.dart:604-610 —— QNAP 共享文件夹（内部结构）。
class _QnapShareFolder {
  const _QnapShareFolder({required this.name, required this.path, this.iconCls});

  final String name;
  final String path;
  final String? iconCls;
}

/// 上游: qnap/api/qnap_api.dart:613-676 —— QNAP 文件项（内部结构，不对外暴露）。
class _QnapFile {
  const _QnapFile({
    required this.name,
    required this.path,
    required this.isDir,
    this.size = 0,
    this.createTime,
    this.modifyTime,
    this.mimeType,
    this.owner,
    this.group,
  });

  /// 上游: qnap/api/qnap_api.dart:626-646
  factory _QnapFile.fromJson(Map<String, dynamic> json) {
    final isDir =
        json['isfolder'] == 1 ||
        json['isdir'] == 1 ||
        json['filetype'] == 'folder';

    return _QnapFile(
      name: json['filename'] as String? ?? json['text'] as String? ?? '',
      path:
          json['path'] as String? ??
          json['real_path'] as String? ??
          '/${json['filename'] ?? json['text'] ?? ''}',
      isDir: isDir,
      size: _parseSize(json['filesize'] ?? json['size']),
      createTime: _parseTime(json['epochcreate'] ?? json['create_time']),
      modifyTime: _parseTime(json['epochmt'] ?? json['modify_time']),
      mimeType: json['mimetype'] as String?,
      owner: json['owner'] as String?,
      group: json['group'] as String?,
    );
  }

  final String name;
  final String path;
  final bool isDir;
  final int size;
  final DateTime? createTime;
  final DateTime? modifyTime;
  final String? mimeType;
  final String? owner;
  final String? group;

  /// 上游: qnap/api/qnap_api.dart:658-663
  static int _parseSize(dynamic value) {
    if (value == null) return 0;
    if (value is int) return value;
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }

  /// 上游: qnap/api/qnap_api.dart:665-675 —— 秒级 Unix 时间戳 → 本地时间的绝对时刻。
  static DateTime? _parseTime(dynamic value) {
    if (value == null) return null;
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value * 1000);
    if (value is String) {
      final intValue = int.tryParse(value);
      if (intValue != null) {
        return DateTime.fromMillisecondsSinceEpoch(intValue * 1000);
      }
    }
    return null;
  }
}

/// 威联通 QNAP 品牌适配器。
///
/// 构造：`Dio` 由外部注入（内含 baseUrl，等价上游 `ConnectionConfig.baseUrl`）。
/// QNAP 管理口常见为明文 HTTP（出厂 8080 等），因此来源配置须显式设置
/// `dio.allowInsecureHTTP = true`（dio_compat 的安全策略，不在本适配器内绕过）。
class QnapAdapter implements NasBrandAdapter {
  QnapAdapter({required Dio dio}) : _dio = dio;

  final Dio _dio;

  /// 上游: qnap/api/qnap_api.dart:14 —— 当前会话 ID。
  String? _sid;

  Cancellation? _cancel;
  String? _identity;
  int _sessionEpoch = 0;

  @override
  String get vendor => 'qnap';

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
  /// 上游确实实现了**服务端搜索**（`utilRequest.cgi` 的 `func=search`，见
  /// qnap_api.dart:378-401），本适配器也照搬了它、**没有**回退成客户端遍历；
  /// 但**没有 QNAP 真机**，登录/列目录/搜索的响应形态均未在设备上校准。
  /// **两个字段是两件事，不要合并**：
  ///   `nativeSearch`     = 适配器里**有没有**服务端搜索的实现（有）
  ///   `verifiedOnDevice` = 那个实现**有没有在真机上跑通过**（没有）
  ///
  /// 把两者一起置 false 会让会话层直接判定「不支持搜索」而**不调适配器**，
  /// 真机校准的入口就被堵死了。未验证由 verifiedOnDevice 与 notes 承担。
  /// 结果可以用同一主机的 SMB 共享打开：这台设备本身就是 SMB 服务器，
  /// 搜索结果的逻辑路径与共享路径同构。见 `NasBrandAdapter.exposesSMBShares`。
  @override
  bool get exposesSMBShares => true;

  @override
  BrandCapabilities get capabilities => const BrandCapabilities(
    nativeSearch: true,
    verifiedOnDevice: false,
    querySemantics:
        '搜索走 QNAP File Station 服务端接口（utilRequest.cgi 的 func=search），'
        '按上层授权的共享根逐根发请求；不做客户端全盘递归遍历。'
        '该能力尚未在真机验证。',
    notes:
        '未在真机上验证。已验证的只有上游源码级事实：'
        '登录 POST /cgi-bin/authLogin.cgi（口令进 body，form-urlencoded），'
        '共享列表 GET utilRequest.cgi?func=get_tree&node=share_root，'
        '列目录 GET utilRequest.cgi?func=get_list（分页 pageSize=500），'
        '服务端搜索 GET utilRequest.cgi?func=search。'
        '主要不确定点：QTS 的 authLogin.cgi 默认返回 XML，而上游把响应当 JSON Map 读 '
        '（authPassed/authSid/need_otp/authCode），本适配器逐字保留该读法并容忍数字字符串；'
        '列目录/搜索的 datas[] 字段类型（filesize/isfolder/epochmt 等）未在真机核对。'
        '因此 verifiedOnDevice=false —— 真机校准前不要对外声称「原生搜索可用」。',
  );

  // ─────────────────────────── 登录 ───────────────────────────

  /// 上游: qnap/api/qnap_api.dart:28-87（login）+ qnap_adapter.dart:67-84（connect 分支）。
  ///
  /// 口令只进 POST body（application/x-www-form-urlencoded），绝不进 URL。
  /// 会话身份用 `<sid>#<代际号>`：同一账号重登必定拿到不同身份（契约要求）。
  @override
  Future<LoginOutcome> login({
    required String username,
    required String password,
    String? otpCode,
  }) async {
    _cancel?.check();
    _sid = null;
    _identity = null;

    _log
      ..i('QnapApi: 开始登录认证')
      ..d('QnapApi: 账号 => $username, OTP => ${otpCode != null ? "有" : "无"}');

    // 上游: qnap/api/qnap_api.dart:41-46 —— 逐字保留的字段名与 remme 取值。
    // 窄接口的 login 只有 otpCode，无 rememberMe 开关，等价上游 connect 的默认 false。
    final fields = <String, String>{
      'user': username,
      'pwd': password,
      'remme': '0',
      if (otpCode != null) 'otp_code': otpCode,
    };
    final formBody = fields.entries
        .map(
          (e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
        )
        .join('&');

    try {
      // 上游: qnap/api/qnap_api.dart:39-48 —— POST /cgi-bin/authLogin.cgi，
      // contentType 为 application/x-www-form-urlencoded。
      final response = await _dio.post<String>(
        '/cgi-bin/authLogin.cgi',
        data: formBody,
        options: Options(
          contentType: 'application/x-www-form-urlencoded',
          responseType: ResponseType.plain,
        ),
      );

      // 登录响应包含 sid，不写入日志（上游 qnap_api.dart:51）。
      _log.d('QnapApi: 登录响应状态码 => ${response.statusCode}');

      final result = _parseLoginResponse(response.data);

      switch (result) {
        case _QnapAuthSuccess(:final sid):
          _sid = sid;
          _identity = '$sid#${++_sessionEpoch}';
          _log.i('QnapApi: 登录成功');
          return LoginSuccess(identity: _identity!);
        case _QnapAuthFailure(:final error, :final code):
          _log.w('QnapApi: 登录失败, 错误码 => $code, 消息 => $error');
          return LoginRejected(error, apiCode: code);
        case _QnapAuthRequires2FA():
          // 上游 qnap_adapter.dart:81-83 —— 需要二次验证，唯一可用方式为 totp。
          _log.i('QnapApi: 需要二次验证');
          return const LoginNeedsOTP(methods: ['totp']);
      }
    } on DioException catch (e) {
      _cancel?.check(); // 取消不能被吞掉
      _log.e('QnapApi.login', e);
      if (e.type == DioExceptionType.badResponse &&
          e.message.contains('重定向')) {
        return const LoginRejected(
          'QNAP 服务要求重定向，已按安全策略拒绝自动跟随',
          apiCode: 301,
        );
      }
      return LoginRejected('无法连接 QNAP 设备（${e.message}）');
    }
  }

  /// 上游: qnap/api/qnap_api.dart:50-82 —— 登录响应解析（成功 / 2FA / 失败三分支）。
  ///
  /// 读法说明见文件头「有意偏离上游的传输细节」：上游把 `data` 当 Map，
  /// 这里 plain 拿到原文后再 jsonDecode，判定顺序与字段名不变。
  _QnapAuthResult _parseLoginResponse(String? raw) {
    // 上游: qnap/api/qnap_api.dart:54-55 —— data == null → 服务器空响应。
    if (raw == null || raw.isEmpty) {
      return const _QnapAuthFailure(error: '服务器返回空响应');
    }

    final decoded = _tryDecodeJson(raw);
    if (decoded is! Map<String, dynamic>) {
      // 上游此处把 data 当 Map 用；非 Map（例如 XML 登录页）无法判定，按失败收敛。
      return const _QnapAuthFailure(error: 'QNAP 登录响应格式无法识别');
    }

    // 上游: qnap/api/qnap_api.dart:59 —— authPassed == 1 表示成功。
    final authPassed = _intValue(decoded['authPassed']) ?? 0;

    if (authPassed == 1) {
      // 上游: qnap/api/qnap_api.dart:62-65 —— authSid 缺失视为失败。
      final sidValue = decoded['authSid'];
      final sid = sidValue == null ? null : '$sidValue';
      if (sid == null || sid.isEmpty) {
        return const _QnapAuthFailure(error: '登录成功但服务器未返回会话 ID');
      }
      return _QnapAuthSuccess(sid: sid);
    }

    // 上游: qnap/api/qnap_api.dart:72 —— need_otp == 1 或 authCode == 5 需要 2FA。
    final need2FA =
        _intValue(decoded['need_otp']) == 1 ||
        _intValue(decoded['authCode']) == 5;
    if (need2FA) {
      return const _QnapAuthRequires2FA();
    }

    // 上游: qnap/api/qnap_api.dart:79-82 —— 其余按 authCode 映射错误消息。
    final errorCode = _intValue(decoded['authCode']) ?? -1;
    return _QnapAuthFailure(
      error: _getAuthErrorMessage(errorCode),
      code: errorCode,
    );
  }

  /// 上游: qnap/api/qnap_api.dart:543-553 —— 认证错误码表（逐字保留）。
  String _getAuthErrorMessage(int errorCode) => switch (errorCode) {
    0 => '认证失败',
    1 => '账号或密码错误',
    2 => '账号已被停用',
    3 => '权限不足',
    4 => '已达连接数上限',
    5 => '需要二次验证',
    6 => '二次验证失败',
    7 => 'IP 已被封锁',
    _ => '认证失败（错误码 $errorCode）',
  };

  // ─────────────────────────── 登出 ───────────────────────────

  /// 上游: qnap/api/qnap_api.dart:90-103。登出失败不抛异常，不阻塞用户重连。
  @override
  Future<void> logout() async {
    if (_sid == null) return;

    try {
      // 上游: qnap/api/qnap_api.dart:94-97 —— GET /cgi-bin/authLogout.cgi?sid=...
      // 登出响应多为空/非 JSON，故读 plain，避免无谓的 JSON 解析失败。
      await _dio.get<String>(
        '/cgi-bin/authLogout.cgi',
        queryParameters: {'sid': _sid},
        options: Options(responseType: ResponseType.plain),
      );
    } on Exception catch (e) {
      _log.w('QnapApi: 登出时发生错误不影响操作', e);
    } finally {
      _clearSession();
    }
  }

  // ───────────────────────── 共享根 ─────────────────────────

  /// 上游: qnap/qnap_file_system.dart:23-37（根目录返回共享列表）。
  ///
  /// 共享列表本身就是「可授权的根」，故 shareRoots 等价于上游的 listShareFolders。
  @override
  Future<List<ShareRoot>> shareRoots() async {
    _cancel?.check();
    final shares = await _listShareFolders();
    return shares
        .map((s) => ShareRoot(name: s.name, path: s.path))
        .toList();
  }

  // ───────────────────────── 列目录 ─────────────────────────

  /// 上游: qnap/qnap_file_system.dart:23-75 listDirectory。
  ///
  /// 根目录（`/` 或空）返回共享列表（共享恒为目录、size=0）；其余走 `func=get_list`
  /// 分页拉全（pageSize=500，直到返回条数 < pageSize 或为空）。
  @override
  Future<List<FileItem>> list(String path) async {
    _log.d('QnapFileSystem: listDirectory => $path');

    // 上游: qnap_file_system.dart:25-37 —— 根目录返回共享文件夹列表。
    if (path == '/' || path.isEmpty) {
      final shares = await _listShareFolders();
      return shares
          .map(
            (s) => FileItem(
              name: s.name,
              path: s.path,
              isDirectory: true,
              size: 0,
            ),
          )
          .toList();
    }

    // 上游: qnap_file_system.dart:39-59 —— 分页获取所有文件。
    const pageSize = 500;
    final allFiles = <_QnapFile>[];
    var start = 0;
    var hasMore = true;

    while (hasMore) {
      _cancel?.check();
      final files = await _listFiles(
        folderPath: path,
        start: start,
        limit: pageSize,
      );

      allFiles.addAll(files);

      // 上游: qnap_file_system.dart:55-58 —— 少于 pageSize 即没有更多。
      hasMore = files.length >= pageSize;
      start += files.length;

      if (files.isEmpty) break; // 防止无限循环
    }

    return allFiles.map(_toFileItem).toList();
  }

  // ───────────────────────── 搜索 ─────────────────────────

  /// 上游: qnap/qnap_file_system.dart:151-173（search）。
  ///
  /// QNAP **有**服务端搜索（`func=search`），故照搬；`roots` 是上层已授权的搜索根，
  /// 适配器逐根发**上游原样的单路径请求**（`folderPath=root`），不自行扩大范围，
  /// 也**不**回退成客户端递归遍历。
  @override
  Future<List<FileItem>> search(
    String query, {
    required List<String> roots,
    void Function(RootSearchFailure failure)? onRootFailure,
  }) async {
    if (query.trim().isEmpty) return const [];
    if (roots.isEmpty) return const [];

    final results = <FileItem>[];
    for (final root in roots) {
      _cancel?.check();
      final files = await _searchFiles(folderPath: root, pattern: query);
      results.addAll(files.map(_toFileItem));
    }
    return results;
  }

  // ─────────────────────── QNAP API 调用 ───────────────────────

  /// 上游: qnap/api/qnap_api.dart:124-142 —— 列出共享文件夹（func=get_tree）。
  Future<List<_QnapShareFolder>> _listShareFolders() async {
    final response = await _request(
      '/cgi-bin/filemanager/utilRequest.cgi',
      params: {'func': 'get_tree', 'is_iso': '0', 'node': 'share_root'},
    );

    // 上游原文 ServerException(message: 'QNAP 共享列表响应格式无效')
    if (response is! List) {
      throw AdapterFailures.protocolViolation('QNAP 共享列表响应格式无效');
    }
    final items = response;
    return items.map((item) {
      final map = item as Map<String, dynamic>;
      // 上游: qnap/api/qnap_api.dart:136-140 —— path 为 '/<id 或 text>'。
      return _QnapShareFolder(
        name: map['text'] as String? ?? '',
        path: '/${map['id'] ?? map['text']}',
        iconCls: map['iconCls'] as String?,
      );
    }).toList();
  }

  /// 上游: qnap/api/qnap_api.dart:144-182 —— 列出目录内容（func=get_list）。
  Future<List<_QnapFile>> _listFiles({
    required String folderPath,
    int start = 0,
    int limit = 100,
    String sortBy = 'filename',
    String sortDirection = 'ASC',
  }) async {
    final response = await _request(
      '/cgi-bin/filemanager/utilRequest.cgi',
      params: {
        'func': 'get_list',
        'path': folderPath,
        'list_mode': 'all',
        'start': start.toString(),
        'limit': limit.toString(),
        'sort': sortBy,
        'dir': sortDirection,
        'is_iso': '0',
      },
    );

    // 上游原文 ServerException(message: 'QNAP 目录列表响应格式无效')
    if (response is! Map<String, dynamic> || response['datas'] is! List) {
      throw AdapterFailures.protocolViolation('QNAP 目录列表响应格式无效');
    }
    final datas = response['datas'] as List<dynamic>;

    // 上游: qnap/api/qnap_api.dart:171-177 —— 调试：打印原始数据中的文件大小字段。
    if (datas.isNotEmpty) {
      final sample = datas.first as Map<String, dynamic>;
      _log.d(
        'QnapApi listFiles 原始数据样本: filesize=${sample['filesize']}, size=${sample['size']}',
      );
    }

    return datas
        .map((item) => _QnapFile.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  /// 上游: qnap/api/qnap_api.dart:377-401 —— 搜索文件（func=search）。
  Future<List<_QnapFile>> _searchFiles({
    required String folderPath,
    required String pattern,
    int limit = 100,
  }) async {
    final response = await _request(
      '/cgi-bin/filemanager/utilRequest.cgi',
      params: {
        'func': 'search',
        'path': folderPath,
        'keyword': pattern,
        'limit': limit.toString(),
      },
    );

    // 上游原文 ServerException(message: 'QNAP 搜索响应格式无效')
    if (response is! Map<String, dynamic> || response['datas'] is! List) {
      throw AdapterFailures.protocolViolation('QNAP 搜索响应格式无效');
    }
    final datas = response['datas'] as List<dynamic>;

    return datas
        .map((item) => _QnapFile.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  /// 上游: qnap/api/qnap_api.dart:481-540 —— 通用请求方法。
  ///
  /// 逐字保留：`sid` 挂在 query（会话标识，非口令）、端点与方法、空响应判定、
  /// HTML/login 会话失效嗅探、JSON 对象内的 authPassed/msg/session/login/status 判定。
  /// 差异仅在读法（plain + jsonDecode，见文件头说明），判定集合与顺序完全一致。
  Future<dynamic> _request(String path, {Map<String, String>? params}) async {
    _cancel?.check();

    // 上游: qnap/api/qnap_api.dart:483 —— query 组装 `{'sid': ?_sid, ...?params}`。
    final queryParams = <String, String>{
      if (_sid != null) 'sid': _sid!,
      ...?params,
    };

    _log.d('QnapApi: 请求 => $path');

    final Response<String> response;
    try {
      response = await _dio.get<String>(
        path,
        queryParameters: queryParams,
        options: Options(responseType: ResponseType.plain),
      );
    } on DioException catch (e) {
      // 上游: qnap/api/qnap_api.dart:533-539 —— 401/403 清会话后重抛。
      _cancel?.check();
      throw _translateDio(e, 'QNAP 请求');
    }

    final raw = response.data;
    _log.d('QnapApi: 响应状态码 => ${response.statusCode}');

    // 上游: qnap/api/qnap_api.dart:496-499 —— 空数据。
    if (raw == null || raw.isEmpty) {
      _log.e('QnapApi: 服务器返回空数据');
      throw AdapterFailures.protocolViolation('QNAP 服务器返回空响应');
    }

    // 上游: qnap/api/qnap_api.dart:501-506 —— HTML / login → 会话已失效。
    final lowered = raw.toLowerCase();
    if (lowered.contains('<html') || lowered.contains('login')) {
      _clearSession();
      throw AdapterFailures.sessionExpired();
    }

    // 上游返 JSON Map（dio json 转换）；这里 plain + jsonDecode 等价取回。
    // 非 JSON 正文（例如纯文本）保留为字符串，交由调用方按「响应格式无效」收敛。
    final data = _tryDecodeJson(raw) ?? raw;

    if (data is Map<String, dynamic>) {
      final authPassed = data['authPassed'];
      final message = (data['msg'] ?? data['message'] ?? '').toString();
      if (authPassed == 0 ||
          message.toLowerCase().contains('session') ||
          message.toLowerCase().contains('login')) {
        _clearSession();
        throw AdapterFailure(
          ErrorKind.sessionExpired,
          message.isEmpty ? 'QNAP 会话已失效' : message,
        );
      }
      // 上游: qnap/api/qnap_api.dart:520-529 —— status != 1 视为 API 错误。
      final status = _intValue(data['status']);
      if (status != null && status != 1) {
        final errorMsg = data['msg']?.toString() ?? 'QNAP 操作失败';
        _log.e('QnapApi: API 错误 => $errorMsg');
        throw AdapterFailure(ErrorKind.apiError, errorMsg);
      }
    }

    return data;
  }

  // ─────────────────────── 内部工具 ───────────────────────

  /// 上游: qnap/api/qnap_api.dart:23-25 —— 清除会话。
  /// 窄接口另需清空 identity（会话失效后不得再被当成有效代际）。
  void _clearSession() {
    _sid = null;
    _identity = null;
  }

  /// 上游: qnap/qnap_file_system.dart:61-74 —— QnapFile → FileItem（字段一一对应）。
  FileItem _toFileItem(_QnapFile f) => FileItem(
    name: f.name,
    path: f.path,
    isDirectory: f.isDir,
    size: f.size,
    modifiedTime: f.modifyTime,
    createdTime: f.createTime,
    mimeType: f.mimeType,
    // 上游 qnap_file_system.dart:71 用 p.extension(f.name)；目录给 null。
    extension: f.isDir ? null : PathCompat.extension(f.name),
  );

  /// 把 DioException 翻成中文可读的 AdapterFailure。
  ///
  /// dio_compat 对 3xx 一律判失败且**不带 response**（见 dio_compat.dart:334）。
  AdapterFailure _translateDio(DioException error, String action) {
    if (error.type == DioExceptionType.badResponse &&
        error.message.contains('重定向')) {
      return AdapterFailures.protocolViolation(
        '$action：QNAP 服务要求重定向，已按安全策略拒绝自动跟随',
      );
    }
    final status = error.response?.statusCode;
    if (status == 401 || status == 403) {
      _clearSession();
      return AdapterFailures.sessionExpired(status);
    }
    return AdapterFailures.network('$action失败：${error.message}');
  }

  /// 解析 JSON；失败返回 null（调用方据此决定是走字符串分支还是判格式错误）。
  dynamic _tryDecodeJson(String raw) {
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  /// 容错取整。
  ///
  /// 上游对 authPassed / authCode / need_otp 直接写 `as int?`（qnap_api.dart:59/79/72）。
  /// 由于 QTS 常以字符串承载数值，这里容忍数字字符串以免类型崩溃；
  /// **判定逻辑与字段名不变**（见文件头诚实边界）。
  int? _intValue(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    return int.tryParse(value.toString());
  }
}
