// Adapted MyNAS synology_api.dart:1032-1085, MIT.
//
// 字段策略（2026-10-10 修订，依据 review 结论）：
//   * `path` 是**必需**的 —— 没有路径就无法标识这一条结果，缺了就报错，
//     由 Page.parse 跳过该行并计数（见 synology_api.dart 的 Page.parse）。
//   * `name` **可以缺失**：上游注释写明「name 可能为 null（当文件不存在时），
//     从 path 中提取」。旧实现用 requireString 取 name —— 它在 name 缺失时
//     **先抛异常**，于是紧跟其后那段「从 path 提取」的兜底成了永不执行的死代码。
//     这里按上游原意恢复。
//   * `size` / `crtime` / `mtime` 是设备**可以不给、也可能给哨兵值**的字段：
//     类型不符或为负一律记作「未知」(null)，**不让这一行、更不让整次搜索失败**。
//   * `isdir` 保持必需：它决定这一条是文件还是目录，猜错会给用户错误的行为提示。
//     缺失时同样由 Page.parse 跳过并计数，最终如实上报，不静默丢行。
import 'protocol.dart';

class FileStationFile {
  const FileStationFile({
    required this.name,
    required this.path,
    required this.isDir,
    this.size,
    this.createTime,
    this.modifyTime,
    this.type,
  });

  factory FileStationFile.fromJson(Map<String, dynamic> json) {
    // 容器字段先做类型判断再取用：直接 `as Map<String,dynamic>?` 遇到列表
    // 会抛 TypeError，那属于「这一行不能解析」，不该伪装成别的错误。
    final rawAdditional = json['additional'];
    final additional = rawAdditional is Map ? rawAdditional : const <String, dynamic>{};
    final rawTime = additional['time'];
    final time = rawTime is Map ? rawTime : const <String, dynamic>{};

    final rawPath = json['path'];
    if (rawPath is! String || rawPath.isEmpty) {
      throw const FormatException('缺少 path');
    }
    final path = rawPath;

    // name 缺失/为空时从 path 取末段 —— 这是上游本来就有的兜底，不是新增行为。
    final rawName = json['name'];
    var name = rawName is String ? rawName : '';
    if (name.isEmpty) {
      final lastSlash = path.lastIndexOf('/');
      name = lastSlash >= 0 ? path.substring(lastSlash + 1) : path;
    }
    if (name.isEmpty) throw const FormatException('缺少 name 且无法从 path 推导');

    final rawIsDir = json['isdir'];
    if (rawIsDir is! bool) throw const FormatException('缺少 isdir');

    return FileStationFile(
      name: name,
      path: path,
      isDir: rawIsDir,
      // 未知一律留空，**不用 0 冒充**。
      size: lenientNonnegativeInt(additional, 'size'),
      createTime: _time(time['crtime']),
      modifyTime: _time(time['mtime']),
      type: additional['type'] is String ? additional['type'] as String : null,
    );
  }

  /// 设备时间戳（秒）→ UTC DateTime；缺失或形态异常记作「未知」。
  static DateTime? _time(Object? value) {
    if (value is! int || value < 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(value * 1000, isUtc: true);
  }

  final String name;
  final String path;
  final bool isDir;
  final int? size;
  final DateTime? createTime;
  final DateTime? modifyTime;
  final String? type;
}
