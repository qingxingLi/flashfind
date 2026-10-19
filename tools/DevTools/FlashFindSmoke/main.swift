import Foundation
import FlashFindCore

@main
struct FlashFindSmoke {
    static func main() async {
        do { try await run() } catch { fputs("TEST FAILED: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        func value(_ flag: String) throws -> String {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { throw FlashFindError.message("Missing \(flag)") }
            return args[i + 1]
        }
        let mount = URL(fileURLWithPath: try value("--mount"))
        let token = try value("--run")
        try RelativePath.validate(token)
        guard !token.contains("/"), token.hasPrefix("FF2-SMB-") else { throw FlashFindError.message("Use a unique FF2-SMB- run name") }
        let root = mount.appendingPathComponent("测试").appendingPathComponent(token)
        let fm = FileManager.default
        let resume = args.contains("--resume")
        guard fm.fileExists(atPath: mount.appendingPathComponent("测试").path), resume == fm.fileExists(atPath: root.path) else { throw FlashFindError.message("Test parent missing or run already exists; refusing overwrite") }
        if resume {
            let marker = root.appendingPathComponent("打开检查-中文 空格.txt")
            guard try String(contentsOf: marker, encoding: .utf8).contains("SMB open verification") else { throw FlashFindError.message("Resume marker mismatch") }
        }
        let cache = URL(fileURLWithPath: try value("--cache"))
        let coordinator = try SyncCoordinator(directory: cache)
        guard let url = URL(string: try value("--server")), let password = ProcessInfo.processInfo.environment["FLASHFIND2_PASSWORD"] else { throw FlashFindError.message("Server and service password required") }
        let settings = ServerSettings(address: url, username: "nasuser", certificateSHA256: try value("--pin"))
        let sourceID = "fnos-team-test-pilot-20261002"
        var expected: [String: Int64] = [:]
        var directories = Set<String>([token])
        var stages: [[String: Any]] = []
        var reconstructing = true
        func write(_ path: String, _ text: String) throws {
            let data = Data(text.utf8)
            if !resume || !reconstructing { try data.write(to: mount.appendingPathComponent("测试").appendingPathComponent(path)) }
            expected[path] = Int64(data.count)
        }
        if !resume { try fm.createDirectory(at: root, withIntermediateDirectories: false) }
        let creationStart = ProcessInfo.processInfo.systemUptime
        for bucket in 0..<10 {
            let path = "\(token)/组\(String(format: "%02d", bucket))"
            if !resume { try fm.createDirectory(at: mount.appendingPathComponent("测试").appendingPathComponent(path), withIntermediateDirectories: false) }
            directories.insert(path)
            for index in 0..<100 {
                let n = bucket * 100 + index
                let ext = ["txt", "md", "csv", "json", "log"][n % 5]
                let name = "\(path)/报告 \(String(format: "%04d", n)).\(ext)"
                let body = ext == "json" ? "{\"test\":true,\"record\":\(n)}\n" : ext == "csv" ? "record,name\n\(n),FlashFind SMB test\n" : "FlashFind 2 SMB fixture \(n)\n仅用于文件搜索测试。\n"
                try write(name, body)
            }
            print("\(resume ? "Loaded" : "Created") \((bucket + 1) * 100)/1000 fixtures"); fflush(stdout)
        }
        let original = "\(token)/打开检查-中文 空格.txt"
        try write(original, "FlashFind 2 SMB open verification\n中文与空格路径测试。\n")
        try write("\(token)/literal%_name.txt", "Literal percent and underscore\n")
        try write("\(token)/quote\"name.txt", "Quoted filename\n")
        let modified = "\(token)/修改检查.txt"
        try write(modified, "Before modification\n")
        reconstructing = false
        stages.append(["stage": resume ? "resume-fixtures" : "create", "files": expected.count, "seconds": ProcessInfo.processInfo.systemUptime - creationStart])
        func results() async throws -> [SearchResult] {
            try await coordinator.search(token, limit: 5000).filter { $0.sourceID == sourceID }
        }
        func verify(_ stage: String) async throws {
            let start = ProcessInfo.processInfo.systemUptime
            for attempt in 0..<12 {
                try await Task.sleep(nanoseconds: attempt == 0 ? 1_000_000_000 : 8_000_000_000)
                do {
                    _ = try await coordinator.sync(settings: settings, password: password)
                    let actual = try await results()
                    let expectedPaths = Set(expected.keys).union(directories)
                    let actualPaths = Set(actual.map(\.displayPath))
                    let sizesCorrect = actual.filter { $0.kind == "file" }.allSatisfy { expected[$0.displayPath] == $0.size }
                    if actualPaths == expectedPaths && sizesCorrect {
                        stages.append(["stage": stage, "records": actual.count, "seconds": ProcessInfo.processInfo.systemUptime - start])
                        print("PASS \(stage): \(actual.count) records; \(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - start))s"); fflush(stdout)
                        return
                    }
                    print("Waiting \(stage): \(actual.count)/\(expectedPaths.count)"); fflush(stdout)
                } catch {
                    if attempt == 11 { throw error }
                    print("Retry \(stage): \(error.localizedDescription)"); fflush(stdout)
                }
            }
            throw FlashFindError.message("Index did not converge for \(stage)")
        }
        try await verify("initial-SMB-create")
        guard let source = await coordinator.sources().first(where: { $0.id == sourceID }) else { throw FlashFindError.message("Test source missing") }
        let binding = MountBinding(root: mount, bookmark: try mount.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
        let opened = try binding.resolve(source: source, relativePath: original)
        guard opened.path == root.appendingPathComponent("打开检查-中文 空格.txt").path,
              try String(contentsOf: opened, encoding: .utf8).contains("SMB open verification") else { throw FlashFindError.message("SMB path or file content mismatch") }
        stages.append(["stage": "SMB-path-and-content", "path": opened.path])
        for query in ["打开检查", "报告", "literal%_name", "quote\"name"] {
            guard try await coordinator.search(query, limit: 5000).contains(where: { $0.sourceID == sourceID }) else { throw FlashFindError.message("Query failed: \(query)") }
        }
        print("PASS path mapping, SMB read, Chinese short term and literal queries"); fflush(stdout)
        guard let quote = try await results().first(where: { $0.displayPath == "\(token)/quote\"name.txt" }),
              try String(contentsOf: binding.resolve(source: source, relativePath: quote.relativePath), encoding: .utf8) == "Quoted filename\n" else { throw FlashFindError.message("SMB SFM wire path read failed") }
        stages.append(["stage": "SFM-display-search-and-wire-path-read", "status": "pass"])
        let renamed = "\(token)/更名后的报告.txt"
        try fm.moveItem(at: opened, to: try binding.resolve(source: source, relativePath: renamed))
        expected[renamed] = expected.removeValue(forKey: original)
        try await verify("file-rename")
        let oldDir = "\(token)/组00", newDir = "\(token)/组00-更名"
        try fm.moveItem(at: try binding.resolve(source: source, relativePath: oldDir), to: try binding.resolve(source: source, relativePath: newDir))
        for path in Array(expected.keys) where path.hasPrefix(oldDir + "/") {
            expected[newDir + path.dropFirst(oldDir.count)] = expected.removeValue(forKey: path)
        }
        directories.remove(oldDir); directories.insert(newDir)
        try await verify("directory-rename-100-files")
        try write(modified, String(repeating: "SMB modification verification\n", count: 100))
        try await verify("size-update")
        let deleted = "\(token)/组01/报告 0100.txt"
        try fm.removeItem(at: try binding.resolve(source: source, relativePath: deleted)); expected.removeValue(forKey: deleted)
        try await verify("file-delete")
        let deletedDir = "\(token)/组09"
        try fm.removeItem(at: try binding.resolve(source: source, relativePath: deletedDir))
        expected = expected.filter { !$0.key.hasPrefix(deletedDir + "/") }; directories.remove(deletedDir)
        try await verify("directory-delete-100-files")
        let defaults = UserDefaults(suiteName: "com.flashfind.v2")!
        var bindings = defaults.data(forKey: "ff2.bindings").flatMap { try? JSONDecoder().decode([String: MountBinding].self, from: $0) } ?? [:]
        bindings[sourceID] = binding
        defaults.set(try JSONEncoder().encode(bindings), forKey: "ff2.bindings")
        let report: [String: Any] = ["run": token, "source_id": sourceID, "mount": mount.path, "test_directory": root.path,
                                    "remaining_files": expected.count, "remaining_records": expected.count + directories.count,
                                    "open_sample": try binding.resolve(source: source, relativePath: renamed).path, "stages": stages]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: try value("--report")), options: .atomic)
        print("ALL PASS; retained \(expected.count) readable test files in \(root.path)")
    }
}
