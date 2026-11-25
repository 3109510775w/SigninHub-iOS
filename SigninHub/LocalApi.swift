import Foundation

/// 本地 `/api/*` 路由：把原版网页 UI 的请求接到 Swift 签到引擎，返回与 server.py 一致的 JSON
enum LocalApi {

    // MARK: - JSON 工具

    static func jsonString(_ obj: Any) -> String {
        let safe = sanitizeForJSON(obj)
        guard JSONSerialization.isValidJSONObject(safe),
              let d = try? JSONSerialization.data(withJSONObject: safe) else {
            return "{\"error\":\"bad json\"}"
        }
        return String(data: d, encoding: .utf8) ?? "{}"
    }

    /// 递归净化：把所有非 JSON 安全值（NaN/inf/装箱 optional/未知类型）转成安全值，
    /// 保证 NSJSONSerialization 永不抛 ObjC 异常。
    static func sanitizeForJSON(_ v: Any) -> Any {
        if let d = v as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, val) in d { out[k] = sanitizeForJSON(val) }
            return out
        }
        if let a = v as? [Any] {
            return a.map { sanitizeForJSON($0) }
        }
        if let n = v as? NSNumber {
            if CFGetTypeID(n as CFTypeRef) == CFBooleanGetTypeID() { return n.boolValue }
            let dbl = n.doubleValue
            if dbl.isNaN || dbl.isInfinite { return 0 }
            return n
        }
        if let s = v as? String { return s }
        if let b = v as? Bool { return b }
        if v is NSNull { return NSNull() }
        // 兜底：任何不可序列化类型 → 字符串
        return String(describing: v)
    }

    static func splitQuery(_ path: String) -> (String, [String: String]) {
        let comps = path.split(separator: "?", maxSplits: 1).map(String.init)
        let p = comps.first ?? path
        var q: [String: String] = [:]
        if comps.count > 1 {
            for pair in comps[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 { q[kv[0]] = kv[1].removingPercentEncoding ?? kv[1] }
                else if kv.count == 1 { q[kv[0]] = "" }
            }
        }
        return (p, q)
    }

    static func parseBody(_ body: String) -> [String: Any] {
        guard let d = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    // MARK: - 凭据

    static func wbCredential() -> WBCredential {
        let wb = Store.wbBlock()
        return WBCredential(
            accessToken: Store.cred("wbAccessToken"),
            refreshToken: Store.cred("wbRefreshToken"),
            uid: Store.cred("wbUid"),
            uin: Store.cred("wbUin"),
            enterpriseId: Store.cred("wbEnterpriseId"),
            domain: Store.cred("wbDomain"),
            region: (wb["region"] as? String) ?? "cn"
        )
    }

    static func traeCredential() -> TraeCredential {
        let tr = Store.traeBlock()
        return TraeCredential(
            token: Store.cred("traeToken"),
            session: Store.cred("traeSession"),
            deviceId: (tr["deviceId"] as? String) ?? "",
            region: (tr["region"] as? String) ?? "cn",
            host: (tr["host"] as? String) ?? ""
        )
    }

    static func readiness(_ key: String) -> Bool {
        switch key {
        case "workbuddy": return !Store.cred("wbAccessToken").isEmpty
        case "traesolo": return !Store.cred("traeToken").isEmpty || !Store.cred("traeSession").isEmpty
        default: return false
        }
    }

    // MARK: - 主入口

    /// 无网络、可直接同步返回的接口；返回 nil 表示需要走异步（handleAsync）
    static func handleSync(_ p: String, _ q: [String: String], method: String, body: String) -> String? {
        switch p {
        case "/api/ping":
            return jsonString(["ok": true, "version": "2.25.0", "appVersion": "2.25.0", "local": true] as [String: Any])
        case "/api/status":
            return jsonString(status())
        case "/api/logs":
            return jsonString(["logs": logs(q)])
        case "/api/config":
            if method == "POST" {
                mergeConfig(parseBody(body))
                return jsonString(["ok": true])
            }
            return jsonString(maskedConfig())
        case "/api/reset_creds":
            resetCreds(parseBody(body))
            return jsonString(["ok": true])
        case "/api/growth", "/api/growth/room", "/api/growth/claim", "/api/growth/daily", "/api/growth/daily/run":
            return jsonString(["ok": false, "error": "iOS 版暂未移植成长中心", "results": [Any]()] as [String: Any])
        case "/api/heat":
            return jsonString(["ok": true, "cells": [Any](), "today": [String: Any](), "summary": ""] as [String: Any])
        case "/api/stats":
            return jsonString(["ok": true] as [String: Any])
        case "/api/auto_status":
            return jsonString(["ok": false, "running": false, "last_run": "", "diagnostics": [Any]()] as [String: Any])
        default:
            // 异步路径（真实网络请求）
            if p == "/api/checkin/all" || p == "/api/wb_assets" || p == "/api/refresh_totals" || p == "/api/test_notify"
                || p.hasPrefix("/api/checkin/") || p.hasPrefix("/api/test/") {
                return nil
            }
            return jsonString(["error": "unknown path \(p)"])
        }
    }

    static func handleAsync(_ p: String, _ q: [String: String]) async -> String {
        switch p {
        case "/api/checkin/all":
            return jsonString(await runAll())
        case "/api/wb_assets":
            return jsonString(await wbAssets())
        case "/api/refresh_totals":
            return jsonString(["ok": true, "totals": await totals()])
        case "/api/test_notify":
            return jsonString(await testNotify())
        default:
            if p.hasPrefix("/api/checkin/") {
                let key = String(p.dropFirst("/api/checkin/".count))
                return jsonString(await runOne(key, test: false))
            }
            if p.hasPrefix("/api/test/") {
                let key = String(p.dropFirst("/api/test/".count))
                return jsonString(await runOne(key, test: true))
            }
            return jsonString(["error": "unknown path \(p)"])
        }
    }

    // MARK: - status

    static func status() -> [String: Any] {
        let day = Store.todayStr()
        var rows: [[String: Any]] = []

        for key in ["workbuddy", "traesolo"] {
            let p = Store.provider(key)
            let enabled = (p["enabled"] as? Bool) ?? true
            let mode = (p["mode"] as? String) ?? (key == "workbuddy" ? "wb" : "trae")
            let ready = readiness(key)
            let rec = Store.todayRecord(key, day: day)
            let st = (rec?["status"] as? String) ?? "idle"
            var msg = (rec?["message"] as? String) ?? "今日尚未执行"
            if rec != nil && st == "fail" && !ready {
                msg = "未配置：请到「设置 · 签到配置」填写后重试"
            }
            let row: [String: Any] = [
                "key": key,
                "label": key == "workbuddy" ? "WorkBuddy" : "Trae Solo",
                "enabled": enabled,
                "mode": mode,
                "dry_run": false,
                "ready": ready,
                "issues": (ready ? [] : ["未配置凭据"]),
                "status": st,
                "message": msg,
                "points": (rec?["points"] as? String) ?? "",
                "total_points": (rec?["total_points"] as? Int) ?? -1,
                "used_points": (rec?["used_points"] as? Int) ?? -1,
                "accounts": (rec != nil ? [[
                    "account_key": "default", "label": "账号 1",
                    "status": st, "message": msg,
                    "points": (rec?["points"] as? String) ?? "",
                    "total_points": (rec?["total_points"] as? Int) ?? -1,
                    "used_points": (rec?["used_points"] as? Int) ?? -1,
                ]] : []),
                "streak_days": (rec?["streak_days"] as? Int) ?? -1,
                "time": (rec?["created_at"] as? Int) ?? 0,
            ]
            rows.append(row)
        }

        var streak = 0
        for r in rows { if let s = r["streak_days"] as? Int, s > streak { streak = s } }

        return [
            "day": day,
            "providers": rows,
            "scheduler": Store.config["scheduler"] ?? [String: Any](),
            "stats": [String: Any](),
            "week": [[String: Any]](),
            "streak": streak,
            "assets": [String: Any](),
            "notify": notifyBrief(),
            "crypto_ok": true,
            "creds_lost": false,
        ]
    }

    static func notifyBrief() -> [String: Any] {
        let n = Store.config["notify"] as? [String: Any] ?? [:]
        let enabled = (n["enabled"] as? Bool) ?? false
        let url = (n["webhook_url"] as? String) ?? ""
        let kind = (n["kind"] as? String) ?? "generic"
        let summary = !enabled || url.isEmpty ? "未配置" : "已配置（\(url.prefix(20))…）"
        return ["enabled": enabled, "kind": kind, "summary": summary]
    }

    // MARK: - 签到

    static func runOne(_ key: String, test: Bool) async -> [String: Any] {
        let t0 = Date()
        let out: CheckinOutcome
        switch key {
        case "workbuddy": out = await WorkBuddyProvider.checkin(wbCredential())
        case "traesolo": out = await TraeProvider.checkin(traeCredential())
        default: return ["status": "fail", "message": "unknown provider \(key)", "points": "", "total_points": -1, "streak_days": -1]
        }
        let elapsed = String(format: "%.2f", Date().timeIntervalSince(t0))
        if !test {
            Store.recordCheckin(key: key, day: Store.todayStr(), outcome: out)
        }
        return [
            "status": out.status.rawValue,
            "message": out.message,
            "points": out.points,
            "total_points": out.totalPoints,
            "streak_days": out.streakDays,
            "elapsed": elapsed,
            "detail": "",
        ]
    }

    static func runAll() async -> [String: Any] {
        // 今天已全部签完则短路（避免重复打上游）
        let day = Store.todayStr()
        var allDone = true
        var enabledKeys: [String] = []
        for key in ["workbuddy", "traesolo"] {
            let p = Store.provider(key)
            if (p["enabled"] as? Bool ?? true) == false { continue }
            enabledKeys.append(key)
            let rec = Store.todayRecord(key, day: day)
            let st = (rec?["status"] as? String) ?? ""
            if st != "success" && st != "already" { allDone = false }
        }
        if enabledKeys.isEmpty {
            return ["trigger": "manual", "skipped": true, "done": true,
                    "message": "没有启用的服务", "results": [String: Any]()] as [String: Any]
        }
        if allDone {
            return ["trigger": "manual", "skipped": true, "done": true,
                    "message": "今天已经全部签到啦 🎉", "results": [String: Any]()] as [String: Any]
        }

        var results: [String: Any] = [:]
        var done = true
        for key in enabledKeys {
            let r = await runOne(key, test: false)
            results[key] = r
            if (r["status"] as? String) == "fail" { done = false }
        }
        return ["trigger": "manual", "skipped": false, "done": done,
                "results": results, "summary": ""] as [String: Any]
    }

    // MARK: - 日志

    static func logs(_ q: [String: String]) -> [[String: Any]] {
        var out = Store.history
        if let provider = q["provider"], !provider.isEmpty {
            out = out.filter { ($0["provider"] as? String) == provider }
        }
        let limit = min(max(Int(q["limit"] ?? "60") ?? 60, 1), 500)
        return Array(out.prefix(limit))
    }

    // MARK: - config

    static func maskValue(forCred credKey: String, prefix: String) -> String {
        let v = Store.cred(credKey)
        guard !v.isEmpty else { return "" }
        let suffix = String(v.suffix(min(2, v.count)))
        return prefix + "***" + suffix
    }

    static func maskedConfig() -> [String: Any] {
        var c = Store.config
        var ps = c["providers"] as? [String: Any] ?? [:]

        if var wb = ps["workbuddy"] as? [String: Any] {
            var b = wb["wb"] as? [String: Any] ?? [:]
            b["accessToken"] = maskValue(forCred: "wbAccessToken", prefix: "dt-")
            b["refreshToken"] = maskValue(forCred: "wbRefreshToken", prefix: "drt-")
            b["uid"] = maskValue(forCred: "wbUid", prefix: "")
            b["uin"] = maskValue(forCred: "wbUin", prefix: "")
            b["enterpriseId"] = maskValue(forCred: "wbEnterpriseId", prefix: "")
            b["domain"] = maskValue(forCred: "wbDomain", prefix: "")
            wb["wb"] = b
            ps["workbuddy"] = wb
        }

        if var tr = ps["traesolo"] as? [String: Any] {
            var b = tr["trae"] as? [String: Any] ?? [:]
            b["token"] = maskValue(forCred: "traeToken", prefix: "")
            b["session"] = maskValue(forCred: "traeSession", prefix: "")
            tr["trae"] = b
            ps["traesolo"] = tr
        }

        c["providers"] = ps
        return c
    }

    static func applyCred(_ v: Any?, credKey: String) {
        guard let s = v as? String else { return }
        if s.contains("***") { return }   // 掩码值不回写
        Store.setCred(credKey, s)
    }

    static func mergeConfig(_ body: [String: Any]) {
        if let incPs = body["providers"] as? [String: Any] {
            var curPs = Store.config["providers"] as? [String: Any] ?? [:]

            if let iwb = incPs["workbuddy"] as? [String: Any] {
                var cwb = Store.provider("workbuddy")
                if let v = iwb["enabled"] as? Bool { cwb["enabled"] = v }
                if let v = iwb["mode"] as? String { cwb["mode"] = v }
                if let ib = iwb["wb"] as? [String: Any] {
                    var cb = Store.wbBlock()
                    if let v = ib["region"] as? String { cb["region"] = v }
                    applyCred(ib["accessToken"], credKey: "wbAccessToken")
                    applyCred(ib["refreshToken"], credKey: "wbRefreshToken")
                    applyCred(ib["uid"], credKey: "wbUid")
                    applyCred(ib["uin"], credKey: "wbUin")
                    applyCred(ib["enterpriseId"], credKey: "wbEnterpriseId")
                    applyCred(ib["domain"], credKey: "wbDomain")
                    cwb["wb"] = cb
                }
                curPs["workbuddy"] = cwb
            }

            if let itr = incPs["traesolo"] as? [String: Any] {
                var ctr = Store.provider("traesolo")
                if let v = itr["enabled"] as? Bool { ctr["enabled"] = v }
                if let v = itr["mode"] as? String { ctr["mode"] = v }
                if let ib = itr["trae"] as? [String: Any] {
                    var cb = Store.traeBlock()
                    if let v = ib["region"] as? String { cb["region"] = v }
                    if let v = ib["host"] as? String { cb["host"] = v }
                    if let v = ib["deviceId"] as? String { cb["deviceId"] = v }
                    applyCred(ib["token"], credKey: "traeToken")
                    applyCred(ib["session"], credKey: "traeSession")
                    ctr["trae"] = cb
                }
                curPs["traesolo"] = ctr
            }

            Store.config["providers"] = curPs
        }
        if let s = body["scheduler"] as? [String: Any] { Store.config["scheduler"] = s }
        if let n = body["notify"] as? [String: Any] { Store.config["notify"] = n }
        Store.saveConfig()
    }

    static func resetCreds(_ body: [String: Any]) {
        let key = (body["key"] as? String) ?? ""
        switch key {
        case "workbuddy":
            for k in ["wbAccessToken", "wbRefreshToken", "wbUid", "wbUin", "wbEnterpriseId", "wbDomain"] { Store.setCred(k, "") }
        case "traesolo":
            Store.setCred("traeToken", "")
            Store.setCred("traeSession", "")
        default:
            break
        }
    }

    // MARK: - 积分 / 通知

    static func wbAssets() async -> [String: Any] {
        // 尽量拉真实余额；拿不到就留空（前端显示「未查询」，绝不写 0）
        var wbRemain = -1
        var traeRemain = -1
        if !Store.cred("wbAccessToken").isEmpty {
            wbRemain = await WorkBuddyProvider.heldCredits(wbCredential())
        }
        if !Store.cred("traeToken").isEmpty {
            traeRemain = await TraeProvider.heldCredits(traeCredential())
        }
        return [
            "ok": true,
            "workbuddy": ["remaining": wbRemain, "used_total": -1],
            "traesolo": ["remaining": traeRemain, "used_total": -1],
        ]
    }

    static func totals() async -> [String: Any] {
        var t: [String: Any] = [:]
        if !Store.cred("wbAccessToken").isEmpty {
            t["workbuddy"] = await WorkBuddyProvider.heldCredits(wbCredential())
        }
        if !Store.cred("traeToken").isEmpty {
            t["traesolo"] = await TraeProvider.heldCredits(traeCredential())
        }
        return t
    }

    static func testNotify() async -> [String: Any] {
        let n = Store.config["notify"] as? [String: Any] ?? [:]
        let url = (n["webhook_url"] as? String) ?? ""
        guard !url.isEmpty, let u = URL(string: url) else {
            return ["ok": false, "error": "未配置 Webhook 地址"]
        }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "title": "签到中心测试通知",
            "body": "这是一条测试通知，收到即表示推送正常。",
            "content": "这是一条测试通知，收到即表示推送正常。",
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let ok = (200..<300).contains(code)
            return ["ok": ok, "http": code, "message": ok ? "已发送" : "HTTP \(code)"]
        } catch {
            return ["ok": false, "error": error.localizedDescription]
        }
    }
}