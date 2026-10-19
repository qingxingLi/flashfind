// 移植自上游 `lib/nas_adapters/base/dio_file_stream.dart`（固定上游 2b1458e2）。
//
// 保留的契约：不少 NAS 在会话失效时会**用 HTTP 200 返回一张 HTML/JSON 登录页**。
// 这种响应一旦被当作文件字节交给解码器，用户看到的是「打开成功但内容乱码」，
// 比直接报错难查得多。所以这里在流的第一块里就嗅探错误载荷并中断。
//
// 与上游的差异：
//   - `StateError` → `AdapterFailure`（带机器可判别 kind，能被 harness 翻成线上错误）
//   - `Headers` 来自本项目的 dio 兼容层，而非 dio 本身
//   - 不在本层注入 `onSessionInvalid` 之外的行为；Range 语义逐字保留
import 'dart:convert';

import 'adapter_support.dart';
import 'error_kinds.dart';
import 'dio_compat.dart';
import 'upstream_file_types.dart' show FileRange;

/// 打开一个二进制响应流，并执行 NAS 适配器共用的流式契约。
Future<Stream<List<int>>> openDioFileStream(
  Dio dio,
  String url, {
  FileRange? range,
  void Function()? onSessionInvalid,
}) async {
  final headers = <String, dynamic>{};
  if (range != null) {
    // HTTP Range 的 end 是**闭区间**，而 FileRange.end 是开区间。
    final end = range.end == null ? '' : '${range.end! - 1}';
    headers['Range'] = 'bytes=${range.start}-$end';
  }

  final response = await dio.get<ResponseBody>(
    url,
    options: Options(
      responseType: ResponseType.stream,
      headers: headers,
      validateStatus: (status) => status != null && status < 600,
    ),
  );

  final status = response.statusCode ?? 0;
  if (status == 401 || status == 403) {
    onSessionInvalid?.call();
    throw AdapterFailure(ErrorKind.sessionExpired, '文件会话已失效（HTTP $status）');
  }
  if (status < 200 || status >= 300) {
    throw AdapterFailure(ErrorKind.httpFailure, '文件流请求失败（HTTP $status）');
  }

  final body = response.data;
  if (body == null || status == 204) {
    throw const AdapterFailure(ErrorKind.httpFailure, '文件流响应为空');
  }

  final contentType = response.headers
      .value(Headers.contentTypeHeader)
      ?.toLowerCase();
  final expectedDocument = _isExpectedDocumentResponse(
    url,
    contentType,
    response.headers,
  );
  if (_isErrorContentType(contentType) && !expectedDocument) {
    onSessionInvalid?.call();
    throw AdapterFailure(ErrorKind.sessionExpired, '服务器返回了错误页面（$contentType）');
  }

  var skipBytes = 0;
  int? takeBytes;
  if (range != null) {
    if (status == 206) {
      final contentRange = response.headers.value('content-range');
      if (contentRange == null ||
          !contentRange.toLowerCase().startsWith('bytes ${range.start}-')) {
        throw const AdapterFailure(ErrorKind.httpFailure, '服务器返回了无效的 Content-Range');
      }
    } else if (status == 200) {
      // 相当多 NAS 固件直接忽略 Range。为了不让调用方拿到错位的数据，
      // 这里本地切片，而不是装作支持。
      skipBytes = range.start;
    }
    if (range.end != null) takeBytes = range.end! - range.start;
  }

  return _validateAndSlice(
    body.stream,
    skipBytes: skipBytes,
    takeBytes: takeBytes,
    inspectErrorPayload: !expectedDocument,
    onErrorPayload: onSessionInvalid,
  );
}

bool _isErrorContentType(String? contentType) {
  if (contentType == null) return false;
  return contentType.contains('application/json') ||
      contentType.contains('text/html') ||
      contentType.contains('application/problem+json');
}

bool _isExpectedDocumentResponse(
  String url,
  String? contentType,
  Headers headers,
) {
  final disposition = headers.value('content-disposition')?.toLowerCase();
  if (disposition?.contains('attachment') ?? false) return true;
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  final candidates = <String>[
    uri.path.toLowerCase(),
    ...uri.queryParameters.values.map((value) => value.toLowerCase()),
  ];
  if (contentType?.contains('json') ?? false) {
    return candidates.any((value) => value.endsWith('.json'));
  }
  if (contentType?.contains('html') ?? false) {
    return candidates.any(
      (value) => value.endsWith('.html') || value.endsWith('.htm'),
    );
  }
  return false;
}

Stream<List<int>> _validateAndSlice(
  Stream<List<int>> input, {
  required int skipBytes,
  required int? takeBytes,
  required bool inspectErrorPayload,
  void Function()? onErrorPayload,
}) async* {
  var remainingSkip = skipBytes;
  var remainingTake = takeBytes;
  var inspected = false;

  await for (var chunk in input) {
    if (inspectErrorPayload && !inspected && chunk.isNotEmpty) {
      inspected = true;
      final prefix = utf8.decode(
        chunk.take(512).toList(growable: false),
        allowMalformed: true,
      );
      if (_looksLikeErrorPayload(prefix)) {
        onErrorPayload?.call();
        throw const AdapterFailure(
          ErrorKind.sessionExpired,
          '服务器返回了登录页或 API 错误，而不是文件内容',
        );
      }
    }

    if (remainingSkip >= chunk.length) {
      remainingSkip -= chunk.length;
      continue;
    }
    if (remainingSkip > 0) {
      chunk = chunk.sublist(remainingSkip);
      remainingSkip = 0;
    }
    if (remainingTake != null) {
      if (remainingTake <= 0) break;
      if (chunk.length > remainingTake) {
        yield chunk.sublist(0, remainingTake);
        break;
      }
      remainingTake -= chunk.length;
    }
    if (chunk.isNotEmpty) yield chunk;
  }

  if (remainingSkip > 0) {
    throw const AdapterFailure(ErrorKind.httpFailure, '服务器返回的文件短于请求的 Range 起点');
  }
}

bool _looksLikeErrorPayload(String prefix) {
  final value = prefix.trimLeft().toLowerCase();
  if (value.startsWith('<!doctype html') || value.startsWith('<html')) {
    return true;
  }
  if (!value.startsWith('{')) return false;
  return value.contains('"error"') ||
      value.contains('"message"') ||
      value.contains('"msg"') ||
      value.contains('"code"') ||
      value.contains('"success"');
}
