import ServiceManagement

@MainActor
final class LaunchAtLoginManager: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var statusMessage: String?

    init() {
        refresh()
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            statusMessage = nil
        } catch {
            statusMessage = "无法更新登录项：\(error.localizedDescription)"
        }
        refresh()
    }

    func refresh() {
        switch SMAppService.mainApp.status {
        case .enabled:
            isEnabled = true
            statusMessage = nil
        case .requiresApproval:
            isEnabled = false
            statusMessage = "请在系统设置 → 通用 → 登录项中允许 Restly。"
        case .notFound:
            isEnabled = false
            statusMessage = "请先将 Restly 拖入“应用程序”文件夹。"
        case .notRegistered:
            isEnabled = false
        @unknown default:
            isEnabled = false
        }
    }
}
