import Foundation
import Darwin
import FlashFindCore

@main
struct FlashFindCLI {
    static func main() async {
        do {
            // CLI 与 App 各自装配：没有 AppDelegate，不装就是空的内存后端，
            // `configure` 存完下次运行就读不到了。
            CredentialStore.install(FileSecretStore())
            let args = Array(CommandLine.arguments.dropFirst())
            func value(_ flag: String) -> String? { guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }; return args[index + 1] }
            func passwordInput() throws -> String {
                if args.contains("--password-stdin") {
                    var original = termios()
                    let terminal = isatty(STDIN_FILENO) != 0
                    if terminal {
                        guard tcgetattr(STDIN_FILENO, &original) == 0 else { throw FlashFindError.message("Cannot read terminal settings") }
                        var hidden = original; hidden.c_lflag &= ~tcflag_t(ECHO)
                        guard tcsetattr(STDIN_FILENO, TCSANOW, &hidden) == 0 else { throw FlashFindError.message("Cannot disable password echo") }
                        fputs("NAS password: ", stderr)
                    }
                    defer { if terminal { tcsetattr(STDIN_FILENO, TCSANOW, &original); fputs("\n", stderr) } }
                    guard let password = readLine(), !password.isEmpty else { throw FlashFindError.message("Password required") }
                    return password
                }
                guard let password = ProcessInfo.processInfo.environment["FLASHFIND2_PASSWORD"] else { throw FlashFindError.message("--password-stdin or FLASHFIND2_PASSWORD required") }
                return password
            }
            let defaults = UserDefaults(suiteName: "com.flashfind.v2")!
            let address = value("--server") ?? defaults.string(forKey: "ff2.address") ?? ""
            let username = value("--user") ?? defaults.string(forKey: "ff2.username") ?? ""
            let cacheRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/FlashFind2")
            let root = value("--cache").map { URL(fileURLWithPath: $0) } ?? AccountProfile.directory(root: cacheRoot, address: address, username: username)
            let sync = try SyncCoordinator(directory: root)
            switch args.first {
            case "configure":
                guard let address = value("--server"), let pin = value("--pin"), let password = ProcessInfo.processInfo.environment["FLASHFIND2_PASSWORD"] else { throw FlashFindError.message("server, pin and password required") }
                guard let user = value("--user"), !user.isEmpty else { throw FlashFindError.message("--user NAS_ACCOUNT required") }
                try SecureStorage.save(password, account: CredentialAccount.legacy(address: address, username: user))
                defaults.set(address, forKey: "ff2.address"); defaults.set(user, forKey: "ff2.username")
                defaults.set(pin, forKey: "ff2.pin"); defaults.set(true, forKey: "ff2.enabled")
                defaults.set(true, forKey: "ff2.rememberPassword." + AccountProfile.key(address: address, username: user))
                // 凭据实际存本机文件，不是钥匙串 —— 早期文案写错了，会误导人去钥匙串里找。
                print("Configured; password stored in the local FlashFind2 credential file")
            case "probe", "sync":
                guard let address = value("--server"), let url = URL(string: address) else { throw FlashFindError.message("--server https://host:port required") }
                let settings = ServerSettings(address: url, username: username, certificateSHA256: value("--pin") ?? "")
                if args.first == "probe" { print(try await ServerConnection(settings: settings).probeCertificate()) }
                else {
                    let password = try passwordInput()
                    print(try await sync.sync(settings: settings, password: password))
                }
            case "search":
                guard let query = value("--query") else { throw FlashFindError.message("--query required") }
                for result in try await sync.search(query) { print("\(result.sourceName)\t\(result.relativePath)") }
            case "benchmark":
                let iterations = Int(value("--iterations") ?? "1000") ?? 0
                guard (1...100000).contains(iterations) else { throw FlashFindError.message("--iterations must be between 1 and 100000") }
                let queries = ["报告", "报告 0101", "合同", "备份", "更名后的报告", "quote\"name", "%_", "flashfind2-unlikely-token"]
                let sources = await sync.sources()
                var records = 0
                for source in sources {
                    let url = try await sync.databaseURL(source.id)
                    guard FileManager.default.fileExists(atPath: url.path) else { continue }
                    let db = try IndexDatabase(url: url, create: false)
                    records += try db.count(); db.close()
                }
                func cpuSeconds() -> Double {
                    var usage = rusage()
                    getrusage(RUSAGE_SELF, &usage)
                    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                        + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
                }
                let clock = ContinuousClock()
                func milliseconds(_ duration: Duration) -> Double {
                    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
                }
                // Warm each query before measuring; this is a warm-cache workload, not first import.
                for query in queries { _ = try await sync.search(query) }
                let start = clock.now, initialCPU = cpuSeconds()
                var timings = Array(repeating: [Double](), count: queries.count), hits = Array(repeating: 0, count: queries.count)
                for index in 0..<iterations {
                    let queryIndex = index % queries.count, before = clock.now
                    let found = try await sync.search(queries[queryIndex])
                    timings[queryIndex].append(milliseconds(before.duration(to: clock.now)))
                    hits[queryIndex] = found.count
                }
                let elapsed = milliseconds(start.duration(to: clock.now)) / 1000, cpu = cpuSeconds() - initialCPU
                let rows: [[String: Any]] = queries.indices.compactMap { index in
                    let sorted = timings[index].sorted()
                    guard !sorted.isEmpty else { return nil }
                    func percentile(_ p: Double) -> Double { sorted[max(0, Int(ceil(Double(sorted.count) * p)) - 1)] }
                    return ["query": queries[index], "samples": sorted.count, "last_hits": hits[index],
                            "p50_ms": percentile(0.5), "p95_ms": percentile(0.95), "max_ms": sorted.last!]
                }
                let report: [String: Any] = ["timestamp": ISO8601DateFormatter().string(from: Date()),
                    "scope": "warm NAS metadata cache only; no Spotlight, network sync or SMB scan",
                    "sources": sources.count, "records": records, "iterations": iterations,
                    "wall_seconds": elapsed, "cpu_seconds": cpu, "queries_per_second": Double(iterations) / elapsed,
                    "queries": rows]
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                if let output = value("--output") { try data.write(to: URL(fileURLWithPath: output), options: .atomic) }
                print(String(decoding: data, as: UTF8.self))
            case "sources": for source in await sync.sources() { print("\(source.id)\t\(source.name)\t\(source.smbEndpoint)") }
            default: print("flashfind2 probe|sync --server HTTPS_URL --user USER --pin CERT_SHA256 [--cache DIR]\nflashfind2 search --query TEXT [--cache DIR]\nflashfind2 benchmark [--iterations N] [--output JSON_PATH] [--cache DIR]\nflashfind2 sources [--cache DIR]")
            }
        } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    }
}
