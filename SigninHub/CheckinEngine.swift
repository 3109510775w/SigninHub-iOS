import Foundation

/// 可选认证注入：由 tokenKey 派生
struct AuthInjection {
    var header: String
    var value: String
}

struct EngineResponse {
    var success: Bool
    var raw: String
}

enum EngineError: LocalizedError {
    case notConfigured
    case invalidJSON
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "接口未配置（url 为空）"
        case .invalidJSON: return "JSON 解析失败"
        }
    }
}

/// 「接口模式」核心引擎：通用 HTTP 签到 + 成功判定，与安卓 LocalCheckin 同构
enum CheckinEngine {

    static func run(_ cfg: HttpProviderConfig,
                    auth: AuthInjection? = nil,
                    date: Date = Date()) async throws -> EngineResponse {
        guard !cfg.url.isEmpty, let url = URL(string: cfg.url) else {
            throw EngineError.notConfigured
        }

        var request = URLRequest(url: url)
        request.httpMethod = cfg.method.uppercased()
        request.timeoutInterval = 30

        for (k, v) in cfg.headers {
            request.setValue(v, forHTTPHeaderField: k)
        }
        if let auth = auth, !auth.value.isEmpty {
            request.setValue(auth.value, forHTTPHeaderField: auth.header)
        }

        // 替换 {date} 占位
        var body = cfg.body
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let today = df.string(from: date)
        for (k, v) in body where v == "{date}" {
            body[k] = today
        }

        let method = cfg.method.uppercased()
        if method != "GET" && !body.isEmpty {
            if cfg.bodyType == "form" {
                var comps = URLComponents()
                comps.queryItems = body.map { URLQueryItem(name: $0.key, value: $0.value) }
                request.httpBody = comps.query?.data(using: .utf8)
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            } else {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }

        let (data, _) = try await URLSession.shared.data(for: request)
        let raw = String(data: data, encoding: .utf8) ?? ""
        let success = evaluate(raw: raw, expr: cfg.successExpr, value: cfg.successValue)
        return EngineResponse(success: success, raw: raw)
    }

    /// 从返回 JSON 取值判定成功（支持 data.status 点路径）
    static func evaluate(raw: String, expr: String, value: String) -> Bool {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return false }
        guard let dict = obj as? [String: Any] else { return false }
        guard let actual = valueAt(dict: dict, path: expr) else { return false }

        if let s = actual as? String { return s == value }
        if let n = actual as? NSNumber { return n.stringValue == value }
        if let b = actual as? Bool { return String(b) == value }
        return false
    }

    private static func valueAt(dict: [String: Any], path: String) -> Any? {
        var current: Any? = dict
        for part in path.split(separator: ".").map(String.init) {
            if let d = current as? [String: Any] {
                current = d[part]
            } else if let arr = current as? [Any], let idx = Int(part), idx < arr.count {
                current = arr[idx]
            } else {
                return nil
            }
        }
        return current
    }
}

enum Notify {
    /// 通用 webhook 推送（Bark / PushPlus / 钉钉 / 飞书 / 企业微信均可，按 host 自行适配）
    static func send(url: String, text: String) async {
        guard let u = URL(string: url) else { return }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "title": "签到日报",
            "content": text,
            "body": text,
            "msgtype": "text",
            "text": ["content": text]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        _ = try? await URLSession.shared.data(for: req)
    }
}
