import Foundation
import Combine

/// 应用主模型：配置读写 + 签到编排 + 历史记录
final class AppModel: ObservableObject {
    @Published var config: AppConfig
    @Published var history: [CheckinResult] = []
    @Published var running = false
    @Published var lastSummary: String = ""

    private let configURL: URL
    private let historyURL: URL

    init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        configURL = dir.appendingPathComponent("config.json")
        historyURL = dir.appendingPathComponent("history.json")

        if let d = try? Data(contentsOf: configURL),
           let c = try? JSONDecoder().decode(AppConfig.self, from: d) {
            config = c
        } else {
            config = AppConfig.default
        }

        if let d = try? Data(contentsOf: historyURL),
           let h = try? JSONDecoder().decode([CheckinResult].self, from: d) {
            history = h
        }
    }

    func saveConfig() {
        if let d = try? JSONEncoder().encode(config) {
            try? d.write(to: configURL, options: .atomic)
        }
    }

    private func saveHistory() {
        if let d = try? JSONEncoder().encode(history) {
            try? d.write(to: historyURL, options: .atomic)
        }
    }

    /// 执行签到（不传 kinds 则执行全部启用项）
    func runCheckin(kinds: [ServiceKind]? = nil) async {
        guard !running else { return }
        running = true
        defer { running = false }

        var lines: [String] = []
        let targets = kinds ?? config.providers.filter { $0.enabled }.map { $0.kind }

        for kind in targets {
            guard let svc = config.providers.first(where: { $0.kind == kind }), svc.enabled else { continue }
            let auth: AuthInjection? = svc.tokenKey.flatMap { key in
                guard let t = Keychain.get(key), !t.isEmpty else { return nil }
                return AuthInjection(header: svc.tokenHeader, value: svc.tokenPrefix + t)
            }
            do {
                let resp = try await CheckinEngine.run(svc.http, auth: auth)
                let record = CheckinResult(kind: kind.rawValue, date: Date(),
                                           success: resp.success,
                                           message: String(resp.raw.prefix(300)))
                history.insert(record, at: 0)
                lines.append("\(kind.rawValue): \(resp.success ? "成功" : "失败")")
            } catch {
                let record = CheckinResult(kind: kind.rawValue, date: Date(),
                                           success: false, message: error.localizedDescription)
                history.insert(record, at: 0)
                lines.append("\(kind.rawValue): 错误 - \(error.localizedDescription)")
            }
        }

        saveHistory()
        lastSummary = lines.joined(separator: "\n")

        if let n = config.notify, n.enabled, !n.webhookURL.isEmpty {
            await Notify.send(url: n.webhookURL, text: lastSummary)
        }
    }

    func setToken(_ value: String, for key: String) {
        if value.isEmpty { Keychain.delete(key) } else { Keychain.set(value, for: key) }
    }

    func enabledBinding(_ svc: ServiceConfig) -> Binding<Bool> {
        Binding(
            get: { self.config.providers.first(where: { $0.kind == svc.kind })?.enabled ?? false },
            set: { v in
                if let i = self.config.providers.firstIndex(where: { $0.kind == svc.kind }) {
                    self.config.providers[i].enabled = v
                    self.saveConfig()
                }
            }
        )
    }
}
