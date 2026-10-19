// 闪寻 dio 兼容层（零 pub 依赖）。
//
// 为什么需要它：MyNAS 上游 `lib/nas_adapters/` 下 qnap / ugreen / fnos / webdav
// 四个适配器**全部**依赖 `package:dio`。闪寻的 Dart 核心是一条「只用 Dart 标准库、
// 零 pub 依赖」的硬约束（见 SOURCE_MAP.md：许可隔离 + 不引传递依赖）。
//
// 直接 vendored dio 会带进它自己的依赖树与许可；而实测 dio 在这四个适配器里的
// 使用面**很窄**（只有 get/post/request/close，没有 CancelToken、没有 Interceptor），
// 所以自己写一层覆盖得住的兼容层比引入整个 dio 更划算，也更容易把安全策略钉死。
//
// ── 与 http_transport.dart 的关系 ────────────────────────────────
// 那一层是给群晖 DSM 用的：**只准 HTTPS + 只准同源 POST + form-urlencoded**。
// qnap / fnos / ugreen 是 HTTP JSON API，webdav 是 HTTP/HTTPS 上的
// PROPFIND/GET/PUT，形态完全不同，塞不进那个约束里。所以这里是**另一条**
// 受控传输：约束更宽（允许 http、允许任意方法），但下面这些一条都不放松。
//
// ── 安全策略（不放松的条款）────────────────────────────────────
//   1. **同源锁定**：所有请求必须落在构造时给定的 origin 内。适配器里任何
//      绝对 URL 一旦跑出 origin 就拒绝，不给「重定向到别处」留口子。
//   2. **不跟随重定向**：3xx 一律视为失败，不做透明跳转。
//   3. **响应体上限**：默认 8 MiB，超了即断，避免被超大响应拖死。
//   4. **真实取消**：取消令牌触发时 abort 底层 socket 并关闭连接，
//      不是只让 Future 超时（与 http_transport 同一约定）。
//   5. **明文 HTTP 需要显式放行**：`allowInsecureHTTP` 默认 false。
//      qnap/fnos 这类设备出厂就是 http 管理口，所以来源配置要显式带上
//      「这台就是明文」的意图，而不是默默降级。
//   6. **凭据不进 URL**：本层不主动把口令拼进 query。适配器若把会话令牌
//      放进 query（qnap 的 `sid` 属上游既有行为），那是会话标识不是口令，
//      但日志一律不打印 URL 的 query。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'protocol.dart';

/// 响应体的期望形态。对应 dio 的 `ResponseType`。
enum ResponseType { json, plain, bytes, stream }

/// 失败类型。只保留适配器实际会判别的几种（实测用到 4 种）。
enum DioExceptionType {
  connectionTimeout,
  sendTimeout,
  receiveTimeout,
  connectionError,
  badResponse,
  badCertificate,
  cancel,
  unknown,
}

/// 响应头包装。对应 dio 的 `Headers`。
class Headers {
  /// 小写化的头名，与 dio 一致。
  static const String contentTypeHeader = 'content-type';
  static const String contentLengthHeader = 'content-length';
  static const String acceptHeader = 'accept';

  final Map<String, List<String>> _values;

  Headers([Map<String, dynamic>? map]) : _values = _normalize(map);

  Headers.fromMap(Map<String, List<String>> map)
    : _values = {
        for (final entry in map.entries)
          entry.key.toLowerCase(): List<String>.from(entry.value),
      };

  static Map<String, List<String>> _normalize(Map<String, dynamic>? map) {
    final out = <String, List<String>>{};
    if (map == null) return out;
    map.forEach((key, value) {
      if (value == null) return;
      if (value is List) {
        out[key.toLowerCase()] = value.map((e) => '$e').toList();
      } else {
        out[key.toLowerCase()] = ['$value'];
      }
    });
    return out;
  }

  /// 头名大小写不敏感。
  String? value(String name) {
    final list = _values[name.toLowerCase()];
    if (list == null || list.isEmpty) return null;
    return list.first;
  }

  List<String>? operator [](String name) => _values[name.toLowerCase()];

  Map<String, List<String>> get map => _values;

  factory Headers.fromHttpHeaders(HttpHeaders source) {
    final map = <String, List<String>>{};
    source.forEach((name, values) {
      map[name.toLowerCase()] = List<String>.from(values);
    });
    return Headers.fromMap(map);
  }
}

/// `ResponseType.stream` 的载荷。对应 dio 的 `ResponseBody`。
class ResponseBody {
  final Stream<List<int>> stream;
  const ResponseBody(this.stream);
}

/// 单次请求的选项。对应 dio 的 `Options`。
class Options {
  String? method;
  Map<String, dynamic>? headers;
  ResponseType? responseType;
  String? contentType;
  bool Function(int? status)? validateStatus;
  Duration? connectTimeout;
  Duration? receiveTimeout;
  Duration? sendTimeout;

  Options({
    this.method,
    this.headers,
    this.responseType,
    this.contentType,
    this.validateStatus,
    this.connectTimeout,
    this.receiveTimeout,
    this.sendTimeout,
  });
}

/// 连接级默认选项。对应 dio 的 `BaseOptions`。
class BaseOptions {
  String baseUrl;
  Map<String, dynamic>? headers;
  ResponseType responseType;
  String? contentType;
  bool Function(int? status)? validateStatus;
  Duration? connectTimeout;
  Duration? receiveTimeout;
  Duration? sendTimeout;

  BaseOptions({
    this.baseUrl = '',
    this.headers,
    this.responseType = ResponseType.json,
    this.contentType,
    this.validateStatus,
    this.connectTimeout,
    this.receiveTimeout,
    this.sendTimeout,
  });
}

/// 已经解析、可以交给传输层的请求。对应 dio 的 `RequestOptions`。
class RequestOptions {
  final String path;
  final String method;
  final Map<String, dynamic>? queryParameters;
  final Object? data;
  final Map<String, dynamic>? headers;
  final ResponseType responseType;
  final String? contentType;
  final bool Function(int? status)? validateStatus;
  final Duration? connectTimeout;
  final Duration? receiveTimeout;
  /// 发送预算。此前 RequestOptions **没有这个字段** —— 于是 sendTimeout 在
  /// BaseOptions / Options 上被解析、被合并，一路传到这里就断了，从未作用于请求。
  final Duration? sendTimeout;

  /// 最终请求地址，已通过同源校验。
  final Uri uri;

  RequestOptions({
    required this.path,
    required this.method,
    this.queryParameters,
    this.data,
    this.headers,
    this.responseType = ResponseType.json,
    this.contentType,
    this.validateStatus,
    this.connectTimeout,
    this.receiveTimeout,
    this.sendTimeout,
    required this.uri,
  });
}

/// 响应。对应 dio 的 `Response<T>`。
class Response<T> {
  final T? data;
  final int? statusCode;
  final Headers headers;
  final RequestOptions requestOptions;

  Response({
    this.data,
    this.statusCode,
    Headers? headers,
    required this.requestOptions,
  }) : headers = headers ?? Headers();
}

/// 失败。对应 dio 的 `DioException`。
///
/// `error` 里挂着本层自己的 `CoreError`，便于 harness 把它翻成线上错误码，
/// 而不是把 dio 的类型名直接暴露出去。
class DioException implements Exception {
  final DioExceptionType type;
  final Response<dynamic>? response;
  final String message;
  final Object? error;

  DioException({
    required this.type,
    this.response,
    required this.message,
    this.error,
  });

  @override
  String toString() => 'DioException(${type.name}): $message';
}

/// dio 子集实现。只实现四个适配器实际用到的方法，多一个都不加。
class Dio {
  BaseOptions options;

  /// harness 注入的取消令牌。置位后，在飞的请求会被真实中止。
  Cancellation? cancellation;

  /// 明文 HTTP 放行开关。默认 false —— 想连 http 的来源必须显式打开。
  bool allowInsecureHTTP;

  /// 响应体上限，超过即判定失败。
  int maxResponseBytes;

  Dio([BaseOptions? options])
    : options = options ?? BaseOptions(),
      allowInsecureHTTP = false,
      maxResponseBytes = 8 * 1024 * 1024;

  /// 兼容上游写法：`_dio.options.baseUrl`。
  String get baseUrl => options.baseUrl;

  /// 已解析的 origin。所有请求都要落在这里面。
  Uri get _origin {
    final parsed = Uri.tryParse(options.baseUrl);
    if (parsed == null || parsed.host.isEmpty) {
      throw _fail(DioExceptionType.unknown, '来源地址不合法');
    }
    final scheme = parsed.scheme.toLowerCase();
    if (scheme != 'https' && !(scheme == 'http' && allowInsecureHTTP)) {
      throw _fail(
        DioExceptionType.unknown,
        scheme == 'http' ? '该来源未允许明文 HTTP 直连' : '只接受 http/https 来源',
      );
    }
    // origin 只留 scheme+host+port，路径部分由各次请求自己拼。
    return Uri(scheme: scheme, host: parsed.host, port: parsed.port);
  }

  Future<Response<T>> get<T>(
    String path, {
    Map<String, dynamic>? queryParameters,
    Options? options,
  }) => request<T>(
    path,
    method: 'GET',
    queryParameters: queryParameters,
    options: options,
  );

  Future<Response<T>> post<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    void Function(int sent, int total)? onSendProgress,
  }) => request<T>(
    path,
    method: 'POST',
    data: data,
    queryParameters: queryParameters,
    options: options,
  );

  Future<Response<T>> request<T>(
    String path, {
    String? method,
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
  }) async {
    final resolved = _resolve(path, method: method, data: data,
        queryParameters: queryParameters, options: options);
    final token = cancellation;

    token?.check();
    final client = HttpClient();
    client.connectionTimeout = resolved.connectTimeout;
    client.idleTimeout = const Duration(seconds: 5);
    HttpClientRequest? httpRequest;

    void abort() {
      httpRequest?.abort();
      client.close(force: true);
    }

    token?.listeners.add(abort);
    try {
      final req = await client.openUrl(resolved.method, resolved.uri);
      httpRequest = req;
      token?.check();

      // 不跟随重定向：跳走就意味着离开了已授权的来源。
      req.followRedirects = false;
      req.maxRedirects = 0;

      // ★ 所有请求头必须在写入正文**之前**设置。
      // dart:io 在 `req.add(...)` 之后会把 headers 置为不可变，之后任何 set
      // 都抛 `HttpException: HTTP headers are not mutable`。
      // 这个顺序坑只影响带正文的请求（POST/PUT/PROPFIND），GET 不会触发 ——
      // 所以它躲过了最初那批 GET 测试，是 WebDAV 的 PROPFIND 把它逼出来的。
      resolved.headers?.forEach((name, value) {
        if (value == null) return;
        if (name.toLowerCase() == 'content-type') return; // 下面单独设置
        req.headers.set(name, value);
      });
      _assertSafeHeaders(resolved.headers);

      final body = _encodeBody(resolved);
      if (body != null) {
        req.headers.contentType =
            ContentType.parse(resolved.contentType ?? 'application/json');
        req.add(body);
      }

      // 发送 + 等响应头：这正是「服务端卡住就永久挂起」的位置，必须带预算。
      final streamed = await _withBudget(
        req.close(),
        _tighterDuration(resolved.sendTimeout, resolved.receiveTimeout),
        '等待响应超时',
        abort,
      );
      token?.check();

      final status = streamed.statusCode;
      if (status >= 300 && status < 400) {
        throw _fail(DioExceptionType.badResponse, '服务端要求重定向，已拒绝');
      }

      final headers = Headers.fromHttpHeaders(streamed.headers);
      final accepts = resolved.validateStatus ?? _defaultValidate;

      if (!accepts(status)) {
        // 读掉一点正文便于诊断，但绝不整包吞下错误页。
        await streamed.drain<void>().catchError((_) {});
        final response = Response<T>(
          data: null,
          statusCode: status,
          headers: headers,
          requestOptions: resolved,
        );
        throw DioException(
          type: DioExceptionType.badResponse,
          response: response,
          message: 'HTTP $status',
        );
      }

      final data = await _withBudget(
        _readBody<T>(streamed, resolved, headers, token),
        resolved.receiveTimeout,
        '读取响应超时',
        abort,
      );
      return Response<T>(
        data: data,
        statusCode: status,
        headers: headers,
        requestOptions: resolved,
      );
    } on DioException {
      token?.check();
      rethrow;
    } on CoreError catch (error) {
      // 取消令牌抛出的是 CoreError（reason 决定 kind），要原样保真 ——
      // 否则「用户取消」会被说成「网络故障」。
      throw DioException(
        type: error.kind == 'Cancelled' || error.kind == 'TimedOut'
            ? DioExceptionType.cancel
            : DioExceptionType.connectionError,
        message: error.kind,
        error: error,
      );
    } on HandshakeException catch (error) {
      throw DioException(
        type: DioExceptionType.badCertificate,
        message: 'TLS 握手失败',
        error: error,
      );
    } on SocketException catch (error) {
      throw DioException(
        type: DioExceptionType.connectionError,
        message: '无法连接目标设备',
        error: error,
      );
    } on TimeoutException catch (error) {
      throw DioException(
        type: DioExceptionType.receiveTimeout,
        message: '请求超时',
        error: error,
      );
    } catch (error) {
      token?.check();
      // 兜底分支要带上**底层错误类型**，否则「请求失败」四个字什么都说明不了 ——
      // 适配器层只能看到一层壳，排查时得靠猜。这里把类型名带上，
      // 但不带 URL/query（凭据可能挂在 query 上）。
      throw DioException(
        type: DioExceptionType.unknown,
        message: '请求失败（${error.runtimeType}）',
        error: error,
      );
    } finally {
      token?.listeners.remove(abort);
      client.close(force: true);
    }
  }

  /// 给「服务端不响应就会一直等下去」的 await 加预算，超时同时 abort 底层连接。
  ///
  /// 背景（本机真服务器实测）：此前只有 `connectTimeout` 真正生效
  /// （走 `HttpClient.connectionTimeout`），而 `receiveTimeout` / `sendTimeout`
  /// **只被解析、合并、层层传递，从未作用于任何请求** ——
  /// 打一个挂起 5 秒的服务器时，600ms 的预算毫无效果（实测等满 5005ms，
  /// 还把它当成成功响应收下）。计划 §2.2 要求的 Timeout 因此在真实设备上不成立。
  ///
  /// 超时时必须 `abort()`：只让 Future 提前抛错不够，
  /// 底层 socket 和已占用的内存会一直挂在后台。
  static Future<T> _withBudget<T>(
    Future<T> future,
    Duration? budget,
    String message,
    void Function() abort,
  ) {
    if (budget == null || budget <= Duration.zero) return future;
    return future.timeout(budget, onTimeout: () {
      abort();
      throw DioException(
        type: DioExceptionType.receiveTimeout,
        message: message,
      );
    });
  }

  /// 取两个预算里更紧的那个；都为 null 则为 null。
  static Duration? _tighterDuration(Duration? a, Duration? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a < b ? a : b;
  }

  /// 上游会在 finally 里调 `close()`。这里无连接池可关，保留方法只为接口一致。
  void close({bool force = false}) {}

  static bool _defaultValidate(int? status) =>
      status != null && status >= 200 && status < 300;

  DioException _fail(DioExceptionType type, String message) =>
      DioException(type: type, message: message);

  /// 凭据只走 header / 会话标识，禁止把口令塞进 Authorization 之外的明文头。
  static void _assertSafeHeaders(Map<String, dynamic>? headers) {
    if (headers == null) return;
    headers.forEach((name, value) {
      if (value == null) return;
      final text = '$value';
      if (text.contains('\n') || text.contains('\r')) {
        throw DioException(
          type: DioExceptionType.unknown,
          message: '请求头含非法字符',
        );
      }
    });
  }

  RequestOptions _resolve(
    String path, {
    String? method,
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
  }) {
    final origin = _origin;
    // 连接级默认头 + 本次请求头；本次的覆盖连接级的。
    final mergedHeaders = <String, dynamic>{
      ...?this.options.headers,
      ...?options?.headers,
    };

    final target = _resolveUri(origin, path, queryParameters);
    if (target.host != origin.host || target.port != origin.port ||
        target.scheme != origin.scheme) {
      // 绝对 URL 想跑出已授权的 origin —— 直接拒绝，不给 SSRF 留缝。
      throw _fail(DioExceptionType.unknown, '请求地址超出了来源范围');
    }

    return RequestOptions(
      path: path,
      method: (options?.method ?? method ?? (data != null ? 'POST' : 'GET'))
          .toUpperCase(),
      queryParameters: queryParameters,
      data: data,
      headers: mergedHeaders,
      responseType: options?.responseType ?? this.options.responseType,
      contentType: options?.contentType ?? this.options.contentType,
      validateStatus: options?.validateStatus ?? this.options.validateStatus,
      connectTimeout:
          options?.connectTimeout ?? this.options.connectTimeout,
      receiveTimeout:
          options?.receiveTimeout ?? this.options.receiveTimeout,
      sendTimeout: options?.sendTimeout ?? this.options.sendTimeout,
      uri: target,
    );
  }

  /// 把相对路径拼到 origin 上。绝对 URL 只允许与 origin 同源。
  Uri _resolveUri(
    Uri origin,
    String path,
    Map<String, dynamic>? queryParameters,
  ) {
    final parsed = Uri.tryParse(path);
    if (parsed == null) throw _fail(DioExceptionType.unknown, '请求路径不合法');

    Uri base;
    if (parsed.hasScheme) {
      base = parsed;
    } else {
      // 上游有的端点写 '/api/...'，有的写 'api/...'，两种都要能拼。
      base = origin.replace(path: path.startsWith('/') ? path : '/$path');
    }

    final merged = <String, String>{};
    base.queryParameters.forEach((key, value) => merged[key] = value);
    queryParameters?.forEach((key, value) {
      if (value != null) merged[key] = '$value';
    });
    return merged.isEmpty ? base : base.replace(queryParameters: merged);
  }

  /// GET 不带正文；POST/PUT 默认 JSON，除非 Options 指定了别的 content-type。
  Uint8List? _encodeBody(RequestOptions options) {
    if (options.method == 'GET' || options.method == 'HEAD') return null;
    final data = options.data;
    if (data == null) return null;
    if (data is String) return Uint8List.fromList(utf8.encode(data));
    if (data is List<int>) return Uint8List.fromList(data);
    return Uint8List.fromList(utf8.encode(jsonEncode(data)));
  }

  Future<T?> _readBody<T>(
    HttpClientResponse response,
    RequestOptions options,
    Headers headers,
    Cancellation? token,
  ) async {
    switch (options.responseType) {
      case ResponseType.stream:
        final stream = _limitedStream(response, token);
        return ResponseBody(stream) as T;
      case ResponseType.bytes:
        final bytes = await _collect(response, token);
        return bytes as T;
      case ResponseType.plain:
        final bytes = await _collect(response, token);
        return utf8.decode(bytes, allowMalformed: true) as T;
      case ResponseType.json:
        final bytes = await _collect(response, token);
        if (bytes.isEmpty) return null;
        final text = utf8.decode(bytes, allowMalformed: true);
        if (text.trim().isEmpty) return null;
        try {
          return jsonDecode(text) as T;
        } catch (_) {
          // 设备返回了非 JSON（例如 HTML 登录页）。不假装成功：
          // 交给调用方按 DioException 处理，避免把错误页当数据用。
          throw DioException(
            type: DioExceptionType.badResponse,
            message: '响应不是合法 JSON',
          );
        }
    }
  }

  Future<Uint8List> _collect(
    HttpClientResponse response,
    Cancellation? token,
  ) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in _limitedStream(response, token)) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  /// 逐块读取并做上限检查；取消令牌触发时立即中断。
  Stream<List<int>> _limitedStream(
    HttpClientResponse response,
    Cancellation? token,
  ) async* {
    var total = 0;
    await for (final chunk in response) {
      token?.check();
      total += chunk.length;
      if (total > maxResponseBytes) {
        throw _fail(DioExceptionType.badResponse, '响应体超出上限');
      }
      yield chunk;
    }
  }
}
