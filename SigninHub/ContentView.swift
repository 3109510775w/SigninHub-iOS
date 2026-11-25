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
                    if !model.lastSummary.isEmpty {
                        Text(model.lastSummary)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }

                ForEach(model.config.providers) { svc in
                    Section(svc.kind.rawValue) {
                        Toggle("启用", isOn: model.enabledBinding(svc))
                        if let key = svc.tokenKey {
                            TokenField(key: key, label: "Token（存 Keychain）")
                        }
                        Button("签到 \(svc.kind.rawValue)") {
                            Task { await model.runCheckin(kinds: [svc.kind]) }
                        }
                        .disabled(svc.http.url.isEmpty && (svc.tokenKey == nil || Keychain.get(svc.tokenKey ?? "") == nil))
                    }
                }
            }
            .navigationTitle("签到中心")
            .disabled(model.running)
            .navigationViewStyle(.stack)
        }
    }
}

// MARK: - Token 输入

struct TokenField: View {
    let key: String
    let label: String
    @State private var text = ""
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack {
            TextField(label, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onAppear { text = Keychain.get(key) ?? "" }
            Button("保存") {
                model.setToken(text, for: key)
            }
            .buttonStyle(.borderless)
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

// MARK: - 设置页（直接编辑 config.json）

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var text = ""
    @State private var errorMsg: String?

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 12) {
                if let e = errorMsg {
                    Text(e).foregroundColor(.red).font(.footnote)
                }
                TextEditor(text: $text)
                    .font(.system(.caption, design: .monospaced))
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .border(Color.gray.opacity(0.3))
                Button("保存配置") { save() }
                    .buttonStyle(.borderedProminent)
            }
            .padding()
            .navigationTitle("设置（config.json）")
            .navigationViewStyle(.stack)
            .onAppear { refresh() }
        }
    }

    private func refresh() {
        if let d = try? JSONEncoder().encode(model.config),
           let s = String(data: d, encoding: .utf8) {
            text = pretty(s)
        }
    }

    private func pretty(_ s: String) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)),
           let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
           let out = String(data: d, encoding: .utf8) {
            return out
        }
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
