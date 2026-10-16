import Combine
import Foundation
import HuantaiCore
import HuantaiFeishu

final class FeishuBotManager: ObservableObject {
    @Published private(set) var binding: FeishuBotBinding?
    @Published private(set) var status = "未绑定"
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    private let configuration: FeishuBotConfiguration
    private var worker: Task<Void, Never>?
    private var timer: Timer?

    init(store: SessionStore, startServices: Bool) {
        configuration = FeishuBotConfiguration(dataDirectory: store.dataDirectory)
        reload()
        guard startServices else { return }
        let service = FeishuBotService(store: store)
        worker = Task.detached {
            while !Task.isCancelled {
                do { try await service.run() } catch {}
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.reload() }
    }

    deinit {
        worker?.cancel()
        timer?.invalidate()
    }

    func reload() {
        do {
            binding = try configuration.binding()
            status = try configuration.status().connection
        } catch { self.error = "读取飞书机器人配置失败。" }
    }

    func bind(appID: String, secret: String) {
        guard !busy else { return }
        busy = true
        error = nil
        let configuration = configuration
        Task { @MainActor [weak self] in
            defer { self?.busy = false }
            do {
                try await FeishuBotSetup.validate(appID: appID, secret: secret)
                try configuration.bind(appID: appID, secret: secret)
                self?.reload()
            } catch { self?.error = (error as? FeishuBotError)?.localizedDescription ?? "绑定失败，请检查网络和应用凭据。" }
        }
    }

    func unbind() {
        do {
            try configuration.unbind()
            error = nil
            reload()
        } catch { self.error = "解绑失败，请检查本机配置目录权限。" }
    }

    func renewPairing() {
        do {
            _ = try configuration.renewPairing()
            error = nil
            reload()
        } catch { self.error = error.localizedDescription }
    }

    func setFilter(_ filter: FeishuDashboardFilter) {
        do {
            try configuration.setFilter(filter)
            error = nil
            reload()
        } catch { self.error = error.localizedDescription }
    }
}
