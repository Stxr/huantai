import HuantaiCore
import SwiftUI

struct RemoteConnectionsView: View {
    @ObservedObject var model: AppModel
    @State private var editingID: String?
    @State private var name = ""
    @State private var host = ""
    @State private var root = "~/.codex"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("远端 Codex", systemImage: "network")
                .font(.system(size: 12, weight: .medium))
            Text("独立于本机来源，通过 SSH 只读同步。主机可填写 SSH 配置别名或 user@host；远端需有 python3，并支持免交互登录。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(model.sourceConfiguration.remoteTargets) { target in
                targetRow(target)
            }
            TextField("名称", text: $name).accessibilityLabel("远端名称")
            TextField("SSH 主机（user@host 或别名）", text: $host).accessibilityLabel("SSH 主机")
            TextField("远端 Codex 数据目录", text: $root).accessibilityLabel("远端 Codex 数据目录")
            Text("~ 表示远端用户主目录；每 30 秒同步，断线保留缓存。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                if editingID != nil {
                    Button("取消编辑") { clearEditor() }
                }
                Button(editingID == nil ? "添加远端" : "保存修改") {
                    model.saveRemoteTarget(id: editingID, name: name, host: host, root: root)
                }
                .disabled(
                    model.savingSourceConfiguration
                        || [name, host, root].contains {
                            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        })
            }
        }
    }

    private func targetRow(_ target: RemoteTarget) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(target.name).font(.system(size: 12, weight: .medium))
                Text(target.host + " · " + target.sessionRoot)
                    .font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            Button("编辑") {
                editingID = target.id
                name = target.name
                host = target.host
                root = target.sessionRoot
            }.disabled(model.savingSourceConfiguration)
            Button("移除") {
                model.removeRemoteTarget(id: target.id)
                if editingID == target.id { clearEditor() }
            }.disabled(model.savingSourceConfiguration)
        }
    }

    private func clearEditor() {
        editingID = nil
        name = ""
        host = ""
        root = "~/.codex"
    }
}
