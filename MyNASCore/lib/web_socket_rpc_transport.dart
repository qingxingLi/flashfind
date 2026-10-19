// 通用 WebSocket RPC 传输层（闪寻 FlashFind，零 pub 依赖）。
//
// ── 为什么单独一层 ────────────────────────────────────────────────
// 计划 §3 要求「Transport 与 Vendor Adapter 分离」。fnOS 的真实传输**不是 HTTP**
// 而是 WebSocket RPC（GET /api/v1/auth/login 返回 404，
// 落到 SPA 的 index.html fallback，证明上游 fnos_api.dart 的 HTTP 猜测形态不成立）。
// 因此需要一层通用的「请求-响应 + reqid 关联 + 超时 + 取消」的 WebSocket 传输，
// 让 FnOSAdapter 不必自己管 socket 生命周期。
//
// 只依赖 dart:io 的 WebSocket / WebSocketTransformer —— 不引 package:web_socket_channel。
//
// ── 帧格式：默认 codec 明确标注为「待真机确认」─────────────────────
// 从飞牛 SPA bundle（2.9MB）挖到的静态线索是：
//   连接 ws://<host>/websocket?type=main
//   请求 {reqid, req:"user.login", ...}
//   响应与请求以 reqid 关联（线索里出现 "<reqid>_result" 形态的键）
// 但**哪个字段承载 reqid、响应是顶层还是嵌套、错误怎么表达**，
// 必须由真机 Login Probe 落实。
//
// 所以本类把「编帧 / 解帧 / 判失败 / 取结果」四件事抽成可注入的 [RpcFrameCodec]。
// 默认实现 [ReqidFieldCodec] 按上述线索给出，并在文档与 API 上显式声明它未经验证。
// 真机探测后只需换掉一个 codec —— 传输层一行不用改。这不是「猜」，是把
// 未确认的部分收敛到一个可替换点上，并把它标出来。
//
// ── 本机测试通过 ≠ 真机可用 ──────────────────────────────────────
// test_web_socket_rpc.dart 起的是本机真 WebSocket 服务器，证明的是**传输层自身的
// 正确性**（关联、超时、取消、断线、脏帧容错），不是飞牛可用。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'adapter_support.dart';
import 'protocol.dart';

/// 一次 RPC 调用失败的原因。[kind] 取值与项目其它层保持一致：
/// NotConnected / TimedOut / Cancelled / ConnectionClosed /
/// NetworkFailure / ProtocolViolation / ServerError。
class RpcFailure implements Exception {
  const RpcFailure(this.kind, this.message, {this.reqid});

  final String kind;
  final String message;
  final int? reqid;

  @override
  String toString() => 'RpcFailure($kind${reqid == null ? '' : ', reqid=$reqid'}, $message)';
}

/// 帧编解码策略：把「这个品牌的 RPC 长什么样」与传输层解耦。
///
/// 实现者只需回答四个问题：怎么编请求、响应怎么找 reqid、怎么判失败、结果在哪。
abstract class RpcFrameCodec {
  const RpcFrameCodec();

  /// 把一次调用编成要发送的**文本帧**。
  String encode(int reqid, String method, Map<String, Object?>? params);

  /// 从收到的响应帧里取出它对应的 reqid。
  /// 返回 null 表示这帧与任何在等请求都无关（心跳、服务端推送、日志），
  /// 传输层会**静默忽略**而不是报错。
  int? reqidOf(Map<String, Object?> frame);

  /// 该响应是否表示业务失败。
  bool isFailure(Map<String, Object?> frame);

  /// 失败原因（仅在 [isFailure] 为 true 时调用）。
  String failureReason(Map<String, Object?> frame);

  /// 结果体。返回 null 表示「成功但没有数据」。
  Map<String, Object?>? payload(Map<String, Object?> frame);
}

/// 默认 codec：请求 `{"reqid":N,"req":"<method>", ...params}`，
/// 响应按**同名字段 `reqid`** 关联，结果取 `result`，失败看 `error`。
///
/// ★★ 这个形态**尚未在真机上确认**，来源是对飞牛 SPA bundle 的静态线索。
/// 任何品牌适配器使用它时，结论必须标「待确认」。真机探测后换掉即可。
class ReqidFieldCodec extends RpcFrameCodec {
  const ReqidFieldCodec({
    this.reqidKey = 'reqid',
    this.methodKey = 'req',
    this.resultKey = 'result',
    this.errorKey = 'error',
  });

  final String reqidKey;
  final String methodKey;
  final String resultKey;
  final String errorKey;

  @override
  String encode(int reqid, String method, Map<String, Object?>? params) =>
      jsonEncode(<String, Object?>{
        reqidKey: reqid,
        methodKey: method,
        ...?params,
      });

  @override
  int? reqidOf(Map<String, Object?> frame) {
    final value = frame[reqidKey];
    if (value is int) return value;
    if (value is String) return int.tryParse(value);
    return null;
  }

  @override
  bool isFailure(Map<String, Object?> frame) =>
      frame.containsKey(errorKey) && frame[errorKey] != null;

  @override
  String failureReason(Map<String, Object?> frame) => '${frame[errorKey]}';

  @override
  Map<String, Object?>? payload(Map<String, Object?> frame) {
    final raw = frame[resultKey] ?? frame;
    return raw is Map ? raw.cast<String, Object?>() : null;
  }
}

/// 在飞的调用。
class _Pending {
  _Pending(this.reqid, this.method);

  final int reqid;
  final String method;
  final Completer<Map<String, Object?>> _completer =
      Completer<Map<String, Object?>>();
  Timer? timer;
  void Function()? cancelListener;

  Future<Map<String, Object?>> get future => _completer.future;
  bool get isCompleted => _completer.isCompleted;

  void complete(Map<String, Object?> value) {
    if (!_completer.isCompleted) _completer.complete(value);
  }

  void completeError(Object error) {
    if (!_completer.isCompleted) _completer.completeError(error);
  }
}

/// 通用 WebSocket RPC 传输层。
///
/// 生命周期：`connect()` → 若干 `call()` → `close()`；断线可 `reconnect()`。
/// 连接是**单条**，多并发调用在同一 socket 上按 reqid 关联，不排队。
class WebSocketRpcTransport {
  WebSocketRpcTransport({
    required this.url,
    RpcFrameCodec? codec,
    Map<String, dynamic>? headers,
    this.connectTimeout = const Duration(seconds: 10),
    this.defaultCallTimeout = const Duration(seconds: 20),
    this.pingInterval = const Duration(seconds: 30),
    this.maxFrameBytes = 8 * 1024 * 1024,
  })  : codec = codec ?? const ReqidFieldCodec(),
        headers = headers ?? const <String, dynamic>{};

  /// 完整地址，例如 `ws://<设备地址>:PORT/websocket?type=main`。
  final String url;
  final RpcFrameCodec codec;
  final Map<String, dynamic> headers;
  final Duration connectTimeout;
  final Duration defaultCallTimeout;

  /// dart:io 内置心跳：设为非 null 后底层会自动发 ping 帧并处理 pong。
  /// 设为 [Duration.zero] 可关闭。
  final Duration pingInterval;

  /// 单帧文本上限。超限丢弃并记日志，绝不让一条脏帧吃光内存。
  final int maxFrameBytes;

  final Logger _log = Logger();

  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  bool _closing = false;
  int _nextReqid = 1;
  final Map<int, _Pending> _pending = <int, _Pending>{};

  bool get isConnected => _socket != null;
  int get pendingCount => _pending.length;
  int get lastAssignedReqid => _nextReqid - 1;

  // ─────────────────────────── 连接 ───────────────────────────

  /// 建连。已连接时直接返回（幂等）。
  Future<void> connect() async {
    if (_socket != null) return;
    _closing = false;

    try {
      final socket = await WebSocket.connect(
        url,
        headers: headers.isEmpty ? null : headers,
      ).timeout(connectTimeout);

      if (pingInterval > Duration.zero) socket.pingInterval = pingInterval;
      _socket = socket;
      _subscription = socket.listen(
        _onFrame,
        onError: (Object error) =>
            _failAll(RpcFailure('ConnectionClosed', '连接出错：$error')),
        onDone: () => _failAll(
          const RpcFailure('ConnectionClosed', '连接已被对端关闭'),
        ),
        cancelOnError: false,
      );
      _log.i('WebSocketRpcTransport: 已连接 ${Logger.safeUrl(url)}');
    } on TimeoutException {
      throw RpcFailure('TimedOut', '连接超时（${connectTimeout.inSeconds}s）');
    } on SocketException catch (error) {
      throw RpcFailure('NetworkFailure', '无法连接：${error.message}');
    } on WebSocketException catch (error) {
      throw RpcFailure('NetworkFailure', 'WebSocket 握手失败：${error.message}');
    }
  }

  /// 先关再连。用于网络抖动后的恢复。
  Future<void> reconnect() async {
    await close();
    await connect();
  }

  // ─────────────────────────── 调用 ───────────────────────────

  /// 发一次请求并等它的响应。
  ///
  /// [reqid] 不传时自动分配；传入可复现固定编号（便于真机抓包比对）。
  /// [cancellation] 触发时，本次调用立刻以 `Cancelled` 失败 ——
  /// 是**真的不再等**，而不是晚一点再返回。
  Future<Map<String, Object?>> call(
    String method, {
    Map<String, Object?>? params,
    Duration? timeout,
    Cancellation? cancellation,
    int? reqid,
    void Function(int reqid, String method)? onSent,
  }) async {
    var socket = _socket;
    if (socket == null || _closing) {
      throw const RpcFailure('NotConnected', '尚未连接，无法发起调用');
    }
    if (cancellation != null) {
      cancellation.check(); // 已取消就别发出去
    }

    final id = reqid ?? _nextReqid++;
    if (reqid == null) {
      // 保持 _nextReqid 始终大于任何用过的编号。
    } else if (id >= _nextReqid) {
      _nextReqid = id + 1;
    }

    final pending = _Pending(id, method);
    _pending[id] = pending;

    try {
      socket.add(codec.encode(id, method, params));
      onSent?.call(id, method);
      _log.d('WebSocketRpcTransport: → $method (reqid=$id)');
    } catch (error) {
      _pending.remove(id);
      throw RpcFailure('ConnectionClosed', '发送失败：$error', reqid: id);
    }

    final timer = Timer(timeout ?? defaultCallTimeout, () {
      final waiting = _pending.remove(id);
      if (waiting != null) {
        waiting.completeError(
          RpcFailure('TimedOut', '调用 $method 超时（reqid=$id）', reqid: id),
        );
      }
    });
    pending.timer = timer;

    if (cancellation != null) {
      void abort() {
        final waiting = _pending.remove(id);
        if (waiting != null) {
          waiting.completeError(
            RpcFailure('Cancelled', cancellation.reason, reqid: id),
          );
        }
      }

      pending.cancelListener = abort;
      cancellation.listeners.add(abort);
    }

    try {
      return await pending.future;
    } finally {
      timer.cancel();
      final listener = pending.cancelListener;
      if (cancellation != null && listener != null) {
        cancellation.listeners.remove(listener);
      }
      _pending.remove(id);
    }
  }

  // ─────────────────────────── 收帧 ───────────────────────────

  void _onFrame(dynamic data) {
    // 只认文本帧。二进制帧（若将来需要）另行支持，先明确忽略而不是崩。
    if (data is! String) {
      _log.d('WebSocketRpcTransport: 忽略非文本帧（${data.runtimeType}）');
      return;
    }
    if (data.length > maxFrameBytes) {
      _log.w('WebSocketRpcTransport: 帧超过上限（${data.length} > $maxFrameBytes），已丢弃');
      return;
    }

    Map<String, Object?> frame;
    try {
      final decoded = jsonDecode(data);
      if (decoded is! Map) {
        _log.d('WebSocketRpcTransport: 忽略非对象帧');
        return;
      }
      frame = decoded.cast<String, Object?>();
    } catch (_) {
      // 非 JSON 文本（心跳文案、服务端日志…）：忽略。一条脏帧不能拖垮整条连接。
      _log.d('WebSocketRpcTransport: 忽略非 JSON 帧');
      return;
    }

    final id = codec.reqidOf(frame);
    if (id == null) {
      _log.d('WebSocketRpcTransport: 无 reqid 的帧（推送/通知），忽略');
      return;
    }

    final pending = _pending.remove(id);
    if (pending == null) {
      // 已超时/已取消的调用，响应晚到了。丢弃 —— 这是正常竞态，不是错误。
      _log.d('WebSocketRpcTransport: reqid=$id 已无等待者（超时或被取消），丢弃');
      return;
    }

    pending.timer?.cancel();
    if (codec.isFailure(frame)) {
      pending.completeError(
        RpcFailure('ServerError', codec.failureReason(frame), reqid: id),
      );
    } else {
      pending.complete(codec.payload(frame) ?? const <String, Object?>{});
    }
  }

  // ─────────────────────────── 关闭 ───────────────────────────

  /// 关闭连接并让所有在飞调用立即失败。可重复调用。
  Future<void> close() async {
    _closing = true;
    final socket = _socket;
    _socket = null;

    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();

    // 先让等的人拿到明确原因，再关 socket —— 否则它们会一直挂着。
    _failAll(const RpcFailure('ConnectionClosed', '连接已关闭'));

    try {
      await socket?.close(WebSocketStatus.normalClosure, 'client close');
    } catch (_) {
      // 已经断了就断了，关闭操作本身不该抛。
    }
    _log.i('WebSocketRpcTransport: 已关闭 ${Logger.safeUrl(url)}');
  }

  void _failAll(RpcFailure failure) {
    if (_pending.isEmpty) return;
    final snapshot = List<_Pending>.of(_pending.values);
    _pending.clear();
    for (final pending in snapshot) {
      pending.timer?.cancel();
      pending.completeError(failure);
    }
  }
}
