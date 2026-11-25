import SwiftUI

struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        TabView {
            CheckinView().tabItem { Label("签到", systemImage: "checkmark.seal") }
            RecordView().tabItem { Label("记录", systemImage: "clock") }
            SettingsView().tabItem { Label("设置", systemImage: "gear") }
        }
        .environmentObject(model)
    }
}

// MARK: - 签到页

struct CheckinView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationView {
            List {
                Section {
                    Button {
                        Task { await model.runCheckin() }
                    } label: {
                        Label("全部签到", systemImage: "checkmark.seal.fill")
                    }
                    .disabled(model.running)
                    if !model.lastSummary.isEmpty {
                        Text(model.lastSummary).font(.footnote).foregroundColor(.secondary)
                    }
                }

                ForEach(model.config.providers) { svc in
                    Section {
                        Toggle("启用", isOn: enableBinding(svc))
                        if let o = model.lastOutcome[svc.kind] {
                            Text(statusText(o)).font(.footnote).foregroundColor(color(o))
                        }
                        HStack {
                            Button("签到 \(svc.kind.label)") {
                                Task { await model.runCheckin(kinds: [svc.kind]) }
                            }
                            .disabled(model.running)
                            Spacer()
                            NavigationLink(destination: credentialEditor(svc)) {
                                Text("凭据").font(.footnote)
                            }
                        }
                    } header: {
                        Text(svc.kind.label)
                    }
                }
            }
            .navigationTitle("签到中心")
            .navigationViewStyle(.stack)
        }
    }

    @ViewBuilder
    private func credentialEditor(_ svc: ServiceConfig) -> some View {
        switch svc.kind {
        case .workbuddy: WBCredentialView(svc: svc)
        case .traesolo: TraeCredentialView(svc: svc)
        case .doubao: Text("豆包签到已下线").padding()
        }
    }

    private func enableBinding(_ svc: ServiceConfig) -> Binding<Bool> {
        Binding(
            get: { model.config.providers.first(where: { $0.kind == svc.kind })?.enabled ?? false },
            set: { v in
                if let i = model.config.providers.firstIndex(where: { $0.kind == svc.kind }) {
                    model.config.providers[i].enabled = v
                    model.saveConfig()
                }
            }
        )
    }

    private func statusText(_ o: CheckinOutcome) -> String {
        switch o.status {
        case .success: return "✓ \(o.message)"
        case .already: return "已签 · \(o.message)"
        case .noActivity: return "无活动 · \(o.message)"
        case .fail: return "失败 · \(o.message)"
        }
    }
    private func color(_ o: CheckinOutcome) -> Color {
        switch o.status {
        case .success: return .green
        case .already: return .secondary
        case .noActivity: return .orange
        case .fail: return .red
        }
    }
}

// MARK: - WorkBuddy 凭据

struct WBCredentialView: View {
    @EnvironmentObject var model: AppModel
    let svc: ServiceConfig
    @State private var accessToken = ""
    @State private var refreshToken = ""
    @State private var uid = ""
    @State private var enterpriseId = ""
    @State private var domain = ""
    @State private var region = "cn"

    var body: some View {
        Form {
            Section(header: Text("WorkBuddy 凭据（存 Keychain）")) {
                SecureField("accessToken", text: $accessToken)
                SecureField("refreshToken（可选）", text: $refreshToken)
                TextField("uid（可选）", text: $uid)
                TextField("enterpriseId（可选）", text: $enterpriseId)
                TextField("domain（国际版填 workbuddy.ai）", text: $domain)
                Picker("区域", selection: $region) {
                    Text("国内").tag("cn")
                    Text("国际").tag("global")
                    Text("自动").tag("")
                }
                Button("保存") { save() }.buttonStyle(.borderedProminent)
            }
            Section(footer: Text("accessToken 从 WorkBuddy 桌面端 / DSH 插件 vault 或浏览器 DevTools 的 Authorization: Bearer 头获取。")) {
                EmptyView()
            }
        }
        .navigationTitle("WorkBuddy")
        .onAppear {
            accessToken = model.cred("wbAccessToken")
            refreshToken = model.cred("wbRefreshToken")
            uid = model.cred("wbUid")
            enterpriseId = model.cred("wbEnterpriseId")
            domain = model.cred("wbDomain")
            region = svc.region
        }
    }

    func save() {
        model.setCred("wbAccessToken", accessToken)
        model.setCred("wbRefreshToken", refreshToken)
        model.setCred("wbUid", uid)
        model.setCred("wbEnterpriseId", enterpriseId)
        model.setCred("wbDomain", domain)
        if let i = model.config.providers.firstIndex(where: { $0.kind == .workbuddy }) {
            model.config.providers[i].region = region
            model.saveConfig()
        }
    }
}

// MARK: - Trae 凭据

struct TraeCredentialView: View {
    @EnvironmentObject var model: AppModel
    let svc: ServiceConfig
    @State private var token = ""
    @State private var session = ""
    @State private var deviceId = ""
    @State private var region = "cn"

    var body: some View {
        Form {
            Section(header: Text("Trae Solo 凭据")) {
                SecureField("Cloud-IDE-Token（8 小时有效）", text: $token)
                SecureField("X-Cloudide-Session（约 14 天，自动换 token）", text: $session)
                TextField("x-device-id（16 位数字）", text: $deviceId)
                    .keyboardType(.numberPad)
                Picker("区域", selection: $region) {
                    Text("国内").tag("cn")
                    Text("国际").tag("global")
                }
                Button("保存") { save() }.buttonStyle(.borderedProminent)
            }
            Section(footer: Text("token：登录 www.trae.cn 后 DevTools 执行 localStorage.getItem('Cloud-IDE-Token')。\n设备号：Trae 客户端 storage.json 里 iCubeAuthInfo://icube-dc: 后面那串 16 位数字。")) {
                EmptyView()
            }
        }
        .navigationTitle("Trae Solo")
        .onAppear {
            token = model.cred("traeToken")
            session = model.cred("traeSession")
            deviceId = svc.deviceId
            region = svc.region
        }
    }

    func save() {
        model.setCred("traeToken", token)
        model.setCred("traeSession", session)
        if let i = model.config.providers.firstIndex(where: { $0.kind == .traesolo }) {
            model.config.providers[i].deviceId = deviceId
            model.config.providers[i].region = region
            model.saveConfig()
        }
    }
}

// MARK: - 记录页

struct RecordView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationView {
            List(model.history) { r in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(r.kind).bold()
                        Spacer()
                        Image(systemName: r.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(r.success ? .green : .red)
                    }
                    Text(r.message).font(.caption).foregroundColor(.secondary)
                    Text(r.date, style: .date).font(.caption2).foregroundColor(.secondary)
                }
            }
            .navigationTitle("记录")
            .navigationViewStyle(.stack)
        }
    }
}

// MARK: - 设置页（编辑 config.json）

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var text = ""
    @State private var errorMsg: String?

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 12) {
                if let e = errorMsg { Text(e).foregroundColor(.red).font(.footnote) }
                TextEditor(text: $text)
                    .font(.system(.caption, design: .monospaced))
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .border(Color.gray.opacity(0.3))
                Button("保存配置") { save() }.buttonStyle(.borderedProminent)
            }
            .padding()
            .navigationTitle("设置（config.json）")
            .navigationViewStyle(.stack)
            .onAppear { refresh() }
        }
    }

    private func refresh() {
        if let d = try? JSONEncoder().encode(model.config), let s = String(data: d, encoding: .utf8) {
            text = pretty(s)
        }
    }
    private func pretty(_ s: String) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)),
           let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
           let out = String(data: d, encoding: .utf8) { return out }
        return s
    }
    private func save() {
        guard let data = text.data(using: .utf8),
              let c = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            errorMsg = "JSON 解析失败，未保存"
            return
        }
        model.config = c
        model.saveConfig()
        errorMsg = nil
    }
}