import Foundation
import Security
import CryptoKit

final class TrustHTTP: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    let input: [String: Any]
    var failure: [String: Any]?
    init(_ input: [String: Any]) { self.input = input }
    func certificateInfo(_ certificate: SecCertificate) -> [String: Any] {
        let der = SecCertificateCopyData(certificate) as Data
        let digest = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        let process = Process(), out = Pipe(), err = Pipe(), stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = ["x509", "-inform", "DER", "-noout", "-subject", "-issuer", "-dates", "-text"]
        process.standardInput = stdin; process.standardOutput = out; process.standardError = err
        var text = ""
        do {
            try process.run(); stdin.fileHandleForWriting.write(der); try stdin.fileHandleForWriting.close()
            text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
        } catch { }
        let lines = text.components(separatedBy: .newlines)
        func value(_ prefix: String) -> String {
            lines.first(where: { $0.hasPrefix(prefix) }).map { String($0.dropFirst(prefix.count)) } ?? ""
        }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "MMM d HH:mm:ss yyyy zzz"
        let start = formatter.date(from: value("notBefore=")), end = formatter.date(from: value("notAfter="))
        var san: [String] = []
        if let index = lines.firstIndex(where: { $0.contains("X509v3 Subject Alternative Name:") }), index + 1 < lines.count {
            san = lines[index + 1].trimmingCharacters(in: .whitespaces).components(separatedBy: ", ")
        }
        return ["der": der.base64EncodedString(), "sha256": digest, "subject": value("subject="),
                "issuer": value("issuer="), "san": san,
                "validFrom": start.map { ISO8601DateFormatter().string(from: $0) } ?? "",
                "validUntil": end.map { ISO8601DateFormatter().string(from: $0) } ?? "",
                "expired": end.map { $0 < Date() } ?? true]
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let certificate = chain.first,
              let endpoint = URL(string: input["endpoint"] as? String ?? ""),
              challenge.protectionSpace.host.lowercased() == endpoint.host?.lowercased(),
              challenge.protectionSpace.port == (endpoint.port ?? 443) else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        // Explicit fixture/approved CA affects only this trust object, never system settings.
        if let pem = input["approvedCAPem"] as? String {
            let body = pem.components(separatedBy: .newlines).filter { !$0.hasPrefix("---") }.joined()
            if let data = Data(base64Encoded: body), let anchor = SecCertificateCreateWithData(nil, data as CFData) {
                SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
                SecTrustSetAnchorCertificatesOnly(trust, true)
            } else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        }
        let info = certificateInfo(certificate)
        var error: CFError?
        let systemValid = SecTrustEvaluateWithError(trust, &error)
        let expected = input["sha256"] as? String
        let actual = info["sha256"] as? String
        let expired = info["expired"] as? Bool ?? true
        if let expected = expected {
            if expected == actual && (!expired || input["allowExpired"] as? Bool == true) {
                completionHandler(.useCredential, URLCredential(trust: trust)); return
            }
        } else if systemValid {
            completionHandler(.useCredential, URLCredential(trust: trust)); return
        }
        var reasons: [String] = []
        if expected != nil && expected != actual { reasons.append("Certificate fingerprint changed") }
        if expired { reasons.append("Certificate expired") }
        let host = endpoint.host?.lowercased() ?? ""
        let names = info["san"] as? [String] ?? []
        let nameMatches = names.contains { entry in
            let value = entry.replacingOccurrences(of: "DNS:", with: "").replacingOccurrences(of: "IP Address:", with: "").lowercased()
            return value == host || (value.hasPrefix("*.") && host.components(separatedBy: ".").count == value.components(separatedBy: ".").count && host.hasSuffix(String(value.dropFirst())))
        }
        if !nameMatches { reasons.append("Host does not match certificate SAN") }
        if let error = error { reasons.append(CFErrorCopyDescription(error) as String) }
        failure = ["state": "certificateTrustRequired", "certificate": info, "failureReasons": reasons]
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
    /// 响应体开头像不像 HTML/XML 文档。
    ///
    /// 只回答一个是非题，**绝不把响应内容带出去** —— 反向代理错误页、
    /// 登录门户跳转页、网关超时页都会在这里露头，而它们与「设备本身出问题」
    /// 是完全不同的处置方式：前者要用户去查代理/门户，后者要查设备。
    static func looksLikeHTML(_ data: Data) -> Bool {
        guard let text = String(data: data.prefix(64), encoding: .utf8) else { return false }
        return text.drop(while: { $0.isWhitespace }).hasPrefix("<")
    }

    func execute() -> [String: Any] {
        guard let endpoint = URL(string: input["endpoint"] as? String ?? ""), endpoint.scheme == "https",
              endpoint.user == nil, endpoint.password == nil,
              let path = input["path"] as? String, path.hasPrefix("/webapi/"),
              let url = URL(string: path, relativeTo: endpoint)?.absoluteURL,
              url.host == endpoint.host, url.port == endpoint.port else { return ["state": "UnsafeEndpoint"] }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        let ms = input["requestTimeoutMs"] as? Int ?? 30000
        // 超时值与响应体判定分开报：它们是完全不同的原因，压成同一个
        // ProtocolViolation 后，诊断里就只剩一句「响应不符合预期」。
        guard (1000...120000).contains(ms) else { return ["state": "InvalidTimeout", "ms": ms] }
        let seconds=Double(ms)/1000
        config.timeoutIntervalForRequest = seconds; config.timeoutIntervalForResource = seconds
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        var request = URLRequest(url: url); request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        // This device rejects a body-carried SynoToken with code 119; CSRF must be a header.
        if let token = input["synoToken"] as? String, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Syno-Token")
        }
        request.httpBody = (input["body"] as? String ?? "").data(using: .utf8)
        let done = DispatchSemaphore(value: 0)
        var result: [String: Any] = ["state": "NetworkFailure"]
        let task = session.dataTask(with: request) { data, response, _ in
            defer { done.signal() }
            if let failure = self.failure { result = failure; return }
            guard let response = response as? HTTPURLResponse else { return }
            guard response.statusCode == 200 else { result = ["state": "HttpFailure", "httpStatus": response.statusCode]; return }
            // ──────────────────────────────────────────────────────────────
            // 响应体可用性判定。
            //
            // 这里原来是一句：
            //     guard let data = data, data.count <= 262144,
            //           let object = try? JSONSerialization... else { ProtocolViolation }
            // 它把**三种完全不同的情况**压成同一个 ProtocolViolation：
            //   · 响应体是空的
            //   · 响应体超过 262144 字节（256 KB —— 一个没有任何依据的魔数）
            //   · 响应体不是 JSON 对象
            // 后果是界面上只有一句「设备返回的内容不符合预期」，排查时
            // 无法区分「代理挡了」「被截断了」「设备真的坏了」。
            // 群晖源（demo-nas.example:5003）就在
            // 就绪轮询那一次请求上死在这里，而同一台设备的登录、列共享都正常。
            // 现在每种情况各自上报，并带上字节数 —— 内容一律不外传。
            // ──────────────────────────────────────────────────────────────
            guard let data = data else { result = ["state": "EmptyBody", "bytes": 0]; return }
            if data.isEmpty { result = ["state": "EmptyBody", "bytes": 0]; return }
            // 这个上限只用来防「内存无界增长」，不是业务判据：一次分页最多 200 行，
            // 16 MB 已是它的几十倍。旧值 256 KB 连「几百条结果的一页」都容不下。
            let maxBodyBytes = 16 * 1024 * 1024
            if data.count > maxBodyBytes {
                result = ["state": "BodyTooLarge", "bytes": data.count, "limit": maxBodyBytes]; return
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                result = ["state": "NonJSONBody", "bytes": data.count, "looksLikeHTML": TrustHTTP.looksLikeHTML(data)]; return
            }
            result = ["state": "response", "body": object]
        }
        task.resume()
        if done.wait(timeout: .now() + seconds + 2) == .timedOut { task.cancel(); result = ["state": "TimedOut"] }
        session.invalidateAndCancel(); return result
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

let raw = FileHandle.standardInput.readDataToEndOfFile()
if raw.count <= 65536, let input = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] {
    let result = TrustHTTP(input).execute()
    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
        FileHandle.standardOutput.write(data)
    }
}
