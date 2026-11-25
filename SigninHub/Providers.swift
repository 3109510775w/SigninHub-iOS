import Foundation

// MARK: - 通用结果类型

enum CheckinStatus: String, Codable {
    case success
    case already
    case noActivity
    case fail
}

/// 一次签到的统一结果
struct CheckinOutcome {
    var status: CheckinStatus
    var message: String
    var points: String        // "+100" 之类，空表示无
    var totalPoints: Int      // 当前持有积分，-1 未知
    var streakDays: Int

    static func fail(_ m: String) -> CheckinOutcome {
        CheckinOutcome(status: .fail, message: m, points: "", totalPoints: -1, streakDays: -1)
    }
    static func already(_ m: String, held: Int, streak: Int = -1) -> CheckinOutcome {
        CheckinOutcome(status: .already, message: m, points: "", totalPoints: held, streakDays: streak)
    }
    static func success(_ m: String, points: String, held: Int, streak: Int = -1) -> CheckinOutcome {
        CheckinOutcome(status: .success, message: m, points: points, totalPoints: held, streakDays: streak)
    }
    static func noActivity(_ m: String, held: Int) -> CheckinOutcome {
        CheckinOutcome(status: .noActivity, message: m, points: "", totalPoints: held, streakDays: -1)
    }
}

enum CheckinError: LocalizedError {
    case network(String)
    case missing(String)
    case unauthorized(String)
    var errorDescription: String? {
        switch self {
        case .network(let s): return "网络错误：\(s)"
        case .missing(let s): return s
        case .unauthorized(let s): return s
        }
    }
}

// MARK: - HTTP 助手

struct Resp {
    var status: Int
    var text: String
    var json: [String: Any]
    var codeInt: Int? { (json["code"] as? NSNumber)?.intValue }
}

enum HTTP {
    static func postJSON(_ url: String, headers: [String: String], body: [String: Any] = [:]) async throws -> Resp {
        guard let u = URL(string: url) else { throw CheckinError.network("无效 URL") }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.timeoutInterval = 25
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw CheckinError.network(error.localizedDescription)
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(data: data, encoding: .utf8) ?? ""
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return Resp(status: status, text: text, json: json)
    }
}

func jint(_ v: Any?) -> Int {
    if let n = v as? NSNumber { return n.intValue }
    if let s = v as? String, let d = Double(s) { return Int(d) }
    return 0
}
func jdict(_ v: Any?) -> [String: Any] { v as? [String: Any] ?? [:] }
func jstr(_ v: Any?) -> String { v as? String ?? "" }

// MARK: - WorkBuddy 官方协议直连

struct WBCredential {
    var accessToken = ""
    var refreshToken = ""
    var uid = ""
    var uin = ""
    var enterpriseId = ""
    var domain = ""
    var region = ""   // "cn" | "global" | ""
}

enum WorkBuddyProvider {
    static let cnChat = "https://copilot.tencent.com"
    static let cnBilling = "https://www.codebuddy.cn"
    static let globalBase = "https://www.workbuddy.ai"
    static let ua = "CLI/2.63.2 CodeBuddy/2.63.2"
    static let statusPath = "/v2/billing/meter/checkin-activity-status"
    static let claimPath = "/v2/billing/meter/daily-checkin"
    static let refreshPath = "/v2/plugin/auth/token/refresh"
    static let summaryPath = "/billing/meter/get-user-resource-summary"

    static func isGlobal(_ c: WBCredential) -> Bool {
        if c.region.lowercased() == "global" { return true }
        let d = c.domain.lowercased()
        return d.contains("workbuddy.ai") || d.contains("global")
    }
    static func billingBase(_ c: WBCredential) -> String { isGlobal(c) ? globalBase : cnBilling }
    static func chatBase(_ c: WBCredential) -> String { isGlobal(c) ? globalBase : cnChat }
    static func referer(_ c: WBCredential) -> String { isGlobal(c) ? globalBase : cnBilling }

    static func commonHeaders(_ c: WBCredential) -> [String: String] {
        let ref = referer(c)
        return [
            "Accept": "application/json, text/plain, */*",
            "X-Requested-With": "XMLHttpRequest",
            "Origin": ref,
            "Referer": ref + "/",
            "User-Agent": ua,
        ]
    }
    static func billingHeaders(_ c: WBCredential) -> [String: String] {
        var h = commonHeaders(c)
        h["Authorization"] = "Bearer " + c.accessToken
        h["Accept"] = "application/json"
        h["Content-Type"] = "application/json"
        if !c.uid.isEmpty { h["X-User-Id"] = c.uid }
        if !c.enterpriseId.isEmpty {
            h["X-Enterprise-Id"] = c.enterpriseId
            h["X-Tenant-Id"] = c.enterpriseId
        }
        if !c.domain.isEmpty { h["X-Domain"] = c.domain }
        return h
    }

    static func refresh(_ c: WBCredential) async throws -> WBCredential {
        guard !c.refreshToken.isEmpty else { throw CheckinError.missing("没有 refreshToken，无法自动续期") }
        var h = commonHeaders(c)
        h["Accept"] = "application/json"
        h["X-Refresh-Token"] = c.refreshToken
        h["X-Auth-Refresh-Source"] = "workbuddy"
        let r = try await HTTP.postJSON(chatBase(c) + refreshPath, headers: h)
        if r.status == 401 || r.status == 403 { throw CheckinError.unauthorized("refresh token 被拒绝，请重新登录 WorkBuddy") }
        if let code = r.codeInt, code != 0 { throw CheckinError.missing("刷新失败 code=\(code) msg=\(jstr(r.json["msg"]))") }
        let data = jdict(r.json["data"])
        let tok = jstr(data["accessToken"]).isEmpty ? jstr(data["access_token"]) : jstr(data["accessToken"])
        guard !tok.isEmpty else { throw CheckinError.missing("刷新响应里没有 accessToken") }
        var nc = c
        nc.accessToken = tok
        if !jstr(data["refreshToken"]).isEmpty { nc.refreshToken = jstr(data["refreshToken"]) }
        return nc
    }

    static func fetchStatus(_ c: WBCredential) async throws -> Resp {
        let r = try await HTTP.postJSON(billingBase(c) + statusPath, headers: billingHeaders(c))
        if r.status == 401 || r.status == 403 { throw CheckinError.unauthorized("凭据被拒绝（http \(r.status)）") }
        return r
    }
    static func fetchClaim(_ c: WBCredential) async throws -> Resp {
        let r = try await HTTP.postJSON(billingBase(c) + claimPath, headers: billingHeaders(c))
        if r.status == 401 || r.status == 403 { throw CheckinError.unauthorized("凭据被拒绝（http \(r.status)）") }
        return r
    }

    /// 当前持有积分：官方汇总口径 get-user-resource-summary.TotalCredits
    static func heldCredits(_ c: WBCredential) async -> Int {
        for path in [summaryPath, "/v2" + summaryPath] {
            do {
                let r = try await HTTP.postJSON(billingBase(c) + path, headers: billingHeaders(c))
                if (200..<300).contains(r.status), let d = r.json["data"] as? [String: Any] {
                    if let s = d["TotalCredits"] as? String, let v = Double(s) { return Int(v) }
                    if let n = d["TotalCredits"] as? NSNumber { return Int(n.doubleValue) }
                }
            } catch { continue }
        }
        return -1
    }

    static func checkin(_ c: WBCredential) async -> CheckinOutcome {
        var cred = c
        var didRefresh = false

        func headText(_ reason: String) -> String {
            let isIntl = isGlobal(cred)
            return isIntl ? "国际版账号没有签到活动（只能读余额）" : "该账号当前没有可领取的签到活动"
        }

        func attempt(_ cur: WBCredential) async throws -> CheckinOutcome {
            let st = try await fetchStatus(cur)
            let codeOk = st.codeInt == nil || st.codeInt == 0
            let data = st.json["data"] as? [String: Any]

            if !codeOk || data == nil {
                let held = await heldCredits(cur)
                let reason = jstr(st.json["msg"]).isEmpty ? "code=\(st.codeInt ?? -1)" : jstr(st.json["msg"])
                return .noActivity(headText(reason) + (reason.isEmpty ? "" : " · \(reason)") + (held >= 0 ? " · 当前积分 \(held)" : ""), held: held)
            }
            if (data?["active"] as? Bool) == false {
                let held = await heldCredits(cur)
                return .noActivity(headText("活动未开启或已结束") + " · 活动未开启或已结束" + (held >= 0 ? " · 当前积分 \(held)" : ""), held: held)
            }
            if (data?["today_checked_in"] as? Bool) == true {
                let held = await heldCredits(cur)
                let streak = jint(data?["streak_days"])
                let today = jint(data?["today_credit"])
                let msg = "今日已签到 · 连续 \(streak) 天" + (today > 0 ? " · 今日 \(today) 积分" : "")
                return .already(msg, held: held, streak: streak)
            }

            let cl = try await fetchClaim(cur)
            let clCode = cl.codeInt
            if let cc = clCode, cc != 0 {
                let held = await heldCredits(cur)
                let reason = jstr(cl.json["msg"]).isEmpty ? "code=\(cc)" : jstr(cl.json["msg"])
                return .noActivity(headText("") + " · \(reason)" + (held >= 0 ? " · 当前积分 \(held)" : ""), held: held)
            }
            let cdata = cl.json["data"] as? [String: Any] ?? [:]
            let credit = jint(cdata["credit"])
            let streak = jint(cdata["streak_days"])
            let held = await heldCredits(cur)
            let msg = "签到成功 · +\(credit) 积分 · 连续 \(streak) 天" + (held >= 0 ? " · 当前积分 \(held)" : "")
            return .success(msg, points: "+\(credit)", held: held, streak: streak)
        }

        while true {
            do { return try await attempt(cred) }
            catch CheckinError.unauthorized(let e) {
                if didRefresh { return .fail("\(e)；刷新后仍失败，请重新登录 WorkBuddy") }
                do { cred = try await refresh(cred); didRefresh = true }
                catch let e2 { return .fail("\(e)；自动续期失败：\(e2.localizedDescription)") }
            }
            catch { return .fail(error.localizedDescription) }
        }
    }
}

// MARK: - Trae Solo 每日签到

struct TraeCredential {
    var token = ""
    var session = ""
    var deviceId = ""
    var region = "cn"
    var host = ""
}

enum TraeProvider {
    static let baseCN = "https://api.trae.cn"
    static let baseIntl = "https://api.trae.ai"
    static let statusPath = "/trae/api/v2/ug/checkin_credits/status"
    static let claimPath = "/trae/api/v2/ug/checkin_credits/claim"
    static let tokenPath = "/cloudide/api/v3/common/GetUserToken"
    static let usagePath = "/trae/api/v2/pay/ide_user_ent_usage"
    static let ideVersion = "1.107.1"
    static let osName = "windows"
    static let osVersion = "Windows 10 Pro for Workstations"
    static let deviceModel = "82RF"
    static let alreadyCodes: Set<Int> = [9004, 9095]
    static let deviceCodes: Set<Int> = [9074]
    static let authHardCodes: Set<Int> = [20405, 20101, 10101, 20403]

    static func base(_ c: TraeCredential) -> String {
        if !c.host.isEmpty { return c.host.hasSuffix("/") ? String(c.host.dropLast()) : c.host }
        return c.region.lowercased() == "global" ? baseIntl : baseCN
    }

    static func checkinHeaders(_ c: TraeCredential) -> [String: String] {
        [
            "Content-Type": "application/json",
            "Accept": "application/json",
            "Authorization": "Cloud-IDE-JWT " + c.token,
            "X-User-Region": c.region.isEmpty ? "cn" : c.region,
            "x-device-id": c.deviceId,
            "x-device-type": osName,
            "x-os-version": osVersion,
            "x-app-version": ideVersion,
            "x-device-brand": deviceModel,
            "User-Agent": "Trae/" + ideVersion,
            "Origin": "https://work.trae.cn",
            "Referer": "https://work.trae.cn/",
        ]
    }

    /// 打一次签到/领取接口；9074 用 req_source=2 重试
    static func checkinCall(_ c: TraeCredential, path: String) async throws -> Resp {
        let r1 = try await HTTP.postJSON(base(c) + path, headers: checkinHeaders(c), body: ["req_source": 1])
        if let code = r1.codeInt, deviceCodes.contains(code) {
            let r2 = try await HTTP.postJSON(base(c) + path, headers: checkinHeaders(c), body: ["req_source": 2])
            if let c2 = r2.codeInt, deviceCodes.contains(c2) { return r1 }
            return r2
        }
        return r1
    }

    static func exchangeSession(_ c: TraeCredential) async throws -> String {
        let headers = [
            "Cookie": "X-Cloudide-Session=" + c.session,
            "Referer": "https://www.trae.cn/",
            "Origin": "https://www.trae.cn",
            "Content-Type": "application/json",
        ]
        let r = try await HTTP.postJSON(base(c) + tokenPath, headers: headers)
        let result = (r.json["Result"] as? [String: Any]) ?? (r.json["result"] as? [String: Any]) ?? [:]
        let tok = jstr(result["Token"]).isEmpty ? jstr(result["token"]) : jstr(result["Token"])
        return tok.count > 40 ? tok : ""
    }

    static func heldCredits(_ c: TraeCredential) async -> Int {
        var h = checkinHeaders(c)
        h["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        do {
            let r = try await HTTP.postJSON(base(c) + usagePath, headers: h,
                                            body: ["require_usage": true, "req_source": 2])
            if r.status != 200 { return -1 }
            if let code = r.codeInt, code != 0 { return -1 }
            let packs = r.json["user_entitlement_pack_list"] as? [Any] ?? []
            var rem = 0.0
            var seen = 0
            for p in packs {
                guard let pd = p as? [String: Any] else { continue }
                let baseInfo = pd["entitlement_base_info"] as? [String: Any] ?? [:]
                let quota = baseInfo["quota"] as? [String: Any] ?? [:]
                let limit = (quota["credits_limit"] as? NSNumber)?.doubleValue ?? 0
                if limit <= 0 { continue }
                let usage = pd["usage"] as? [String: Any] ?? [:]
                let used = (usage["credits_amount"] as? NSNumber)?.doubleValue ?? 0
                rem += max(limit - used, 0)
                seen += 1
            }
            return seen > 0 ? Int(rem) : -1
        } catch { return -1 }
    }

    static func authHint(_ code: Int) -> String {
        switch code {
        case 20405: return "（续期需要设备证明 ECDSA，已改用 session 换 token 绕开）"
        case 20101: return "（refreshToken 已失效或被轮换，请重新登录）"
        case 10101: return "（refreshToken 与客户端不匹配）"
        case 20403: return "（token 与设备不匹配）"
        default: return ""
        }
    }

    static func checkin(_ c: TraeCredential) async -> CheckinOutcome {
        var cred = c
        if cred.deviceId.isEmpty { return .fail("缺少 x-device-id：请填写 16 位设备号（Trae 客户端 storage.json 里的 iCubeAuthInfo 那串）") }

        if cred.token.isEmpty && !cred.session.isEmpty {
            do { let t = try await exchangeSession(cred); if !t.isEmpty { cred.token = t } }
            catch { return .fail("网络错误：换 token 失败（\(error.localizedDescription)）") }
        }
        if cred.token.isEmpty { return .fail("缺少 token：请粘贴 Cloud-IDE-Token，或填 X-Cloudide-Session 自动续期") }

        // status
        var st: Resp
        do { st = try await checkinCall(cred, path: statusPath) }
        catch { return .fail("网络错误：\(error.localizedDescription)") }

        if st.status == 401 || st.status == 403 {
            if !cred.session.isEmpty {
                do {
                    let t = try await exchangeSession(cred)
                    if t.isEmpty { return .fail("凭据被拒绝（HTTP \(st.status)），session 也换不到新 token，请重新登录") }
                    cred.token = t
                } catch { return .fail("凭据被拒绝，session 换 token 失败：\(error.localizedDescription)") }
                do { st = try await checkinCall(cred, path: statusPath) }
                catch { return .fail("网络错误：\(error.localizedDescription)") }
                if st.status == 401 || st.status == 403 { return .fail("换新后仍被拒绝（HTTP \(st.status)），session 可能已过期") }
            } else {
                return .fail("凭据被拒绝（HTTP \(st.status)），token 可能过期；填 session 可自动续期")
            }
        }

        let code = st.codeInt
        if let code = code, code != 0, !alreadyCodes.contains(code) {
            let msg = jstr(st.json["message"]).isEmpty ? jstr(st.json["msg"]) : jstr(st.json["message"])
            if deviceCodes.contains(code) {
                return .fail("被 Trae 风控拦截（code=9074，不是「设备没注册」）。建议：① 先到 trae.cn 官网正常登录用一会儿，隔几小时再回来签；② 已报 9074 的等 12~24 小时再试；③ 期间不要改设备号、不要反复点测试")
            }
            if authHardCodes.contains(code) { return .fail("上游失败 code=\(code) \(msg)\(authHint(code))") }
            return .fail("上游失败 code=\(code) \(msg)")
        }

        let checkedIn = (st.json["checked_in"] as? Bool) == true
        if checkedIn || (code.map { alreadyCodes.contains($0) } ?? false) {
            let held = await heldCredits(cred)
            return .already("今日已签到" + (held >= 0 ? " · 当前积分 \(held)" : ""), held: held)
        }
        if (st.json["enable"] as? Bool) == false {
            return .fail("该账号签到活动未开启（enable=false）")
        }

        // claim
        var cl: Resp
        do { cl = try await checkinCall(cred, path: claimPath) }
        catch { return .fail("网络错误：领取时 \(error.localizedDescription)") }
        if cl.status == 401 || cl.status == 403 {
            if !cred.session.isEmpty {
                do { let t = try await exchangeSession(cred); if !t.isEmpty { cred.token = t } }
                catch { return .fail("领取时凭据被拒绝，续期失败：\(error.localizedDescription)") }
                do { cl = try await checkinCall(cred, path: claimPath) }
                catch { return .fail("网络错误：领取重试 \(error.localizedDescription)") }
            }
        }
        if cl.status == 401 || cl.status == 403 { return .fail("领取时凭据被拒绝（HTTP \(cl.status)）") }

        let code2 = cl.codeInt
        let checkedIn2 = (cl.json["checked_in"] as? Bool) == true
        if let code2 = code2, code2 != 0, !alreadyCodes.contains(code2), !checkedIn2 {
            let msg = jstr(cl.json["message"]) + jstr(cl.json["msg"])
            if deviceCodes.contains(code2) {
                return .fail("领取被 Trae 风控拦截（code=9074）。请先到官网正常用一会儿再试，已报则等 12~24 小时")
            }
            return .fail("领取失败 code=\(code2) \(msg)\(authHardCodes.contains(code2) ? authHint(code2) : "")")
        }

        let credits = jint(cl.json["credits"])
        let extra = jint(cl.json["extra_credits"])
        var gained = ""
        if extra > 0 { gained = "+\(extra)" }
        else if credits > 0 { gained = "+\(credits)" }
        let held = await heldCredits(cred)
        let msg = "签到成功" + (gained.isEmpty ? "" : " · \(gained) 积分") + (held >= 0 ? " · 当前积分 \(held)" : "")
        return .success(msg, points: gained, held: held)
    }
}