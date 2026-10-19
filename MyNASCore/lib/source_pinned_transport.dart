// Transport backed by the bundled native HTTPS helper with source-level leaf pinning.
// Certificate prompts surface as typed events, never as raw exceptions or logs.
import 'protocol.dart';
import 'source_trust.dart';

class CertificateTrustError extends CoreError {
  final Map<String, Object?> candidate;
  CertificateTrustError(this.candidate) : super('CertificateTrustRequired');
  @override Map<String, Object?> toJson() => {...super.toJson(), 'candidate': candidate};
  @override String toString() => 'CoreError(CertificateTrustRequired)';
}

class SourcePinnedTransport implements Transport {
  final SourcePinnedClient client;
  SourcePinnedTransport(this.client);
  @override Future<Map<String, dynamic>> send(WireRequest request, Cancellation token) async {
    token.check();
    void Function()? abort;
    try {
      final body = await client.post(request.path, request.fields,
          synoToken: request.fields['SynoToken'], onAbortReady: (kill) {
        abort = () { kill(); token.cancel(); };
        token.listeners.add(abort!);
      });
      token.check();
      return body;
    } on TrustRequired catch (error) {
      throw CertificateTrustError(error.candidate.toJson());
    } on NativeTransportError catch (error) {
      throw CoreError(transportKind(error.kind), api: request.api, method: request.method,
          httpStatus: error.httpStatus, detail: nativeTransportDetail(error));
    } on StateError catch (error) {
      throw CoreError(trustStateKind(error.message), api: request.api, method: request.method,
          detail: 'native:${error.message}');
    } finally {
      if (abort != null) token.listeners.remove(abort);
    }
  }
}

/// 写好诊断用的 `detail`：`native:<助手状态>[:<响应体字节数>]`。
///
/// 字节数只在响应体相关的失败上有值，它把三件此前长得一模一样的事分开：
/// 响应太大、响应不是 JSON、响应是空的。`detail` 只进诊断文件，不给用户看。
String nativeTransportDetail(NativeTransportError error) {
  final bytes = error.bytes;
  return 'native:${error.kind}${bytes == null ? '' : ':$bytes'}';
}

String trustStateKind(Object message) => switch (message) {
  'UnsafeApiPath' => 'UnsafeApiPath', 'UnsafeEndpoint' => 'UnsafeEndpoint',
  'CertificateMetadataMismatch' => 'ProtocolViolation',
  'ExplicitCertificateConfirmationRequired' => 'ExplicitCertificateConfirmationRequired',
  'TrustStorePermissions' || 'TrustDirectoryRequired' || 'UnsafeTrustStore' ||
  'UnsafeTrustDirectory' || 'TrustHelperMissing' || 'TrustHelperNotExecutable' ||
  'TrustHelperOutsideProject' => 'TrustStoreFailure',
  _ => 'NetworkFailure',
};

/// 助手报的失败状态 → 对外错误种类。
///
/// 响应体相关的四种状态全部归到 `ProtocolViolation`：它们的用户处置是同一件事
/// （「设备返回的东西没法当 API 响应解读」），但**诊断必须能区分**，
/// 所以精确状态留在 `detail`（见 [nativeTransportDetail]）。
/// 这里绝不能落到默认分支：默认是 `NetworkFailure`，会把
/// 「代理挡了」说成「网络不通」，指向完全错误的排查方向。
String transportKind(String kind) => switch (kind) {
  'HttpFailure' => 'HttpFailure', 'TimedOut' => 'TimedOut',
  'ProtocolViolation' => 'ProtocolViolation', 'UnsafeEndpoint' => 'UnsafeEndpoint',
  'EmptyBody' || 'BodyTooLarge' || 'NonJSONBody' || 'InvalidTimeout' => 'ProtocolViolation',
  _ => 'NetworkFailure',
};
