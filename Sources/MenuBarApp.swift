import SwiftUI
import Foundation
import Darwin

private let guardianRoot = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/SZUNetworkGuardian", isDirectory: true).path
private let guardianLabel = "com.wenjun.szu-network-guardian"
private let usernameService = "com.wenjun.szu-network-guardian.username"
private let passwordService = "com.wenjun.szu-network-guardian.password"

#if !TESTING
@main
struct SZUNetworkGuardianApp: App {
    @StateObject private var model = GuardianModel()
    var body: some Scene {
        MenuBarExtra("SZU 网络", systemImage: model.running ? "shield.checkered" : "shield.slash") {
            MenuBarDashboard(model: model)
                .onAppear { model.refresh() }
        }
        .menuBarExtraStyle(.window)
    }
}
#endif

@MainActor
final class GuardianModel: ObservableObject {
    @Published var running = false
    @Published var networkZone = "teaching_office" {
        didSet { updateSettingsDirty() }
    }
    @Published var intervalMinutes = 5 {
        didSet { updateSettingsDirty() }
    }
    @Published var feedback = "正在读取后台守护状态…"
    @Published var activity: [String] = []
    @Published var busy = false
    @Published var credentialUsername = ""
    @Published var credentialPassword = ""
    @Published var editingCredentials = false
    @Published private(set) var settingsDirty = false
    private var refreshTimer: Timer?
    private var lastRunning: Bool?
    private var savedNetworkZone = "teaching_office"
    private var savedIntervalMinutes = 5
    private var applyingConfiguration = false

    init() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit { refreshTimer?.invalidate() }

    var zoneDisplayName: String {
        switch networkZone {
        case "dormitory": return "宿舍区"
        case "auto": return "自动尝试（实验性）"
        default: return "教学 / 办公区"
        }
    }

    var zoneEndpointDescription: String {
        switch networkZone {
        case "dormitory": return "宿舍 ePortal · HTTP"
        case "auto": return "依次尝试两种认证 · 不建议无人值守使用"
        default: return "net.szu.edu.cn · HTTPS"
        }
    }

    func refresh() {
        let isRunning = guardianPID() != nil
        running = isRunning
        if !busy && (lastRunning != isRunning || feedback == "正在读取后台守护状态…") {
            feedback = isRunning ? "后台守护运行中 · 等待下一次检测" : "后台守护未运行 · 可使用“重启守护”恢复"
        }
        lastRunning = isRunning
        readConfiguration()
        activity = recentActivity()
    }

    func checkNow() {
        guard let pid = guardianPID() else {
            feedback = "无法检测：后台守护未运行"
            activity.insert("刚刚 · 请求检测失败：守护未运行", at: 0)
            return
        }
        guard kill(pid, SIGUSR1) == 0 else {
            feedback = "请求未送达，请尝试重启后台守护"
            return
        }
        busy = true
        feedback = "已请求立即检测，后台正在处理…"
        activity.insert("刚刚 · 已请求立即检测", at: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.busy = false
            self?.refresh()
            if self?.running == true {
                self?.feedback = "检测完成：运行记录已更新；正常联网时不会重复认证"
            }
        }
    }

    func restartGuardian() {
        busy = true
        feedback = "正在重启后台守护…"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["kickstart", "-k", "gui/\(getuid())/\(guardianLabel)"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            feedback = task.terminationStatus == 0 ? "后台守护已重启" : "重启命令未成功执行"
        } catch {
            feedback = "无法启动系统守护命令"
        }
        busy = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.refresh() }
    }

    func saveSettings() {
        let path = URL(fileURLWithPath: guardianRoot + "/config.json")
        do {
            var config = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any] ?? [:]
            config["network_zone"] = networkZone
            config["check_interval_seconds"] = intervalMinutes * 60
            let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: path, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            savedNetworkZone = networkZone
            savedIntervalMinutes = intervalMinutes
            settingsDirty = false
            if let pid = guardianPID() { _ = kill(pid, SIGUSR1) }
            feedback = "设置已保存：\(zoneDisplayName) · \(intervalMinutes) 分钟"
            activity.insert("刚刚 · 已保存连接设置并请求重新检测", at: 0)
        } catch {
            feedback = "无法保存连接设置"
        }
    }

    func saveCredentials() {
        let username = credentialUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = credentialPassword
        guard !username.isEmpty, !password.isEmpty else {
            feedback = "请输入完整账号和密码"
            return
        }
        busy = true
        defer {
            credentialUsername = ""
            credentialPassword = ""
            busy = false
        }
        guard writeKeychain(service: passwordService, secret: password),
              writeKeychain(service: usernameService, secret: username) else {
            feedback = "无法写入 macOS Keychain"
            return
        }
        if let pid = guardianPID() { _ = kill(pid, SIGUSR1) }
        feedback = "凭据已安全更新，并请求重新检测"
        activity.insert("刚刚 · 已更新 Keychain 凭据", at: 0)
    }

    func openLogs() {
        NSWorkspace.shared.open(URL(fileURLWithPath: guardianRoot + "/logs", isDirectory: true))
        feedback = "已在 Finder 中打开日志目录"
    }

    private func guardianPID() -> pid_t? {
        let path = guardianRoot + "/guardian.pid"
        guard let text = try? String(contentsOfFile: path, encoding: .ascii),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1, kill(pid, 0) == 0 else { return nil }
        return pid
    }

    private func writeKeychain(service: String, secret: String) -> Bool {
        let task = Process()
        let input = Pipe()
        task.executableURL = URL(fileURLWithPath: guardianRoot + "/keychain")
        task.arguments = ["set", service]
        task.standardInput = input
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            input.fileHandleForWriting.write(Data(secret.utf8))
            try input.fileHandleForWriting.close()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            try? input.fileHandleForWriting.close()
            return false
        }
    }

    private func readConfiguration() {
        guard !settingsDirty else { return }
        let path = URL(fileURLWithPath: guardianRoot + "/config.json")
        guard let data = try? Data(contentsOf: path),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let seconds = config["check_interval_seconds"] as? Int else { return }
        applyingConfiguration = true
        defer { applyingConfiguration = false }
        if let zone = config["network_zone"] as? String,
           ["teaching_office", "dormitory", "auto"].contains(zone) {
            networkZone = zone
        }
        intervalMinutes = max(1, min(1440, seconds / 60))
        savedNetworkZone = networkZone
        savedIntervalMinutes = intervalMinutes
        settingsDirty = false
    }

    private func updateSettingsDirty() {
        guard !applyingConfiguration else { return }
        settingsDirty = networkZone != savedNetworkZone || intervalMinutes != savedIntervalMinutes
        if settingsDirty {
            feedback = "设置已修改，点击保存后生效"
        }
    }

    private func recentActivity() -> [String] {
        let directory = URL(fileURLWithPath: guardianRoot + "/logs", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return ["暂无运行记录"]
        }
        let lines = files
            .filter { $0.lastPathComponent.hasPrefix("guardian-") && $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .suffix(2)
            .flatMap { (try? String(contentsOf: $0, encoding: .utf8))?.replacingOccurrences(of: "\\n", with: "\n").split(separator: "\n").map(String.init) ?? [] }
            .suffix(8)
            .reversed()
        return lines.isEmpty ? ["暂无运行记录"] : Array(lines)
    }
}

struct MenuBarDashboard: View {
    @ObservedObject var model: GuardianModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "shield.checkered")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.blue)
                Text("SZU 网络守护").font(.headline)
                Spacer()
                Circle().fill(model.running ? .green : .orange).frame(width: 9, height: 9)
                Text(model.running ? "运行中" : "未运行").font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(model.feedback).font(.subheadline.weight(.medium)).lineLimit(1)
                Text("\(model.zoneDisplayName) · \(model.zoneEndpointDescription)").font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 8) {
                Label("Keychain 已保护", systemImage: "key.fill")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("区域", selection: $model.networkZone) {
                    Text("教学区").tag("teaching_office")
                    Text("宿舍区").tag("dormitory")
                    Text("自动（实验）").tag("auto")
                }
                .labelsHidden().frame(width: 82)
                Picker("", selection: $model.intervalMinutes) {
                    ForEach([1, 3, 5, 10, 15, 30, 60, 120, 360, 720, 1440], id: \.self) { Text("\($0) 分钟").tag($0) }
                }
                .labelsHidden().frame(width: 95)
                Button(model.settingsDirty ? "保存*" : "保存") { model.saveSettings() }.controlSize(.small)
            }

            if model.networkZone == "dormitory" {
                Label("宿舍接口使用 HTTP，认证 URL 会携带密码；仅在可信校园网内使用", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5)).foregroundStyle(.orange).lineLimit(2)
            } else if model.networkZone == "auto" {
                Label("实验模式可能依次尝试两种网关；固定设备请手动选择实际区域", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5)).foregroundStyle(.orange).lineLimit(2)
            }

            DisclosureGroup("更新校园网凭据", isExpanded: $model.editingCredentials) {
                VStack(spacing: 7) {
                    TextField("校园网账号", text: $model.credentialUsername)
                        .textFieldStyle(.roundedBorder)
                    SecureField("统一身份认证密码", text: $model.credentialPassword)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Text("内容仅通过标准输入写入 Keychain").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button("安全保存") { model.saveCredentials() }
                            .controlSize(.small).disabled(model.busy)
                    }
                }
                .padding(.top, 6)
            }
            .font(.caption)

            HStack(spacing: 8) {
                Button { model.checkNow() } label: {
                    Label("检测", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).disabled(model.busy)
                Button { model.restartGuardian() } label: {
                    Label("重启", systemImage: "power").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).disabled(model.busy)
                Button { model.openLogs() } label: {
                    Label("日志", systemImage: "folder").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.small)

            Divider()
            HStack {
                Text("最近记录").font(.caption.weight(.semibold))
                Spacer()
                Text("点击外部即可收起").font(.caption2).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(model.activity.prefix(3).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            Text("关闭面板不会停止后台守护").font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(16)
        .frame(width: 360, height: model.editingCredentials ? 530 : 456)
    }
}

struct GuardianDashboard: View {
    @ObservedObject var model: GuardianModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            statusCard
            settingsCard
            actions
            activityCard
            Text("点击菜单栏图标打开或关闭面板 · 凭据只保存在 macOS Keychain")
                .font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(28)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("SZU 网络守护").font(.system(size: 27, weight: .bold))
                Text("深圳大学 · \(model.zoneDisplayName)").foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "shield.checkered").font(.system(size: 28, weight: .semibold)).foregroundStyle(.blue)
                .padding(11).background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 13))
        }
    }

    private var statusCard: some View {
        Card {
            HStack(spacing: 14) {
                Circle().fill(model.running ? Color.green : Color.orange).frame(width: 12, height: 12)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.running ? "守护运行中" : "守护未运行").font(.headline)
                    Text(model.feedback).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Text(model.running ? "已启用" : "需处理").font(.caption.weight(.semibold))
                    .foregroundStyle(model.running ? .green : .orange)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background((model.running ? Color.green : Color.orange).opacity(0.10), in: Capsule())
            }
        }
    }

    private var settingsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 15) {
                Text("连接设置").font(.headline)
                HStack {
                    SettingLabel(title: "认证区域", value: model.zoneDisplayName)
                    Divider().frame(height: 36)
                    SettingLabel(title: "凭据", value: "已存储在钥匙串")
                    Spacer()
                }
                Divider()
                HStack {
                    Text("检测间隔").foregroundStyle(.secondary)
                    Picker("", selection: $model.intervalMinutes) {
                        ForEach([1, 3, 5, 10, 15, 30, 60, 120, 360, 720, 1440], id: \.self) { value in Text("\(value) 分钟").tag(value) }
                    }
                    .labelsHidden().frame(width: 130)
                    Spacer()
                    Button("保存设置") { model.saveSettings() }.buttonStyle(.bordered)
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button { model.checkNow() } label: { Label("立即检测", systemImage: "arrow.clockwise").frame(maxWidth: .infinity) }
                .buttonStyle(PrimaryButtonStyle()).disabled(model.busy)
            Button { model.restartGuardian() } label: { Label("重启守护", systemImage: "power").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered).controlSize(.large).disabled(model.busy)
            Button { model.openLogs() } label: { Label("日志目录", systemImage: "folder").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered).controlSize(.large)
        }
    }

    private var activityCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("运行记录").font(.headline); Spacer(); Text("最近事件").font(.caption).foregroundStyle(.secondary) }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(model.activity.enumerated()), id: \.offset) { _, line in
                            HStack(alignment: .top, spacing: 9) {
                                Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.secondary).padding(.top, 5)
                                Text(line).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 150).padding(12)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

struct SettingLabel: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.medium))
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.controlSize(.large).padding(.vertical, 5).foregroundStyle(.white)
            .background(configuration.isPressed ? Color.blue.opacity(0.75) : Color.blue, in: RoundedRectangle(cornerRadius: 8))
    }
}
