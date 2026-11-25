import Foundation

enum ServiceKind: String, Codable, CaseIterable, Hashable {
    case workbuddy
    case traesolo
    case doubao

    var label: String {
        switch self {
        case .workbuddy: return "WorkBuddy"
        case .traesolo: return "Trae Solo"
        case .doubao: return "豆包（已下线）"
        }
    }
}

/// 「接口模式」配置（其它服务 / 兜底）
struct HttpProviderConfig: Codable {
    var method: String = "POST"
    var url: String = ""
    var headers: [String: String] = [:]
    var body: [String: String] = [:]
    var bodyType: String = "json"
    var successExpr: String = "code"
    var successValue: String = "0"
}

struct ServiceConfig: Codable, Identifiable {
    var id: ServiceKind { kind }
    var kind: ServiceKind
    var enabled: Bool = true
    var mode: String = "native"   // "native" | "http"
    var http: HttpProviderConfig
    var region: String = "cn"
    var host: String = ""
    var deviceId: String = ""     // Trae 设备号（16 位数字），非敏感
}

struct NotifyConfig: Codable {
    var enabled: Bool = false
    var webhookURL: String = ""
}

struct AppConfig: Codable {
    var providers: [ServiceConfig]
    var schedulerTimes: [String] = ["08:30"]
    var notify: NotifyConfig?

    static var `default`: AppConfig {
        AppConfig(providers: [
            ServiceConfig(kind: .workbuddy, mode: "native", http: HttpProviderConfig(), region: "cn"),
            ServiceConfig(kind: .traesolo, mode: "native", http: HttpProviderConfig(), region: "cn"),
            ServiceConfig(kind: .doubao, enabled: false, mode: "http", http: HttpProviderConfig()),
        ])
    }
}

struct CheckinResult: Codable, Identifiable {
    var id = UUID()
    var kind: String
    var date: Date
    var success: Bool
    var message: String
}