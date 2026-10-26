// 绿联 UGREEN NAS 品牌适配器（闪寻 FlashFind，零 pub 依赖）。
//
// 由上游 MyNAS 固定版本 2b1458e205e0 的三个文件移植到闪寻的窄接口 `NasBrandAdapter`：
//   lib/nas_adapters/ugreen/api/ugreen_api.dart        （主要移植对象，1239 行）
//   lib/nas_adapters/ugreen/ugreen_file_system.dart    （277 行，UGreenFileInfo → FileItem 映射）
//   lib/nas_adapters/ugreen/ugreen_adapter.dart        （307 行，Dio/BaseOptions/超时/WebDAV 兜底）
//
// ── 难点 1：RSA 登录加密（上游依赖 package:pointycastle，本移植自实现）──────
// 逐行判定上游用的是哪种 RSA 模式（本移植**先判定、再动手**）：
//   * ugreen_api.dart:249
//       final encryptor = PKCS1Encoding(RSAEngine())..init(true, PublicKeyParameter<RSAPublicKey>(publicKey));
//     —— `PKCS1Encoding`（pointycastle/asymmetric/pkcs1.dart）就是 **RSAES-PKCS1-v1_5**；
//        `init(true, ...)` 的 true 是「加密方向」（解密/verify 才是 false）。
//   * ugreen_api.dart:252-253  待加密明文 = `utf8.encode(password)`（原始口令字节，无摘要、无加盐）。
//   * ugreen_api.dart:256      结果 = `base64Encode(encrypted)`。
//   * 全文**没有** `OAEPEncoding` / `PSSEncoding` / MGF1 的痕迹。
// 结论：上游是**教科书式 RSAES-PKCS1-v1_5 加密**，不是 OAEP、不是 PSS。
// 因此本移植**选择自实现**（不抛 UnsupportedApi）：`dart:core` 的 `BigInt.modPow` 做模幂，
// `Random.secure()` 生成非零随机填充，按 `0x00 || 0x02 || PS || 0x00 || M` 组装 EM。
// 公钥解析同样自实现：一个极简 DER 解析器（只认 SEQUENCE/INTEGER/BIT STRING），覆盖上游
// `_parsePublicKeyFromDer`（:281-308）认的两种封装：
//   * PKCS#1  `SEQUENCE { INTEGER n, INTEGER e }`
//   * PKCS#8/SubjectPublicKeyInfo `SEQUENCE { SEQUENCE alg, BIT STRING RSAPublicKey }`
// 以及入口 `_encryptPassword`（:231-261）认的三种 key 载体：PEM / Base64(PEM) / Base64 DER。
// 兜底与上游一致：`x-rsa-token` 缺失或 RSA 初始化失败时，回退明文口令（早期固件）。
//
// ── 难点 2：package:webdav_client 的用途（整段删除）──────────────────────
// `package:webdav_client` **不在** `ugreen_api.dart` 里，只出现在 `ugreen_adapter.dart`：
//   :17 import / :33 `webdav.Client? _webdavClient` / :38 `_useWebDav` / :177-233 `_initWebDav`
// 它是「UGOS 文件 API 不可用时的 WebDAV 兜底文件系统」这一整条分支：
//   :143-153 先试 `_api.listShares()`，抛异常就 `_useWebDav = true`；
//   :188-230 再逐个试 /webdav、/dav、/ 建 WebDAV 客户端并 ping + readDir。
// 这是**另一个传输/品牌**（闪寻已有独立 webdav 适配器），窄接口完全不需要，
// 故整段删除（连同 `webdav` import 与 `_useWebDav` 状态）。
//
// ── 它到底是「照实机协议写」还是「穷举猜」？（★ 重要判定）────────────────
// 判定：**文件/共享/搜索这一大块是穷举猜测**；只有登录(auth)一段相对结构化，疑似来自
// UGOS 前端逆向或 Home Assistant 集成，但**同样没有任何真机验证记录**。
// 依据（均可复核）：
//   1. listDirectory（:356-444）是一张**有序候选端点表**，共 **11 条**（1 条 v2 新固件
//      端点 + 标注「尝试 1..10」的 10 条），覆盖 /ugreen/v2/filemgr/getDirFileListV2、
//      /ugreen/v1/filemgr/list、/ugreen/v1/file/list、/ugreen/v1/filemgr/dir/list、
//      /ugreen/v1/filestation/list，且对同一端点还猜 GET/POST 与
//      path/dir/folder/folder_path 多种参数名。
//      「同一端点枚举多种参数名与动词」是典型的没跑通时的穷举，不是协议事实。
//   2. listShares（:709-837）更甚：**11 个候选端点**；_getSharesFromStoragePool（:894-977）
//      注释明写「尝试多种可能的响应结构 / 结构 1…结构 2…」。
//      两处合计 **22 条候选端点**（与主控统计的「22 处尝试式写法」吻合）。
//   3. _parseFileInfo（:1153-1200）对修改时间猜了 9 个键名、对创建时间猜了 6 个键名。
//   4. 全文**没有一处**注明「已在真机验证」或引用抓包；:713 唯一一句
//      「这是 Home Assistant 集成发现的可靠端点」——引用的仍是第三方集成，不是抓包。
//   5. 唯一像「实机观测」的线索是 v2 的 referer `.../filemgr/?_filemgr=my_nas`（:469），
//      但它是**候选表里的第 1 项**：一旦 `_itemsBelongToPath` 不符就 `_v2ListDisabled`
//      永久回退到另外 9 个猜测——「观测到就锁死」不会这么写，所以更像试探。
// 侧证：同项目的 fnos 适配器已被证实「HTTP 端点全部 404，真机走 WebSocket RPC」。
// 两个国产 NAS 适配器是同一批、同一风格产出，可信度同档。
// 本移植**不增不减、不换顺序**地保留这套候选（便于真机校准时最小改动），
// 但 `capabilities.verifiedOnDevice=false` 如实说明。
//
// ── 移植约定 ────────────────────────────────────────────────────
//   - 只实现接口需要的 login / shareRoots / list / search / logout / capabilities /
//     cancellation。不移植 getDeviceInfo / getFileUrl / getThumbnailUrl / getUrlStream /
//     createDirectory / delete / rename / copy / upload（上传相关的 FormData/MultipartFile/
//     DioMediaType 本 dio 兼容层也不提供）。
//   - wire 语义逐字保留：HTTP 方法、端点路径、参数名、referer 头、响应字段名、错误码表
//     （1001/1002/1024 等）、分页语义、以及 _extractSuccessfulList/_extractTotal 的候选键顺序。
//   - appL10n.xxx 换成含义相同的中文文案；logger.* 换成 _log.*；StateError / 上游自定义
//     异常换成 AdapterFailure。
//   - 上游 file_system 的**客户端 BFS 搜索兜底**（ugreen_file_system.dart:238-266）按契约
//     删除：服务端搜索不可用时抛 UnsupportedApi，绝不回退全盘递归遍历。
//
// ── 待确认 ──────────────────────────────────────────────────────
//   * 真机未验证（无绿联设备）：端点、参数名、错误码、字段名全部来自上游穷举，未跑通。
//   * 上游 `listShares` 对共享列表有缓存（file_system:66-100）；本移植**不缓存**，
//     避免跨登录代际返回陈旧共享（契约要求同一会话内身份稳定）。
//   * RSA：上游支持 PEM / Base64(PEM) / Base64 DER 三种 key 载体与本移植一致，但真实
//     `x-rsa-token` 的**具体形态**（是 PEM 还是裸 DER）无样本可核，只能三种都试。
//   * v2 列表：`x-ugreen-token` 用 `_loginPublicKey` 加密会话 token，公钥来自登录响应
//     `data.public_key`；该字段在真机上是否存在未验证，缺失时本适配器自动回退 v1。
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../adapter_contract.dart';
import '../adapter_support.dart';
import '../dio_compat.dart';
import '../protocol.dart';
import '../upstream_file_types.dart' show FileItem;

/// 适配器日志入口。上游是全局 logger 并落盘 app.log；此处只写 stderr 且默认静默。
final _log = Logger();

/// 上游: ugreen/api/ugreen_api.dart:58 —— 绿联文件信息（内部结构，不对外暴露）。
class _UGreenFileInfo {
  const _UGreenFileInfo({
    required this.name,
    required this.path,
    required this.isDir,
    this.size,
    this.modified,
    this.created,
    this.mimeType,
  });

  final String name;
  final String path;
  final bool isDir;
  final int? size;
  final DateTime? modified;
  final DateTime? created;
  final String? mimeType;
}

/// 绿联 UGREEN NAS 适配器。
///
/// UGOS 使用两步 RSA 加密登录：先 POST /ugreen/v1/verify/check 取 `x-rsa-token` 公钥，
/// 再由 POST /ugreen/v1/verify/login 携加密口令登录。
///
/// 构造：`Dio` 由外部注入（内含 baseUrl，等价上游 `DioClient.updateBaseUrl`）。
/// UGOS 管理口通常为明文 HTTP，因此来源配置必须显式设置 `dio.allowInsecureHTTP = true`
/// （dio_compat 的安全策略，不在本适配器内绕过）。超时沿用上游 DioClient：
/// connect 30s / receive 60s（无 sendTimeout），BaseOptions 默认
/// `Content-Type: application/json` + `Accept: application/json`，且 responseType
/// 须保持默认 json（登录/列表都解析 JSON）。请在构造 Dio 的 BaseOptions 上设置。
class UGreenAdapter implements NasBrandAdapter {
  UGreenAdapter({required Dio dio}) : _dio = dio;

  final Dio _dio;

  Cancellation? _cancel;
  String? _token;
  String? _tokenId;
  String? _loginPublicKey;
  String? _sessionCookie;
  String? _username;
  String? _password;
  bool _v2ListDisabled = false;
  String? _identity;

  /// 会话代际号：契约要求「同一账号重登必须换一个身份」，token 相同时靠它区分。
  int _sessionEpoch = 0;

  @override
  String get vendor => 'ugreen';

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
        '服务端搜索为上游单一端点（POST /ugreen/v1/file/search，body {keyword, path}），'
        '但从未在真机验证，故按「未验证」保守声明；设备若没有可用的服务端搜索端点，'
        '按契约抛 UnsupportedApi，绝不回退成全盘递归遍历（上游的 BFS 兜底已删除）。',
    notes:
        '未在真机上验证（无绿联真机）。上游端点集是穷举猜测：列目录 11 个候选端点、'
        '共享 11 个候选端点（合计 22 条），均带「尝试 N」注释，同一端点还猜 GET/POST 与多种参数名；'
        '响应解析靠多候选键与「结构 1/2」兜底。登录(auth)一段相对结构化'
        '（/ugreen/v1/verify/check 取 x-rsa-token 公钥 + /ugreen/v1/verify/login，'
        '错误码 1001/1002/1024 等），疑似来自 UGOS 前端逆向或 Home Assistant 集成，'
        '但同样无抓包、无真机跑通记录。口令经 RSAES-PKCS1-v1_5 加密'
        '（本适配器用 BigInt 自实现，不引 pointycastle）；'
        '上游「UGOS 不可用则回退 WebDAV」的整条分支已按窄接口要求删除。',
  );

  // ─────────────────────────── 登录 ───────────────────────────

  /// 上游: ugreen/api/ugreen_api.dart:109-228 login。
  @override
  Future<LoginOutcome> login({
    required String username,
    required String password,
    String? otpCode,
  }) async {
    _log
      ..i('UGreenApi: 开始登录认证 (UGOS API)')
      ..i('UGreenApi: 用户名 => $username');

    _username = username;
    _password = password;
    _invalidateSession();
    _cancel?.check();

    try {
      // 上游: :123-147 —— 新固件先从 verify/check 获取 RSA 公钥；早期固件没有该端点，
      // 仍接受旧的明文 payload。只在 RSA 初始化不可用时回退，不会在新固件上重复发密码。
      var passwordPayload = password;
      try {
        _log.i('UGreenApi: Step 1 - 获取 RSA 公钥');
        final checkResponse = await _dio.post<dynamic>(
          '/ugreen/v1/verify/check',
          queryParameters: const {'token': ''},
          data: {'username': username},
          options: Options(
            validateStatus: (status) => status != null && status < 500,
          ),
        );
        _log.d('UGreenApi: check 响应状态码 => ${checkResponse.statusCode}');
        // 上游: :138 —— 公钥挂在响应头 `x-rsa-token` 上。
        final rsaTokenHeader = checkResponse.headers.value('x-rsa-token');
        if (rsaTokenHeader == null || rsaTokenHeader.isEmpty) {
          _log.w('UGreenApi: 固件未提供 RSA 公钥，尝试早期登录流程');
        } else {
          // 上游: :142 _encryptPassword(password, rsaTokenHeader)（PKCS#1 v1.5）。
          passwordPayload = _rsaEncryptPassword(password, rsaTokenHeader);
          _log.i('UGreenApi: RSA 密码加密完成');
        }
      } on Exception catch (e) {
        // 上游: :145-147 AppError.ignore(..., 'UGREEN RSA 登录初始化失败，尝试早期固件流程')
        _log.w('UGreenApi: RSA 登录初始化失败，尝试早期固件流程', e);
      }

      // 上游: :149-162 —— 登录请求体逐字保留（含 otp 布尔与可空的 otp_code）。
      final loginResponse = await _dio.post<dynamic>(
        '/ugreen/v1/verify/login',
        data: {
          'is_simple': true,
          'keepalive': true,
          'otp': otpCode != null,
          'username': username,
          'password': passwordPayload,
          'otp_code': ?otpCode,
        },
        options: Options(
          validateStatus: (status) => status != null && status < 500,
        ),
      );

      // 登录响应包含 token，不写入日志。
      _log.i('UGreenApi: login 响应状态码 => ${loginResponse.statusCode}');
      _sessionCookie = _cookiesFrom(loginResponse.headers);

      final data = loginResponse.data;
      if (data is Map<String, dynamic>) {
        final code = _intCode(data['code']);

        // 成功。上游: :173-192
        if (code == 200) {
          final tokenData = data['data'];
          if (tokenData is Map<String, dynamic>) {
            final sessionToken = tokenData['token']?.toString();
            final staticToken = tokenData['static_token']?.toString();
            _token = sessionToken ?? staticToken;
            _tokenId = tokenData['token_id']?.toString();
            _loginPublicKey = tokenData['public_key']?.toString();
          }
          if (_token != null && _token!.isNotEmpty) {
            _log.i('UGreenApi: 登录成功');
            // 上游 ugreen_adapter.dart:173 以 token 作为 sessionId。窄接口额外要求
            // 「同一账号重登必须换一个身份」，故追加代际号，保证身份一定变化。
            _identity = '${_token!}#${++_sessionEpoch}';
            return LoginSuccess(identity: _identity!);
          }
        }

        // 需要 2FA。上游: :195-200
        if (code == 1001 ||
            data['need_otp'] == true ||
            data['require_2fa'] == true) {
          _log.i('UGreenApi: 需要二次验证');
          return const LoginNeedsOTP();
        }

        // 其他错误。上游: :202-208（原文 appL10n.ugreenAuthLoginFailed('$code')）
        final message =
            data['message']?.toString() ??
            data['msg']?.toString() ??
            '绿联 NAS 登录失败（错误码 $code）';
        _log.e('UGreenApi: 登录失败 => $message');
        return LoginRejected(message, apiCode: code);
      }

      // 上游: :211（原文 appL10n.ugreenAuthServerResponseInvalid）
      return const LoginRejected('绿联 NAS 响应格式无法识别');
    } on DioException catch (e) {
      _cancel?.check(); // 取消不能被吞掉
      _log.e('UGreenApi: 登录失败', e);
      // 上游: :212-223 的连接类失败分支（原文 appL10n.ugreenAuthConnectionTimeout 等）
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        return const LoginRejected('连接绿联 NAS 超时，请检查设备地址与网络');
      }
      if (e.type == DioExceptionType.connectionError) {
        return const LoginRejected('无法连接绿联 NAS，请检查设备是否在线');
      }
      return LoginRejected('绿联 NAS 登录请求失败：${e.message}');
    } on Exception catch (e) {
      _cancel?.check();
      // 上游: :224-227 AppError.handle(...) + UGreenAuthFailure(error: e.toString())
      _log.e('UGreenApi: 登录异常', e);
      return LoginRejected('绿联 NAS 登录异常：$e');
    }
  }

  // ─────────────────────────── 登出 ───────────────────────────

  /// 上游: ugreen/api/ugreen_api.dart:311-329 logout。登出失败不抛异常，不阻塞重连。
  @override
  Future<void> logout() async {
    if (_token == null) return;

    try {
      await _dio.post<dynamic>(
        '/ugreen/v1/verify/logout',
        queryParameters: {'token': _token},
        options: Options(
          headers: _sessionCookie == null ? null : {'cookie': _sessionCookie},
        ),
      );
    } on Exception catch (e) {
      // 上游: :322-323 AppError.ignore(e, st, '登出失败不影响操作')
      _log.w('UGreenApi: 登出失败不影响操作', e);
    } finally {
      _invalidateSession();
      _identity = null;
      _username = null;
      _password = null;
    }
  }

  // ───────────────────────── 共享根 ─────────────────────────

  /// 上游: ugreen/ugreen_file_system.dart:66-100 listShares（→ api.listShares :709-837）。
  @override
  Future<List<ShareRoot>> shareRoots() async {
    _cancel?.check();
    final shares = await _listSharesRaw();
    return shares
        .map((share) => ShareRoot(name: share.name, path: share.path))
        .toList();
  }

  // ───────────────────────── 列目录 ─────────────────────────

  /// 上游: ugreen/ugreen_file_system.dart:31-61 listDirectory。
  @override
  Future<List<FileItem>> list(String path) async {
    _log.d('UGreenFileSystem: listDirectory => $path');

    // 上游: :34-37 —— 根目录显示共享文件夹列表。
    if (path == '/' || path.isEmpty) {
      return _listShareItems();
    }

    final files = await _listDirectoryRaw(path);
    return files.map(_toFileItem).toList();
  }

  /// 上游: ugreen/ugreen_file_system.dart:66-100 的 FileItem 化（共享恒为目录、size=0）。
  Future<List<FileItem>> _listShareItems() async {
    final shares = await _listSharesRaw();
    return shares
        .map(
          (share) => FileItem(
            name: share.name,
            path: share.path,
            isDirectory: true,
            size: 0,
          ),
        )
        .toList();
  }

  /// 上游: ugreen/api/ugreen_api.dart:709-837 listShares。
  Future<List<_UGreenFileInfo>> _listSharesRaw() async {
    _log.i('UGreenApi: 获取共享文件夹列表');

    // 上游: :712-722 —— 优先走存储池 API（Home Assistant 集成发现的端点）。
    try {
      final poolResult = await _getSharesFromStoragePool();
      if (poolResult.isNotEmpty) {
        _log.i('UGreenApi: 从存储池获取到 ${poolResult.length} 个共享文件夹');
        return poolResult;
      }
    } on Exception catch (e) {
      // 上游: :720-721 AppError.ignore(e, st, '从存储池获取共享失败，继续尝试其他方法')
      _log.w('UGreenApi: 从存储池获取共享失败，继续尝试其他方法', e);
    }

    // 上游: :725-784 —— 逐字保留的共享候选端点（顺序不变）。
    // 注：上游每个候选的 `data` 恒为空 map，:795 处 `data.isEmpty ? null : data` 永远得 null，
    //     故这里不再携带 data 字段，wire 语义等价。
    final attempts = <Map<String, Object>>[
      {'endpoint': '/ugreen/v1/storage/share/list', 'method': 'GET'},
      {'endpoint': '/ugreen/v1/storage/share/list'},
      {'endpoint': '/ugreen/v1/storage/shares', 'method': 'GET'},
      {'endpoint': '/ugreen/v1/storage/volume/list', 'method': 'GET'},
      {'endpoint': '/ugreen/v1/filemgr/share/list', 'method': 'GET'},
      {'endpoint': '/ugreen/v1/filemgr/shares', 'method': 'GET'},
      {'endpoint': '/ugreen/v1/filemgr/root', 'method': 'GET'},
      {'endpoint': '/ugreen/v1/share/list', 'method': 'GET'},
      {'endpoint': '/ugreen/v1/shares', 'method': 'GET'},
      {'endpoint': '/ugreen/v1/user/home', 'method': 'GET'},
      {'endpoint': '/ugreen/v1/user/shares', 'method': 'GET'},
    ];

    for (final attempt in attempts) {
      _cancel?.check();
      try {
        final endpoint = attempt['endpoint']! as String;
        final method = attempt['method'] as String? ?? 'POST';
        _log.d('UGreenApi: 尝试共享端点 => $endpoint ($method)');

        final response = await _request(endpoint, method: method);

        final respData = response.data;
        _log.d('UGreenApi: listShares 响应 ($endpoint) 已收到（响应体不进日志：那是一整棵目录树）');

        // 上游: :802-808 —— 多候选键顺序 ['list','shares','volumes','items','folders'] 逐字保留。
        final shares = _extractSuccessfulList(respData, const [
          'list',
          'shares',
          'volumes',
          'items',
          'folders',
        ]);
        if (shares == null) continue;
        final items = <_UGreenFileInfo>[];
        for (final share in shares.whereType<Map<dynamic, dynamic>>()) {
          // 上游: :812-817 —— 名称多候选键。
          final name =
              share['name']?.toString() ??
              share['share_name']?.toString() ??
              share['volume_name']?.toString() ??
              share['folder_name']?.toString() ??
              '';
          if (name.isEmpty) continue;
          // 上游: :819-823 —— 路径多候选键，缺失则以 /<name> 兜底。
          final path =
              share['path']?.toString() ??
              share['mount_point']?.toString() ??
              share['share_path']?.toString() ??
              '/$name';
          items.add(_UGreenFileInfo(name: name, path: path, isDir: true));
        }
        _log.i('UGreenApi: 找到 ${items.length} 个共享文件夹 (使用 $endpoint)');
        return items;
      } on Exception catch (e) {
        _cancel?.check();
        // 上游: :828-829 AppError.ignore(e, st, '尝试不同的共享 API 端点，失败是预期的')
        _log.w('UGreenApi: 尝试不同的共享 API 端点，失败是预期的', e);
      }
    }

    // 上游: :833-836 —— 所有共享端点都失败，尝试直接列出根目录。
    _log.i('UGreenApi: 共享端点都失败，尝试直接列出根目录');
    return _listDirectoryRaw('/');
  }

  /// 上游: ugreen/api/ugreen_api.dart:875-980 _getSharesFromStoragePool。
  Future<List<_UGreenFileInfo>> _getSharesFromStoragePool() async {
    _log.d('UGreenApi: 尝试从存储池获取共享文件夹');

    // 上游: :878-881 —— GET /ugreen/v1/storage/pool/list。
    final response = await _request(
      '/ugreen/v1/storage/pool/list',
      method: 'GET',
    );
    final respData = response.data;
    _log.d('UGreenApi: storage/pool/list 响应状态已接收');

    if (respData is! Map<String, dynamic> ||
        _intCode(respData['code']) != 200) {
      return [];
    }

    final items = <_UGreenFileInfo>[];
    final data = respData['data'];
    final dataMap = data is Map<String, dynamic> ? data : null;

    // 上游: :894-900 —— 「结构 1」：{ pools: [ { volumes: [...] } ] }（多候选键）。
    final pools =
        dataMap?['pools'] ??
        dataMap?['list'] ??
        (data is List ? data : null) ??
        <dynamic>[];
    if (pools is List) {
      for (final pool in pools) {
        if (pool is! Map) continue;

        _log.d('UGreenApi: 处理存储池: ${pool['name']} (${pool['id']})');

        // 上游: :908-935 —— 从池中提取卷/共享（多候选键）。
        final volumes =
            pool['volumes'] ?? pool['shares'] ?? pool['folders'] ?? <dynamic>[];
        if (volumes is List) {
          for (final vol in volumes) {
            if (vol is! Map) continue;

            final name =
                vol['name']?.toString() ??
                vol['volume_name']?.toString() ??
                vol['share_name']?.toString() ??
                '';
            if (name.isEmpty) continue;

            var path =
                vol['path']?.toString() ??
                vol['mount_point']?.toString() ??
                vol['share_path']?.toString();
            if (path == null || path.isEmpty) {
              path = '/$name';
            }

            _log.d('UGreenApi: 发现共享: $name => $path');
            items.add(_UGreenFileInfo(name: name, path: path, isDir: true));
          }
        }

        // 上游: :937-952 —— 有些 UGOS 版本把共享文件夹放在 pool 级别。
        final shareFolders =
            pool['share_folders'] ?? pool['shared_folders'] ?? <dynamic>[];
        if (shareFolders is List) {
          for (final folder in shareFolders) {
            if (folder is! Map) continue;

            final name = folder['name']?.toString() ?? '';
            if (name.isEmpty) continue;

            final path = folder['path']?.toString() ?? '/$name';

            _log.d('UGreenApi: 发现共享文件夹: $name => $path');
            items.add(_UGreenFileInfo(name: name, path: path, isDir: true));
          }
        }
      }
    }

    // 上游: :956-977 —— 「结构 2」：直接的共享列表，去重后追加。
    final directShares =
        dataMap?['shares'] ?? dataMap?['volumes'] ?? <dynamic>[];
    if (directShares is List) {
      for (final share in directShares) {
        if (share is! Map) continue;

        final name = share['name']?.toString() ?? '';
        if (name.isEmpty) continue;

        final path =
            share['path']?.toString() ??
            share['mount_point']?.toString() ??
            '/$name';
        if (!items.any((item) => item.path == path)) {
          _log.d('UGreenApi: 发现直接共享: $name => $path');
          items.add(_UGreenFileInfo(name: name, path: path, isDir: true));
        }
      }
    }

    return items;
  }

  /// 上游: ugreen/api/ugreen_api.dart:356-538 listDirectory。
  Future<List<_UGreenFileInfo>> _listDirectoryRaw(String path) async {
    _log.i('UGreenApi: 列出目录 => $path');

    // 上游: :364-444 —— 逐字保留的 11 个列目录候选端点（顺序、参数名、方法均不变）。
    // 第 1 项是 UGOS Pro / 新固件的 v2 端点（带 header 认证 + referer），其余 10 条
    // 在 :384-443 依次标注「尝试 1..10」。
    final attempts = <Map<String, Object>>[
      {
        'endpoint': '/ugreen/v2/filemgr/getDirFileListV2',
        'data': <String, dynamic>{
          'path': path,
          'page': 1,
          'limit': 2000,
          'is_shield_recycle': false,
          'data_type': 0,
          'left_no_page_show': false,
          'left_count': 5000,
          'sort_type': 1,
          'reverse': false,
          'permission': 4,
          'root_type': 3,
        },
        'method': 'POST',
        'v2': true,
      },
      {
        'endpoint': '/ugreen/v1/filemgr/list',
        'data': <String, dynamic>{'path': path, 'page': 1, 'page_size': 1000},
        'method': 'POST',
      },
      {
        'endpoint': '/ugreen/v1/filemgr/list',
        'data': <String, dynamic>{'path': path, 'page': 1, 'page_size': 1000},
        'method': 'GET',
      },
      {
        'endpoint': '/ugreen/v1/filemgr/list',
        'data': <String, dynamic>{'dir': path, 'page': 1, 'limit': 1000},
        'method': 'POST',
      },
      {
        'endpoint': '/ugreen/v1/file/list',
        'data': <String, dynamic>{'path': path, 'page': 1, 'page_size': 1000},
        'method': 'POST',
      },
      {
        'endpoint': '/ugreen/v1/file/list',
        'data': <String, dynamic>{'path': path, 'page': 1, 'page_size': 1000},
        'method': 'GET',
      },
      {
        'endpoint': '/ugreen/v1/file/list',
        'data': <String, dynamic>{'folder': path, 'offset': 0, 'limit': 1000},
        'method': 'POST',
      },
      {
        'endpoint': '/ugreen/v2/file/list',
        'data': <String, dynamic>{'path': path, 'page': 1, 'page_size': 1000},
        'method': 'POST',
      },
      {
        'endpoint': '/ugreen/v1/filemgr/dir/list',
        'data': <String, dynamic>{'path': path},
        'method': 'POST',
      },
      {
        'endpoint': '/ugreen/v1/filemgr/dir/list',
        'data': <String, dynamic>{'path': path},
        'method': 'GET',
      },
      {
        'endpoint': '/ugreen/v1/filestation/list',
        'data': <String, dynamic>{'folder_path': path},
        'method': 'POST',
      },
    ];

    for (final attempt in attempts) {
      _cancel?.check();
      try {
        final endpoint = attempt['endpoint']! as String;
        final baseData = attempt['data']! as Map<String, dynamic>;
        final method = attempt['method'] as String? ?? 'POST';
        final isV2 = attempt['v2'] == true;
        final v2Headers = isV2 ? _v2AuthHeaders() : null;
        if (isV2 && (_v2ListDisabled || v2Headers == null)) continue;
        _log.d('UGreenApi: 尝试端点 => $endpoint ($method), 参数 => $baseData');

        // 上游: :456-472 —— 页码/偏移重算规则与 referer 头逐字保留。
        Future<Response<dynamic>> requestPage(int page) {
          final data = Map<String, dynamic>.from(baseData);
          if (data.containsKey('page')) data['page'] = page;
          if (data.containsKey('offset')) {
            data['offset'] = (page - 1) * (data['limit'] as int? ?? 1000);
          }
          return _request(
            endpoint,
            data: data,
            method: method,
            headers: {
              ...?v2Headers,
              if (isV2) 'referer': '${_dio.baseUrl}/filemgr/?_filemgr=my_nas',
            },
          );
        }

        var response = await requestPage(1);

        final respData = response.data;
        _log.d('UGreenApi: listDirectory 响应已收到（响应体不进日志：那是目录内容）');
        // 上游: :478-483 —— 多候选键顺序 ['list','files','items','children'] 逐字保留。
        final files = _extractSuccessfulList(respData, const [
          'list',
          'files',
          'items',
          'children',
        ]);
        if (files == null) continue;

        final allFiles = <dynamic>[...files];
        var pageFiles = files;
        final seenPages = <String>{_pageMarker(files)};
        // 上游: :489-517 —— 分页语义逐字保留（page_size 优先，其次 limit）。
        final pageSize =
            baseData['page_size'] as int? ?? baseData['limit'] as int?;
        final isPaged =
            baseData.containsKey('page') || baseData.containsKey('offset');
        if (pageSize != null && isPaged) {
          var page = 2;
          final total = _extractTotal(respData);
          while (pageFiles.length >= pageSize) {
            _cancel?.check();
            if (total != null && allFiles.length >= total) break;
            if (page > 10000) {
              // 原文 StateError('$endpoint 分页超过安全上限')
              throw AdapterFailures.protocolViolation('$endpoint 分页超过安全上限');
            }
            response = await requestPage(page++);
            final nextFiles = _extractSuccessfulList(response.data, const [
              'list',
              'files',
              'items',
              'children',
            ]);
            if (nextFiles == null) {
              // 原文 StateError('$endpoint 分页响应格式发生变化')
              throw AdapterFailures.protocolViolation('$endpoint 分页响应格式发生变化');
            }
            if (!seenPages.add(_pageMarker(nextFiles))) {
              // 原文 StateError('$endpoint 忽略分页参数，返回了重复页')
              throw AdapterFailures.protocolViolation('$endpoint 忽略分页参数，返回了重复页');
            }
            pageFiles = nextFiles;
            allFiles.addAll(pageFiles);
          }
        }

        final items = allFiles
            .whereType<Map<dynamic, dynamic>>()
            .map((file) => _parseFileInfo(file, path))
            .toList();

        // 上游: :523-527 —— v2 列表若忽略目录路径则本会话回退 v1。
        if (isV2 && !_itemsBelongToPath(items, path)) {
          _v2ListDisabled = true;
          _log.w('UGreenApi: v2 列表忽略目录路径，本会话回退 v1');
          continue;
        }
        _log.i('UGreenApi: 找到 ${items.length} 个文件/目录 (使用 $endpoint)');
        return items;
      } on AdapterFailure {
        // 上游靠 StateError（Error 子类，`on Exception` 抓不到）让分页不变量直接逃出；
        // 这里换成 AdapterFailure（Exception 子类），必须显式 rethrow 才等价。
        rethrow;
      } on CoreError {
        // 取消令牌抛 CoreError；`on Exception` 会把它吞掉，故显式放行。
        rethrow;
      } on Exception catch (e) {
        _cancel?.check();
        // 上游: :530-533 —— v2 尝试失败即本会话禁用 v2。
        if (attempt['v2'] == true) _v2ListDisabled = true;
        _log.w('UGreenApi: 尝试不同的 API 端点，失败是预期的', e);
      }
    }

    _log.e('UGreenApi: 所有端点都失败了，路径: $path');
    // 原文 StateError('UGREEN 无法获取目录列表：$path')。
    // 上游 10 个候选端点任一可用都会在循环内 return，走到这里即「没有可用列表端点」，
    // 按契约归为 UnsupportedApi（真机校准前该分支很可能每次都命中）。
    throw AdapterFailures.unsupported('绿联 NAS 无法获取目录列表：$path');
  }

  // ───────────────────────── 搜索 ─────────────────────────

  /// 上游: ugreen/ugreen_file_system.dart:209-266。
  ///
  /// 契约要求：服务端搜索不可用时抛 UnsupportedApi，**不得**回退成客户端递归遍历
  /// （上游 `_clientSideSearch` BFS 兜底已按此契约删除）。
  /// `roots` 是上层已授权的搜索根集合；适配器逐个根发出**上游原样的单路径请求**，
  /// 不自行扩大范围。
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
      results.addAll(await _searchServer(query, path: root));
    }
    return results;
  }

  /// 上游: ugreen/api/ugreen_api.dart:685-704 search + file_system:209-235 的映射。
  Future<List<FileItem>> _searchServer(String query, {String? path}) async {
    Response<dynamic> response;
    try {
      // 上游: :686-689 —— body {'keyword': query, 'path': ?path} 逐字保留。
      response = await _request(
        '/ugreen/v1/file/search',
        data: {'keyword': query, 'path': ?path},
      );
    } on DioException catch (e) {
      _cancel?.check();
      // 404 = 该端点不存在 → 按契约抛 UnsupportedApi，绝不回退遍历。
      if (e.response?.statusCode == 404) {
        throw AdapterFailures.unsupported('绿联 NAS 没有可用的服务端搜索端点（HTTP 404）');
      }
      throw AdapterFailures.network('绿联 NAS 搜索请求失败：${e.message}');
    }

    // 上游: :691-695 —— 多候选键顺序 ['files','list','items'] 逐字保留。
    final list = _extractSuccessfulList(response.data, const [
      'files',
      'list',
      'items',
    ]);
    if (list == null) {
      // 原文 StateError('UGREEN 搜索响应格式无效')
      throw AdapterFailures.protocolViolation('绿联 NAS 搜索响应格式无效');
    }

    return list
        .whereType<Map<dynamic, dynamic>>()
        .map((m) => _toFileItem(_parseFileInfo(m, path ?? '/')))
        .toList();
  }

  // ─────────────────────── 传输与解析 ───────────────────────

  /// 上游: ugreen/api/ugreen_api.dart:1096-1151 _request（自动处理 token 与 1024 重登）。
  Future<Response<dynamic>> _request(
    String path, {
    Map<String, dynamic>? data,
    String method = 'POST',
    Map<String, dynamic>? headers,
  }) async {
    _cancel?.check();
    final isGet = method.toUpperCase() == 'GET';

    // 上游: :1103 —— query 恒带 token；GET 时参数并入 query。
    Future<Response<dynamic>> send(Map<String, dynamic>? requestHeaders) =>
        _dio.request<dynamic>(
          path,
          queryParameters: <String, dynamic>{
            'token': _token ?? '',
            if (isGet) ...?data,
          },
          data: isGet ? null : data,
          options: Options(method: method, headers: requestHeaders),
        );

    late Response<dynamic> response;
    try {
      response = await send(headers);
    } on DioException catch (e) {
      // 上游: :1112-1117 —— 401/403 立即失效会话。
      if (e.response?.statusCode == 401 || e.response?.statusCode == 403) {
        _invalidateSession();
      }
      rethrow;
    }

    // 上游: :1119-1148 —— 检查 token 是否过期 (code 1024)，过期即重登并重试一次。
    final responseData = response.data;
    final responseCode = responseData is Map
        ? _intCode(responseData['code'])
        : 0;
    if (responseCode == 1024) {
      _log.i('UGreenApi: Token 过期，重新登录');
      _invalidateSession();
      if (_username != null && _password != null) {
        final result = await login(
          username: _username!,
          password: _password!,
        );
        if (result is LoginSuccess) {
          // 上游: :1130-1136 —— v2 请求的 token 头需重算，referer 原样带过。
          final retryHeaders =
              (headers?.containsKey('x-ugreen-token') ?? false)
              ? {
                  ...?_v2AuthHeaders(),
                  if (headers?['referer'] != null)
                    'referer': headers!['referer'],
                }
              : headers;
          return send(retryHeaders);
        }
      }
    } else if (_isAuthFailureCode(responseCode)) {
      // 上游: :1146-1148
      _invalidateSession();
    }

    return response;
  }

  /// 上游: ugreen/api/ugreen_api.dart:982-997 _v2AuthHeaders（v2 端点的认证头）。
  Map<String, dynamic>? _v2AuthHeaders() {
    final token = _token;
    final tokenId = _tokenId;
    final publicKey = _loginPublicKey;
    if (token == null || tokenId == null || publicKey == null) return null;
    try {
      return {
        'x-ugreen-security-key': tokenId,
        'x-ugreen-token': _rsaEncryptPassword(token, publicKey),
        if (_sessionCookie != null) 'cookie': _sessionCookie,
      };
    } on Exception catch (e) {
      // 上游: :993-996 AppError.ignore(e, st, 'UGREEN v2 token 加密失败，回退 v1')
      _log.w('UGreenApi: v2 token 加密失败，回退 v1', e);
      return null;
    }
  }

  /// 上游: ugreen/api/ugreen_api.dart:839-852 _extractSuccessfulList。
  List<dynamic>? _extractSuccessfulList(dynamic body, List<String> keys) {
    if (body is! Map<String, dynamic> || _intCode(body['code']) != 200) {
      return null;
    }
    final payload = body['data'];
    if (payload is List) return payload;
    if (payload is Map) {
      for (final key in keys) {
        final value = payload[key];
        if (value is List) return value;
      }
    }
    return null;
  }

  /// 上游: ugreen/api/ugreen_api.dart:854-860 _extractTotal。
  int? _extractTotal(dynamic body) {
    if (body is! Map) return null;
    final payload = body['data'];
    if (payload is! Map || payload['total'] == null) return null;
    final total = _intCode(payload['total']);
    return total > 0 ? total : null;
  }

  /// 上游: ugreen/api/ugreen_api.dart:862-869 _pageMarker（分页去重指纹）。
  String _pageMarker(List<dynamic> page) => page
      .map((item) {
        if (item is Map) {
          return '${item['path']}\u0000${item['id']}\u0000${item['name']}';
        }
        return item.toString();
      })
      .join('\u0001');

  /// 上游: ugreen/api/ugreen_api.dart:999-1011 _itemsBelongToPath。
  bool _itemsBelongToPath(List<_UGreenFileInfo> items, String path) {
    final normalized = path == '/' || path.isEmpty
        ? ''
        : path.endsWith('/')
        ? path.substring(0, path.length - 1)
        : path;
    if (normalized.isEmpty) return true;
    final pathedItems = items.where((item) => item.path.isNotEmpty).toList();
    if (pathedItems.isEmpty) return true;
    return pathedItems.any(
      (item) => item.path == normalized || item.path.startsWith('$normalized/'),
    );
  }

  /// 上游: ugreen/api/ugreen_api.dart:1073-1076 _intCode。
  int _intCode(dynamic value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  /// 上游: ugreen/api/ugreen_api.dart:1078-1086 _cookiesFrom。
  String? _cookiesFrom(Headers headers) {
    final cookies = headers.map.entries
        .where((entry) => entry.key.toLowerCase() == 'set-cookie')
        .expand((entry) => entry.value)
        .map((value) => value.split(';').first.trim())
        .where((value) => value.isNotEmpty)
        .toList();
    return cookies.isEmpty ? null : cookies.join('; ');
  }

  /// 上游: ugreen/api/ugreen_api.dart:1088-1093 _isAuthFailureCode。
  bool _isAuthFailureCode(int code) =>
      code == 401 || code == 403 || code == 1001 || code == 1002 || code == 1024;

  /// 上游: ugreen/api/ugreen_api.dart:1063-1071 _invalidateSession。
  void _invalidateSession() {
    _token = null;
    _tokenId = null;
    _loginPublicKey = null;
    _sessionCookie = null;
    _v2ListDisabled = false;
  }

  /// 上游: ugreen/api/ugreen_api.dart:1153-1200 _parseFileInfo（字段候选与顺序逐字保留）。
  _UGreenFileInfo _parseFileInfo(Map<dynamic, dynamic> file, String parentPath) {
    final name = file['name']?.toString() ?? file['filename']?.toString() ?? '';
    final isDir =
        file['is_dir'] == true ||
        file['isdir'] == true ||
        file['type'] == 'dir' ||
        file['type'] == 'folder' ||
        file['type'] == 'directory';

    DateTime? modified;
    // 上游: :1164-1174 —— 修改时间 9 个候选键。
    final modifiedValue =
        file['modified'] ??
        file['mtime'] ??
        file['modify_time'] ??
        file['modifyTime'] ??
        file['last_modified'] ??
        file['lastModified'] ??
        file['update_time'] ??
        file['updateTime'] ??
        file['time'] ??
        file['date'];
    if (modifiedValue != null) {
      modified = _parseDateTime(modifiedValue);
    }

    DateTime? created;
    // 上游: :1180-1186 —— 创建时间 6 个候选键。
    final createdValue =
        file['created'] ??
        file['ctime'] ??
        file['create_time'] ??
        file['createTime'] ??
        file['creation_time'] ??
        file['creationTime'];
    if (createdValue != null) {
      created = _parseDateTime(createdValue);
    }

    return _UGreenFileInfo(
      name: name,
      path: file['path']?.toString() ?? '$parentPath/$name',
      isDir: isDir,
      size: file['size'] == null ? null : _intCode(file['size']),
      modified: modified,
      created: created,
      mimeType: file['mime_type']?.toString() ?? file['mimetype']?.toString(),
    );
  }

  /// 上游: ugreen/api/ugreen_api.dart:1202-1238 _parseDateTime（多格式解析）。
  DateTime? _parseDateTime(dynamic value) {
    if (value == null) return null;

    if (value is int) {
      // 上游: :1207-1213 —— 小于 10000000000 视为秒，否则视为毫秒。
      if (value < 10000000000) {
        return DateTime.fromMillisecondsSinceEpoch(value * 1000);
      } else {
        return DateTime.fromMillisecondsSinceEpoch(value);
      }
    } else if (value is String) {
      final parsed = DateTime.tryParse(value);
      if (parsed != null) return parsed;

      // 上游: :1221-1233 —— 兜底解析 "2024-01-15 10:30:00"。
      final parts = value.split(RegExp(r'[\s\-/:]'));
      if (parts.length >= 3) {
        try {
          final year = int.parse(parts[0]);
          final month = int.parse(parts[1]);
          final day = int.parse(parts[2]);
          final hour = parts.length > 3 ? int.tryParse(parts[3]) ?? 0 : 0;
          final minute = parts.length > 4 ? int.tryParse(parts[4]) ?? 0 : 0;
          final second = parts.length > 5 ? int.tryParse(parts[5]) ?? 0 : 0;
          return DateTime(year, month, day, hour, minute, second);
        } on Exception catch (e) {
          // 上游: :1231-1233 AppError.ignore(e, st, '日期格式解析失败是预期的，返回 null')
          _log.d('UGreenApi: 日期格式解析失败是预期的，返回 null', e);
        }
      }
    }

    return null;
  }

  /// 上游: ugreen/ugreen_file_system.dart:40-60 的 _UGreenFileInfo → FileItem 映射。
  FileItem _toFileItem(_UGreenFileInfo file) => FileItem(
    name: file.name,
    path: file.path,
    isDirectory: file.isDir,
    size: file.size ?? 0,
    modifiedTime: file.modified,
    createdTime: file.created,
    mimeType: file.mimeType,
    extension: _getExtension(file.name),
  );

  /// 上游: ugreen/ugreen_file_system.dart:107-111 _getExtension（不含点；无扩展名返回 null）。
  String? _getExtension(String fileName) {
    final dotIndex = fileName.lastIndexOf('.');
    if (dotIndex == -1 || dotIndex == fileName.length - 1) return null;
    return fileName.substring(dotIndex + 1);
  }

  // ─────────────── RSA 公钥解析与 PKCS#1 v1.5 加密 ───────────────
  //
  // 上游: ugreen/api/ugreen_api.dart:231-308（pointycastle 的 PKCS1Encoding + ASN1Parser）。
  // 本移植用 dart:core 的 BigInt 与一个极简 DER 解析器重写，**零 pub 依赖**。

  /// 上游: :231-261 _encryptPassword —— RSAES-PKCS1-v1_5，输出 Base64。
  String _rsaEncryptPassword(String password, String rsaPublicKeyMaterial) {
    final key = _decodeRsaPublicKey(rsaPublicKeyMaterial);
    final message = utf8.encode(password);
    final modulusBytes = (key.n.bitLength + 7) >> 3;
    // RSAES-PKCS1-v1_5 要求 mLen <= k - 11。
    if (modulusBytes <= 11 || message.length > modulusBytes - 11) {
      throw AdapterFailures.unsupported('绿联 RSA 公钥长度不足，无法加密当前长度的口令');
    }

    // EM = 0x00 || 0x02 || PS || 0x00 || M，PS 为 >=8 字节的非零随机串。
    final encoded = Uint8List(modulusBytes);
    encoded[0] = 0x00;
    encoded[1] = 0x02;
    final paddingLength = modulusBytes - 3 - message.length;
    final random = Random.secure();
    for (var i = 0; i < paddingLength; i++) {
      var b = 0;
      while (b == 0) {
        b = random.nextInt(256);
      }
      encoded[2 + i] = b;
    }
    encoded[2 + paddingLength] = 0x00;
    encoded.setRange(2 + paddingLength + 1, modulusBytes, message);

    // c = m^e mod n，再定长 I2OSP 到 k 字节。
    final cipher = _bytesToBigInt(encoded).modPow(key.e, key.n);
    return base64Encode(_bigIntToFixedBytes(cipher, modulusBytes));
  }

  /// 上游: :232-246 —— 公钥载体：PEM / Base64(PEM) / Base64 DER 三种都试。
  ({BigInt n, BigInt e}) _decodeRsaPublicKey(String material) {
    final normalized = material.trim();
    final Uint8List der;
    if (normalized.contains('-----BEGIN')) {
      der = _pemToDer(normalized);
    } else {
      // UGOS 固件会返回「Base64(PEM)」或直接的 Base64 DER。
      final decoded = Uint8List.fromList(
        base64Decode(base64.normalize(normalized)),
      );
      final maybePem = utf8.decode(decoded, allowMalformed: true);
      der = maybePem.contains('-----BEGIN') ? _pemToDer(maybePem) : decoded;
    }
    return _parseRsaPublicKeyDer(der);
  }

  /// 上游: :264-279 _parsePublicKeyFromPem。
  Uint8List _pemToDer(String pem) {
    final lines = pem.split('\n');
    final base64String = lines
        .where(
          (line) =>
              !line.startsWith('-----BEGIN') &&
              !line.startsWith('-----END') &&
              line.trim().isNotEmpty,
        )
        .join();
    return Uint8List.fromList(base64Decode(base64String));
  }

  /// 上游: :281-308 _parsePublicKeyFromDer —— 认 PKCS#1 与 PKCS#8/SPKI 两种封装。
  ({BigInt n, BigInt e}) _parseRsaPublicKeyDer(Uint8List der) {
    final top = _DerReader(der).read();
    if (top.tag != 0x30) {
      throw AdapterFailures.protocolViolation('绿联 RSA 公钥格式无效（顶层不是 SEQUENCE）');
    }

    final inner = _DerReader(top.content);
    final first = inner.read();
    if (first.tag == 0x02) {
      // PKCS#1: SEQUENCE { INTEGER n, INTEGER e }
      final second = inner.read();
      if (second.tag != 0x02) {
        throw AdapterFailures.protocolViolation('绿联 RSA 公钥格式无效（PKCS#1 缺少指数）');
      }
      return (n: _bytesToBigInt(first.content), e: _bytesToBigInt(second.content));
    }

    if (first.tag == 0x30) {
      // PKCS#8 / SubjectPublicKeyInfo: SEQUENCE { AlgorithmIdentifier, BIT STRING }
      final bitString = inner.read();
      if (bitString.tag != 0x03) {
        throw AdapterFailures.protocolViolation('绿联 RSA 公钥格式无效（缺少 BIT STRING）');
      }
      final content = bitString.content;
      if (content.isEmpty || content[0] != 0) {
        throw AdapterFailures.protocolViolation('绿联 RSA 公钥格式无效（BIT STRING 头非法）');
      }
      final keySeq = _DerReader(Uint8List.sublistView(content, 1)).read();
      if (keySeq.tag != 0x30) {
        throw AdapterFailures.protocolViolation(
          '绿联 RSA 公钥格式无效（RSAPublicKey 不是 SEQUENCE）',
        );
      }
      final keyInner = _DerReader(keySeq.content);
      final modulus = keyInner.read();
      final exponent = keyInner.read();
      if (modulus.tag != 0x02 || exponent.tag != 0x02) {
        throw AdapterFailures.protocolViolation('绿联 RSA 公钥格式无效（n/e 不是 INTEGER）');
      }
      return (n: _bytesToBigInt(modulus.content), e: _bytesToBigInt(exponent.content));
    }

    // 上游: :307（原文 appL10n.ugreenEncryptionPublicKeyFormatInvalid）
    throw AdapterFailures.protocolViolation('绿联 RSA 公钥格式无法识别');
  }

  /// 大端字节 → BigInt（经十六进制，天然忽略前导 0x00 符号字节）。
  BigInt _bytesToBigInt(List<int> bytes) {
    final hex = StringBuffer();
    for (final b in bytes) {
      hex.write(b.toRadixString(16).padLeft(2, '0'));
    }
    if (hex.isEmpty) return BigInt.zero;
    return BigInt.parse(hex.toString(), radix: 16);
  }

  /// BigInt → 定长 k 字节（I2OSP）。
  Uint8List _bigIntToFixedBytes(BigInt value, int length) {
    final hex = value.toRadixString(16).padLeft(length * 2, '0');
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}

/// 极简 DER 读取器：只支持 RSA 公钥里出现的 SEQUENCE/INTEGER/BIT STRING 的 TLV 拆解。
///
/// 上游用 pointycastle 的 `ASN1Parser`；这里仅复刻 `_parsePublicKeyFromDer` 需要的最小面。
class _DerReader {
  _DerReader(this._bytes);

  final Uint8List _bytes;
  int _pos = 0;

  ({int tag, Uint8List content}) read() {
    if (_pos >= _bytes.length) {
      throw AdapterFailures.protocolViolation('绿联 RSA 公钥解析提前结束');
    }
    final tag = _bytes[_pos++];

    if (_pos >= _bytes.length) {
      throw AdapterFailures.protocolViolation('绿联 RSA 公钥长度字段缺失');
    }
    var length = _bytes[_pos++];
    if (length & 0x80 != 0) {
      final count = length & 0x7f;
      if (count == 0 || count > 4 || _pos + count > _bytes.length) {
        throw AdapterFailures.protocolViolation('绿联 RSA 公钥长度字段非法');
      }
      length = 0;
      for (var i = 0; i < count; i++) {
        length = (length << 8) | _bytes[_pos++];
      }
    }
    if (_pos + length > _bytes.length) {
      throw AdapterFailures.protocolViolation('绿联 RSA 公钥内容越界');
    }
    final content = Uint8List.sublistView(_bytes, _pos, _pos + length);
    _pos += length;
    return (tag: tag, content: content);
  }
}
