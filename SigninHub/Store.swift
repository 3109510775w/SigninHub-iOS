import Foundation

/// 配置 + 历史 + 凭据存储
enum Store {
    static var config: [String: Any] = [:]
    static var history: [[String: Any]] = []

    static func dir() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    static var configURL: URL { dir().appendingPathComponent("config.json") }
    static var historyURL: URL { dir().appendingPathComponent("history.json") }

    static func boot() {
        loadConfig()
        loadHistory()
    }

    static func loadConfig() {
        if let d = try? Data(contentsOf: configURL),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            config = obj
        } else {
            config = defaultConfig()
            saveConfig()
        }
    }
    static func saveConfig() {
        if let d = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted]) {
            try? d.write(to: configURL, options: .atomic)
        }
    }
    static func loadHistory() {
        if let d = try? Data(contentsOf: historyURL),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] {
            history = obj
        }
    }
    static func saveHistory() {
        if let d = try? JSONSerialization.data(withJSONObject: history) {
            try? d.write(to: historyURL, options: .atomic)
        }
    }

    // MARK: 凭据（Keychain）
    static func cred(_ k: String) -> String { Keychain.get(k) ?? "" }
    static func setCred(_ k: String, _ v: String) {
        if v.isEmpty { Keychain.delete(k) } else { Keychain.set(v, for: k) }
    }

    // MARK: 配置访问
    static func provider(_ key: String) -> [String: Any] {
        (config["providers"] as? [String: Any])?[key] as? [String: Any] ?? [:]
    }
    static func wbBlock() -> [String: Any] {
        provider("workbuddy")["wb"] as? [String: Any] ?? [:]
    }
    static func traeBlock() -> [String: Any] {
        provider("traesolo")["trae"] as? [String: Any] ?? [:]
    }

    static func defaultConfig() -> [String: Any] {
        [
            "scheduler": ["times": ["08:30"], "timezone_offset_hours": 8, "jitter_min": 30, "enabled": true],
            "notify": ["enabled": false, "kind": "bark", "webhook_url": "", "secret": ""],
            "providers": [
                "workbuddy": [
                    "enabled": true, "mode": "wb",
                    "wb": ["region": "cn", "accessToken": "", "refreshToken": "", "uid": "", "uin": "", "enterpriseId": "", "domain": ""]
                ],
                "traesolo": [
                    "enabled": true, "mode": "trae",
                    "trae": ["region": "cn", "host": "", "token": "", "deviceId": "", "session": ""]
                ],
            ],
        ]
    }

    // MARK: 历史记录（今天各 provider 最近一条）
    static func todayRecord(_ key: String, day: String) -> [String: Any]? {
        history.first(where: { ($0["provider"] as? String) == key && ($0["day"] as? String) == day })
    }
    static func recordCheckin(key: String, day: String, outcome: CheckinOutcome, usedPoints: Int = -1) {
        let rec: [String: Any] = [
            "provider": key,
            "day": day,
            "status": outcome.status.rawValue,
            "message": outcome.message,
            "points": outcome.points,
            "total_points": outcome.totalPoints,
            "used_points": usedPoints,
            "streak_days": outcome.streakDays,
            "created_at": Int(Date().timeIntervalSince1970 * 1000),
        ]
        history.removeAll(where: { ($0["provider"] as? String) == key && ($0["day"] as? String) == day })
        history.insert(rec, at: 0)
        saveHistory()
    }

    static func todayStr() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        return f.string(from: Date())
    }
}