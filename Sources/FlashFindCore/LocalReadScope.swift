import Foundation

/// 本机来源的**读范围**判定（1.1.2 build 29 补）。
///
/// ## 为什么需要单独一个类型
///
/// 搜索本来就按 `LocalSearchMode` / `folders` 分流（`LocalSearchProvider.search`），
/// 但 `get_metadata` 走的是**另一条链**：
///
/// ```text
/// MetadataExecutor.run → snapshot.execution(for:) → PathMetadataProviding.metadata
/// ```
///
/// 那条链在 build 28 之前只判「这个来源有没有被授权」，**不判「这个路径还在不在
/// 当前范围里」**。于是出现这样一个缺口：
///
/// ```text
/// ① 用户用「整台 Mac」搜到 /Users/me/客户资料/合同.pdf → AI 拿到 file_id
/// ② 用户把范围收窄成「只搜索 /Users/me/工作」
/// ③ AI 拿旧 file_id 调 get_metadata → 照样问出名字、大小、修改时间
/// ```
///
/// NAS 侧没这个缺口：它的每次调用都要过 Dart 的 `scope.check`。本机缺的正是
/// 同一道闸门，补在这里。
///
/// ## 为什么返回 `false` 而不是抛错误
///
/// 「范围外」对外必须长得和「文件不在了」一模一样。给出一个独立的错误码，
/// 等于告诉调用方「这个路径存在，只是你不该看」——那本身就是信息泄露。
public enum LocalReadScope {

    /// 当前配置下，这个绝对路径能不能读。
    ///
    /// - Parameters:
    ///   - absolutePath: 以 `/` 起的绝对路径。
    ///   - mode: 当前本机搜索方式。`.spotlight` = 整台 Mac，范围不设限。
    ///   - folders: 用户勾选的文件夹。只在 `.selectedFolders` 下才参与判定。
    public static func allows(absolutePath: String,
                              mode: LocalSearchMode,
                              folders: [URL]) -> Bool {
        // 整台 Mac：用户选的就是「全都在范围内」，不必逐条比对。
        guard mode == .selectedFolders else { return true }

        // ★ 说「只搜指定文件夹」却一个都没选，范围是**空的**，不是「全部」。
        //   反过来的话，用户清空列表那一刻就等于把范围放大成全盘。
        guard !folders.isEmpty else { return false }

        let target = canonical(absolutePath)
        return folders.contains { folder in
            let root = canonical(folder.path)
            // ★ 必须带分隔符比：只写 `hasPrefix(root)` 的话，选中的
            //   `/Users/me/工作` 会把 `/Users/me/工作备份` 也放进来。
            //   这是路径判定最常见的一种「看起来对」的错法。
            if target == root { return true }
            return target.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
    }

    /// 规范化：消掉 `..` 与重复斜杠，并把符号链接解开。
    ///
    /// ★ 解符号链接是**安全要求**，不是洁癖：选中的文件夹里放一个指向
    ///   `/etc` 的软链，只比字符串前缀就会把范围外的东西当成范围内的。
    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}
