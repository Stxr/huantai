import AppKit
import SwiftUI

struct CLISettingsView: View {
    @State private var status = ""
    @State private var busy = false
    private var installer: URL? { Bundle.main.url(forResource: "install-cli", withExtension: "sh") }
    private var command: String {
        let path = installer?.path ?? "/Applications/换台.app/Contents/Resources/install-cli.sh"
        return "/bin/bash '" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("命令行工具").font(.system(size: 13, weight: .semibold))
            Text("将 ht 安装到 ~/.local/bin，并配置终端 PATH。无需管理员权限，随 App 升级。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(busy ? "安装中…" : "安装 / 检查 ht") { install() }
                    .disabled(busy || installer == nil)
                Button("复制安装命令") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    status = "已复制。粘贴到终端执行即可安装。"
                }
            }
            Text("安装后新开终端，运行 ht --help。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if !status.isEmpty {
                Text(status).font(.system(size: 11)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private func install() {
        guard let installer else { return }
        busy = true
        Task {
            let message = await Task.detached(priority: .userInitiated) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = [installer.path]
                let output = Pipe()
                process.standardOutput = output
                process.standardError = output
                do {
                    try process.run()
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let text = String(decoding: data, as: UTF8.self)
                    return process.terminationStatus == 0 ? text : "安装未完成：\n" + text
                } catch { return "安装未完成：\(error.localizedDescription)" }
            }.value
            status = message
            busy = false
        }
    }
}
