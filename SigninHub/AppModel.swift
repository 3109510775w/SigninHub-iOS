import Foundation
import Combine

final class AppModel: ObservableObject {
    @Published var config: AppConfig
    @Published var history: [CheckinResult] = []
    @Published var running = false
    @Published var lastSummary = ""
    @Published var lastOutcome: [ServiceKind: CheckinOutcome] = [:]

    private let configURL: URL
    private let historyURL: URL

    init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        configURL = dir.appendingPathComponent("config.json")
        historyURL = dir.appendingPathComponent("history.json")
        if let d = try? Data(contentsOf: configURL), let c = try? JSONDecoder().decode(AppConfig.self, from: d) {
            config = c
        } else {
            config = AppConfig.default
        }
        if let d = try? Data(contentsOf: historyURL), let h = try? JSONDecoder().decode([CheckinResult].self, from: d) {
            history = h
        }
    }

    func saveConfig() {
        if let d = try? JSONEncoder().encode(config) { try? d.write(to: configURL, options: .atomic) }
    }
    private func saveHistory() {
        if let d = try? JSONEncoder().encode(history) { try? d.write(to: historyURL, options: .atomic) }
    }

    /// Keychain 凭据读写（空串 = 删除）
    func cred(_ key: String) -> String { Keychain.get(key) ?? "" }
    func setCred(_ key: String, _ value: String) {
        if value.isEmpty { Keychain.delete(key) } else { Keychain.set(value, for: key) }
    }

    func wbCredential(for svc: ServiceConfig) -> WBCredential {
        WBCredential(
            accessToken: cred("wbAccessToken"),
            refreshToken: cred("wbRefreshToken"),
            uid: cred("wbUid"),
            uin: cred("wbUin"),
            enterpriseId: cred("wbEnterpriseId"),
            domain: cred("wbDomain"),
            region: svc.region
        )
    }

    func traeCredential(for svc: ServiceConfig) -> TraeCredential {
        TraeCredential(
            token: cred("traeToken"),
            session: cred("traeSession"),
            deviceId: svc.deviceId,
            region: svc.region,
            host: svc.host
        )
    }

    @MainActor
    func runCheckin(kinds: [ServiceKind]? = nil) async {
        guard !running else { return }
        running = true
        defer { running = false }

        let targets = kinds ?? config.providers.filter { $0.enabled }.map { $0.kind }
        var lines: [String] = []

        for kind in targets {
            guard let svc = config.providers.first(where: { $0.kind == kind }), svc.enabled else { continue }

            let outcome: CheckinOutcome
            if svc.mode == "http" {
                outcome = await Self.httpCheckin(svc)
            } else {
                switch kind {
                case .workbuddy:
                    outcome = await WorkBuddyProvider.checkin(wbCredential(for: svc))
                case .traesolo:
                    outcome = await TraeProvider.checkin(traeCredential(for: svc))
                case .doubao:
                    outcome = .fail("豆包签到已下线（2026-11-20 服务端风控 710010702）")
                }
            }

            lastOutcome[kind] = outcome
            let ok = outcome.status == .success || outcome.status == .already
            history.insert(CheckinResult(kind: kind.rawValue, date: Date(), success: ok, message: outcome.message), at: 0)
            lines.append("\(kind.label)：\(outcome.message)")
        }

        saveHistory()
        lastSummary = lines.joined(separator: "\n")
        if let n = config.notify, n.enabled, !n.webhookURL.isEmpty {
            await Notify.send(url: n.webhookURL, text: lastSummary)
        }
    }

    private static func httpCheckin(_ svc: ServiceConfig) async -> CheckinOutcome {
        do {
            let resp = try await CheckinEngine.run(svc.http)
            if resp.success { return .success("接口签到成功：" + String(resp.raw.prefix(120)), points: "", held: -1) }
            return .fail("接口返回判定失败：" + String(resp.raw.prefix(200)))
        } catch {
            return .fail(error.localizedDescription)
        }
    }
}