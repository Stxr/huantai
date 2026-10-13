import SwiftUI

struct SessionRecencyView: View {
    @ObservedObject var model: AppModel

    private var selection: Binding<Double> {
        Binding(
            get: { Double(SessionRecency.allCases.firstIndex(of: model.sessionRecency) ?? 3) },
            set: { model.setSessionRecency(SessionRecency.allCases[Int($0.rounded())]) })
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(model.sessionRecency.title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Spacer()
                Button {
                    model.setSessionRecency(.all)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.plain)
                .help("恢复所有消息")
                .accessibilityLabel("恢复所有消息")
            }
            Slider(value: selection, in: 0...3, step: 1)
                .tint(.accentColor)
                .accessibilityLabel("消息时间范围")
                .accessibilityValue(model.sessionRecency.title)
                .accessibilityIdentifier("session-recency-slider")
            HStack {
                ForEach(SessionRecency.allCases, id: \.self) { option in
                    if option != .day { Spacer() }
                    Button(option.label) { model.setSessionRecency(option) }
                        .buttonStyle(.plain)
                        .foregroundStyle(
                            option == model.sessionRecency ? Color.accentColor : .secondary
                        )
                        .accessibilityAddTraits(option == model.sessionRecency ? .isSelected : [])
                }
            }
            .font(.system(size: 11))
            Text("按最后一条 AI 回复时间筛选")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }
}
