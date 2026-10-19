import Foundation

/// 一次输入解析出的「关键词 + 格式」。
///
/// 为什么要有这一层：用户搜的是 `测试报告 ppt`，而设备侧（DSM 的
/// `SYNO.FileStation.Search`）与本地侧需要的是**两样分开的东西** ——
/// 名字关键词走 `pattern`，格式走 `extension`。把整串原样丢给设备，
/// 等于让它去找名字里同时含「测试报告」和「ppt」的文件，结果几乎必然为空。
///
/// 这里只做**纯函数解析**，不碰网络、不碰界面，因此可以被测试直接断言。
public struct ParsedSearchQuery: Equatable {
    /// 原始输入，原样保留（诊断与回填输入框用）。
    public let raw: String
    /// 剥离格式词之后剩下的关键词（保序、不去重）。
    public let terms: [String]
    /// 解析出的扩展名（小写、无前导点、去重保序）。
    public let extensions: [String]

    /// 交给设备/本地索引的名字关键词。
    public var keywords: String { terms.joined(separator: " ") }
    public var hasFormatFilter: Bool { !extensions.isEmpty }
    /// 既没关键词也没格式 ⇒ 不该发起搜索。
    public var isEmpty: Bool { terms.isEmpty && extensions.isEmpty }

    public init(raw: String, terms: [String], extensions: [String]) {
        self.raw = raw
        self.terms = terms
        self.extensions = extensions
    }

    /// 没有格式限制的查询（普通关键词搜索）。
    public static func plain(_ text: String) -> ParsedSearchQuery {
        let terms = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return ParsedSearchQuery(raw: text, terms: terms, extensions: [])
    }

    /// 文件名里的扩展名（小写、无点；没有则为空串）。
    ///
    /// 点开头的文件名（`.gitignore`）**不算**有扩展名：它的点后面是名字的一部分，
    /// 按扩展名处理会把 `.gitignore` 当成 `gitignore` 格式的文件。
    public static func extensionOf(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot > name.startIndex else { return "" }
        let ext = name[name.index(after: dot)...]
        guard !ext.isEmpty else { return "" }
        return ext.lowercased()
    }

    /// 这条结果是否符合本次的格式限制。
    ///
    /// 没有格式限制时一律放行（普通搜索不受影响）。
    public func matches(_ name: String) -> Bool {
        guard hasFormatFilter else { return true }
        return extensions.contains(Self.extensionOf(name))
    }
}

/// 格式词表：什么样的输入算「格式」而不是文件名的一部分。
///
/// ★ 判定口径由用户拍板：
///   1. 只认**内置白名单**里的词（任意字母串都当格式会误吃掉 `iso`、`cad`
///      这类既是缩写又是扩展名的词，以及英文缩写型文件名）；
///   2. 同族连带：`ppt` 同时命中 `.ppt` 与 `.pptx`（`doc`/`xls` 同理）；
///   3. 支持中文类别词：`文档` / `图片` / `表格` / `视频` / `压缩包` 等
///      一次筛一整类。
public enum FileFormatVocabulary {

    /// 单独扩展名 → 同族连带列表。
    ///
    /// 连带是**用户明确要求**的：只记得「是 PPT」的人不该因为
    /// 少打一个 x 就搜不到。反过来，不带 x 的旧格式也必须留在结果里。
    public static let families: [String: [String]] = [
        "ppt": ["ppt", "pptx"],
        "pps": ["pps", "ppsx"],
        "doc": ["doc", "docx"],
        "xls": ["xls", "xlsx"],
        "jpg": ["jpg", "jpeg"],
        "tif": ["tif", "tiff"],
        "heic": ["heic", "heif"],
        "mpg": ["mpg", "mpeg"],
        "yml": ["yml", "yaml"],
        "htm": ["htm", "html"],
    ]

    /// 白名单里不连带、单独成条的扩展名。
    public static let singles: Set<String> = [
        "pdf", "txt", "md", "rtf", "pages", "numbers", "key", "csv", "wps", "odt",
        "pptx", "ppsx", "docx", "xlsx", "jpeg", "tiff", "heif", "mpeg", "yaml", "html",
        "png", "gif", "bmp", "webp", "svg", "psd", "ai", "eps", "ico",
        "mp4", "mov", "avi", "mkv", "flv", "wmv", "rmvb", "m4v", "ts",
        "mp3", "wav", "flac", "aac", "m4a", "ogg", "wma",
        "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "iso", "dmg", "pkg",
        "dwg", "dxf", "step", "igs", "stl",
        "epub", "mobi", "xmind", "vsdx",
        "json", "xml", "sql", "log", "ini", "cfg",
        "py", "js", "ts", "go", "rs", "java", "sh", "css", "swift",
    ]

    /// 类别词 → 整类扩展名。键一律小写比较。
    ///
    /// ⚠️ `zip` 刻意**不做**类别词：它本身就是一个具体扩展名，
    /// 当类别词会让「压缩包」与「zip」两种意图混在一起。
    public static let categories: [String: [String]] = [
        // 文档
        // ⚠️ 「文件」刻意**不在**这里：它不是一类格式，而是「所有东西」。
        // 放进来的话，搜「文件管理」会只剩文档类，等于凭空砍掉大部分结果。
        "文档": ["doc", "docx", "pdf", "txt", "md", "rtf", "pages", "wps", "odt", "epub"],
        "documents": ["doc", "docx", "pdf", "txt", "md", "rtf", "pages", "wps", "odt"],
        "document": ["doc", "docx", "pdf", "txt", "md", "rtf", "pages", "wps", "odt"],
        // 表格
        "表格": ["xls", "xlsx", "csv", "numbers", "ods"],
        "sheet": ["xls", "xlsx", "csv", "numbers", "ods"],
        "excel": ["xls", "xlsx", "csv", "numbers", "ods"],
        // 演示（用户未点名，与「文档/表格」同批补齐，待确认）
        "演示": ["ppt", "pptx", "pps", "ppsx", "key"],
        "ppt文档": ["ppt", "pptx", "pps", "ppsx", "key"],
        "slide": ["ppt", "pptx", "pps", "ppsx", "key"],
        // 图片
        "图片": ["jpg", "jpeg", "png", "gif", "bmp", "webp", "heic", "heif", "tif", "tiff", "svg", "psd"],
        "照片": ["jpg", "jpeg", "png", "gif", "bmp", "webp", "heic", "heif", "tif", "tiff"],
        "image": ["jpg", "jpeg", "png", "gif", "bmp", "webp", "heic", "heif", "tif", "tiff", "svg", "psd"],
        // 视频
        "视频": ["mp4", "mov", "avi", "mkv", "flv", "wmv", "rmvb", "m4v", "mpg", "mpeg"],
        "video": ["mp4", "mov", "avi", "mkv", "flv", "wmv", "rmvb", "m4v", "mpg", "mpeg"],
        // 音频（用户未点名，同批补齐，待确认）
        "音频": ["mp3", "wav", "flac", "aac", "m4a", "ogg", "wma"],
        "音乐": ["mp3", "wav", "flac", "aac", "m4a", "ogg", "wma"],
        "audio": ["mp3", "wav", "flac", "aac", "m4a", "ogg", "wma"],
        // 压缩包
        "压缩包": ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz"],
        "压缩": ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz"],
        "archive": ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz"],
    ]

    /// 所有已知扩展名（连带族的两侧 + 单条）。用于白名单判定。
    public static var knownExtensions: Set<String> {
        var out = singles
        for (key, values) in families { out.insert(key); out.formUnion(values) }
        for values in categories.values { out.formUnion(values) }
        return out
    }

    /// 把一个格式词翻译成扩展名列表。
    ///
    /// - 命中类别词 ⇒ 整类；命中连带族 ⇒ 同族；命中白名单 ⇒ 自身。
    /// - 都不命中 ⇒ nil（调用方应把原词留作关键词）。
    public static func extensions(for word: String) -> [String]? {
        let key = word.lowercased()
        if let category = categories[key] { return category }
        if let family = families[key] { return family }
        if knownExtensions.contains(key) { return [key] }
        return nil
    }
}

/// 查询串解析器：把用户的整串输入拆成「关键词 + 格式」。
///
/// 解析顺序（先具体后宽泛，避免把类别词当扩展名、把带点的文件名当关键词）：
///   1. `ext:ppt` —— 显式前缀，永远按格式处理；
///   2. 中文/英文类别词 —— `文档`、`图片`、`video`；
///   3. 白名单里的裸格式词 —— `ppt`、`pdf`、`xlsx`；
///   4. 带点的写法 `测试报告.ppt` —— 1 代的语法，点后面是字母开头才认
///      （`2026.10` 这种纯数字后缀必须留在关键词里，否则日期被吃掉）；
///   5. 其余 —— 关键词。
public enum SearchQueryParser {

    /// 显式格式前缀。1 代没有，这里作为「不确定这词会不会被当格式」时的兜底写法。
    public static let explicitPrefixes = ["ext:", "格式:", "type:"]

    public static func parse(_ raw: String) -> ParsedSearchQuery {
        var terms: [String] = []
        var extensions: [String] = []

        let tokens = raw.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        for token in tokens {
            if let explicit = explicitWord(token) {
                // 显式前缀同样走词汇表：写 `ext:ppt` 的人多半也想要 pptx。
                append(FileFormatVocabulary.extensions(for: explicit) ?? [explicit], to: &extensions)
                continue
            }
            let lower = token.lowercased()
            if let hit = FileFormatVocabulary.extensions(for: lower) {
                append(hit, to: &extensions)
                continue
            }
            if let pair = splitDotted(token), !pair.ext.isEmpty {
                if !pair.keyword.isEmpty { terms.append(pair.keyword) }
                // 带点的写法是**显式意图**，即使不在白名单也按格式处理；
                // 但同族连带只在白名单命中时才展开（`报告.foo` 不该变成 `foo/foox`）。
                append(FileFormatVocabulary.extensions(for: pair.ext) ?? [pair.ext], to: &extensions)
                continue
            }
            terms.append(token)
        }

        return ParsedSearchQuery(raw: raw, terms: terms, extensions: extensions)
    }

    /// 取显式前缀后面的词。没有前缀 ⇒ nil。
    private static func explicitWord(_ token: String) -> String? {
        let lower = token.lowercased()
        for prefix in explicitPrefixes where lower.hasPrefix(prefix) {
            let value = String(token.dropFirst(prefix.count))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// 按**最后一个点**切开（1 代 `SearchModels.splitExtension` 的同款语义）。
    ///
    /// 为什么只看字母开头：`2026.10.15`、`v1.2` 这类后缀是数字，
    /// 被当扩展名会把「10」「2」吃掉，剩下的关键词就变了。
    private static func splitDotted(_ token: String) -> (keyword: String, ext: String)? {
        guard let dot = token.lastIndex(of: "."), dot > token.startIndex else { return nil }
        let ext = String(token[token.index(after: dot)...])
        // ⚠️ 必须限定 ASCII：`CharacterSet.alphanumerics` 把**汉字也算字母**，
        // 用它会把「最终版.修改」切成关键词「最终版」+ 扩展名「修改」。
        guard !ext.isEmpty, ext.count <= 12,
              ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              let first = ext.first, !first.isNumber else { return nil }
        let key = String(token[..<dot])
        return (key == "*" ? "" : key, ext)
    }

    private static func append(_ values: [String], to extensions: inout [String]) {
        for value in values {
            let lowered = value.lowercased()
            if !extensions.contains(lowered) { extensions.append(lowered) }
        }
    }
}
