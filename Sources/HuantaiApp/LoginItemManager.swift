import Combine
import Foundation
import ServiceManagement

final class LoginItemManager: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var errorMessage: String?
    private let readStatus: () -> SMAppService.Status
    private let register: () throws -> Void
    private let unregister: () throws -> Void
    private let openSettings: () -> Void

    init(
        readStatus: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
        register: @escaping () throws -> Void = { try SMAppService.mainApp.register() },
        unregister: @escaping () throws -> Void = { try SMAppService.mainApp.unregister() },
        openSettings: @escaping () -> Void = { SMAppService.openSystemSettingsLoginItems() }
    ) {
        self.readStatus = readStatus
        self.register = register
        self.unregister = unregister
        self.openSettings = openSettings
        status = readStatus()
    }

    // Pending approval is registered too, so the user can turn it off here.
    var isRegistered: Bool { status == .enabled || status == .requiresApproval }

    var statusDescription: String {
        switch status {
        case .enabled: return "已开启，登录 Mac 后仅在菜单栏运行。"
        case .notRegistered: return "登录 Mac 后自动启动换台。"
        case .requiresApproval: return "等待系统允许，请在「登录项」中启用换台。"
        case .notFound: return "系统未找到启动项，请重新开启。"
        @unknown default: return "暂时无法读取启动状态。"
        }
    }

    func refresh() { status = readStatus() }

    func setEnabled(_ enabled: Bool) {
        refresh()
        errorMessage = nil
        guard enabled != isRegistered else { return }
        do {
            if enabled {
                try register()
            } else {
                try unregister()
            }
        } catch {
            errorMessage = "\(enabled ? "开启" : "关闭")开机运行失败：\(error.localizedDescription)"
        }
        // Read back the OS result, including failure and approval states.
        refresh()
    }

    func showSystemSettings() { openSettings() }
}
