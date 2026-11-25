import Foundation

/// 服务种类（豆包已下线，仅保留占位）
enum ServiceKind: String, Codable, CaseIterable, Hashable {
    case workbuddy
    case traesolo
    case doubao
}

/// 「接口模式」配置：URL / 请求头 / 请求体 / 成功判定
struct HttpProviderConfig: Codable {
    var method: String = "POST"          // GET / POST / PUT
    var url: String = ""
    var headers: [String: String] = [:]
    var body: [String: String] = [:]
    var bodyType: String = "json"        // "json" | "form"
    var successExpr: String = "code"     // 支持 data.status 这种点路径
    var successValue: String = "0"
}

/// 单个签到服务
struct ServiceConfig: Codable, Identifiable {
    var id: ServiceKind { kind }
    var kind: ServiceKind
    var enabled: Bool = true
    var http: HttpProviderConfig

    // 可选：从 Keychain 读取 token 并注入到指定请求头
    var tokenKey: String? = nil          // 例如 "wbToken" / "traeToken"
    var tokenHeader: String = "Authorization"
    var tokenPrefix: String = "Bearer "  // Trae 用 "Cloud-IDE-JWT "
}

/// 通知配置（Bark / PushPlus / 钉钉 / 飞书 / 企业微信 webhook）
struct NotifyConfig: Codable {
    var enabled: Bool = false
    var webhookURL: String = ""
}

struct AppConfig: Codable {
    var providers: [ServiceConfig]
    var schedulerTimes: [String] = ["08:30"]
    var jitterMin: Int = 0
    var notify: NotifyConfig?

    static var `default`: AppConfig {
        AppConfig(
            providers: [
                ServiceConfig(kind: .workbuddy, tokenKey: "wbToken", tokenPrefix: "Bearer ",
                              http: HttpProviderConfig()),
                ServiceConfig(kind: .traesolo, tokenKey: "traeToken", tokenPrefix: "Cloud-IDE-JWT ",
                              http: HttpProviderConfig()),
                ServiceConfig(kind: .doubao, enabled: false, http: HttpProviderConfig())
            ]
        )
    }
}

/// 一条签到记录
struct CheckinResult: Codable, Identifiable {
    var id = UUID()
    var kind: String
    var date: Date
    var success: Bool
    var message: String
}
