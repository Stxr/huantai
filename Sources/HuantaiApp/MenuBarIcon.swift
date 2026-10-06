import AppKit
import Combine
import HuantaiCore

enum MenuBarIconMode: String, CaseIterable, Identifiable {
    case daily, weekly, logo

    var id: String { rawValue }
    var title: String {
        switch self {
        case .daily: return "每日建议额度剩余"
        case .weekly: return "每周额度剩余"
        case .logo: return "原来的 Logo"
        }
    }
    var subtitle: String {
        switch self {
        case .daily: return "圆环显示今日参考，未用额度可结转"
        case .weekly: return "圆环显示整周还剩多少额度"
        case .logo: return "保留换台图标"
        }
    }
}

enum DailyQuotaColor: Equatable {
    case blue, green, red

    var nativeColor: NSColor {
        switch self {
        case .blue: return .systemBlue
        case .green: return .systemGreen
        case .red: return .systemRed
        }
    }
}

struct MenuBarUsageState: Equatable {
    /// nil means unknown; zero means a known exhausted allowance.
    var fraction: Double?
    var isOverBudget = false
    var tooltip: String
    var overBudgetFraction: Double = 0
    var dailyReferenceFraction: Double? = nil
    /// Uncapped daily remainder relative to today's suggested allowance, including carryover.
    var dailyRemainingRatio: Double? = nil

    var displayedPercent: Double? {
        guard let value = dailyRemainingRatio ?? fraction, value.isFinite else { return nil }
        let percent = max(0, value) * 100
        return percent.isFinite ? percent : nil
    }

    var dailyColor: DailyQuotaColor? {
        guard let ratio = dailyRemainingRatio, ratio.isFinite else { return nil }
        // Avoid classifying floating-point residue at exactly 100% or 10% as a different band.
        if ratio > 1 + 1e-10 { return .blue }
        if ratio < 0.1 - 1e-10 { return .red }
        return .green
    }

    static func calculate(
        mode: MenuBarIconMode, usage: UsageSummary, now: Date = Date(), calendar: Calendar = .current
    ) -> Self {
        guard mode != .logo else { return .init(fraction: nil, tooltip: "换台") }
        let title = "换台 · \(mode.title)"
        guard let window = usage.weekly, window.usedPercent.isFinite, window.usedPercent >= 0,
            window.windowDurationMins > 0, window.resetsAt.timeIntervalSince1970.isFinite
        else { return .init(fraction: nil, tooltip: "\(title)\n额度未连接\n\(usage.status)") }
        let duration = Double(window.windowDurationMins) * 60
        let start = window.resetsAt.addingTimeInterval(-duration)
        guard now >= start, now < window.resetsAt else {
            return .init(fraction: nil, tooltip: "\(title)\n等待额度刷新\n\(usage.status)")
        }
        let projection = UsageProjection.calculate(window: window, now: now, calendar: calendar)
        if mode == .weekly {
            let remaining = max(0, 100 - window.usedPercent)
            let budget = projection.todayReferenceBudgetPercent
            let reference = budget.map { min(1, max(0, 1 - $0 / 100)) }
            let over = budget.map { max(0, min(100, window.usedPercent) - $0) / 100 } ?? 0
            let referenceText = reference.map { "\n圆点：今日建议保留 \(percent($0 * 100)) 周额度" } ?? ""
            let overText = over > 1e-10 ? "\n今日超出 \(percent(over * 100)) 周额度" : ""
            return .init(
                fraction: remaining / 100,
                tooltip:
                    "\(title)\n本周剩余 \(percent(remaining))\(referenceText)\(overText)\n\(UsageDate.resetText(resetsAt: window.resetsAt, timeZone: calendar.timeZone))\n\(usage.status)",
                overBudgetFraction: over < 1e-10 ? 0 : over, dailyReferenceFraction: reference
            )
        }
        guard let rawRemaining = projection.todayReferenceRemainingPercent, rawRemaining.isFinite else {
            return .init(fraction: nil, tooltip: "\(title)\n今日参考待更新\n\(usage.status)")
        }
        let remaining = abs(rawRemaining) < 1e-10 ? 0 : rawRemaining
        // Normalize to this natural day's suggested allowance, including partial first/last
        // days. The existing signed remainder carries unspent reference allowance forward.
        guard let day = calendar.dateInterval(of: .day, for: now) else {
            return .init(fraction: nil, tooltip: "\(title)\n今日参考待更新")
        }
        let dayDuration = min(day.end, window.resetsAt).timeIntervalSince(max(day.start, start))
        let dailyAllowance = dayDuration / duration * 100
        guard dailyAllowance > 0 else {
            return .init(fraction: nil, tooltip: "\(title)\n今日参考待更新")
        }
        let ratio = remaining / dailyAllowance
        let fraction = min(1, max(0, ratio))
        let value = remaining < 0 ? "今日超出" : "今日参考剩余"
        let carry = remaining > dailyAllowance ? "\n含结转额度，圆环已满" : ""
        return .init(
            fraction: fraction, isOverBudget: remaining < 0,
            tooltip:
                "\(title)\n每日建议剩余 \(percent(max(0, ratio) * 100))\n\(value) \(percent(abs(remaining))) 周额度\n今日建议量 \(percent(dailyAllowance)) 周额度\(carry)\n\(usage.status)",
            dailyRemainingRatio: ratio
        )
    }

    private static func percent(_ value: Double) -> String {
        value > 0 && value < 0.1 ? "<0.1%" : String(format: "%.1f%%", value)
    }
}

enum MenuBarIcon {
    static let size = NSSize(width: 22, height: 22)
    private static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .semibold)

    struct Labels: Equatable {
        var center: String
        var beside: String
    }

    static func labels(for state: MenuBarUsageState) -> Labels {
        guard let percent = state.displayedPercent else {
            return Labels(center: "?", beside: "")
        }
        let rounded = percent.rounded()
        var number = String(format: "%.0f", rounded)
        // Keep a rounded label from contradicting its color at the two thresholds.
        if state.dailyColor == .blue, rounded <= 100 { number = ">100" }
        if state.dailyColor == .red, rounded >= 10 { number = "<10" }
        if state.isOverBudget { return Labels(center: "!", beside: "\(number)%") }
        let measured = NSAttributedString(string: number, attributes: [.font: numberFont]).size()
        if measured.width <= 10.5, measured.height <= 11 {
            return Labels(center: number, beside: "")
        }
        return Labels(center: "", beside: "\(number)%")
    }

    static func numberTitle(mode: MenuBarIconMode, state: MenuBarUsageState) -> NSAttributedString {
        NSAttributedString(
            string: mode == .logo ? "" : labels(for: state).beside,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.labelColor,
            ])
    }

    static func bind(
        model: AppModel, button: NSStatusBarButton, now: @escaping () -> Date = Date.init,
        calendar: @escaping () -> Calendar = { .current }
    ) -> AnyCancellable {
        // Tick even with the popover closed so a natural-day boundary or reset invalidates
        // the reference. Quota changes still come from the existing real usage snapshots.
        let ticks = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
            .map { _ in () }.prepend(())
        return Publishers.CombineLatest4(
            model.$menuBarIconMode.removeDuplicates(),
            model.$snapshot.map(\.usage).removeDuplicates(), ticks,
            button.publisher(for: \.effectiveAppearance)
        ).sink { [weak button] mode, usage, _, appearance in
            guard let button else { return }
            let state = MenuBarUsageState.calculate(
                mode: mode, usage: usage, now: now(), calendar: calendar())
            button.image = image(mode: mode, state: state, appearance: appearance)
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            button.attributedTitle = numberTitle(mode: mode, state: state)
            button.toolTip = state.tooltip
            button.setAccessibilityLabel(state.tooltip.replacingOccurrences(of: "\n", with: "，"))
        }
    }

    static func image(
        mode: MenuBarIconMode, state: MenuBarUsageState, appearance: NSAppearance = .currentDrawing()
    ) -> NSImage {
        if mode == .logo {
            let logo =
                NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "换台")
                ?? NSImage(size: size)
            logo.isTemplate = true
            return logo
        }
        let image = NSImage(size: size, flipped: false) { _ in
            appearance.performAsCurrentDrawingAppearance {
                let track = NSBezierPath(ovalIn: NSRect(x: 3.5, y: 3.5, width: 15, height: 15))
                track.lineWidth = 2.5
                let redDaily = state.dailyColor == .red
                let trackColor = redDaily ? NSColor.systemRed : .secondaryLabelColor
                trackColor.withAlphaComponent(redDaily ? 0.5 : 0.3).setStroke()
                if state.fraction == nil { track.setLineDash([2, 2], count: 2, phase: 0) }
                track.stroke()
                func arc(from start: Double, to end: Double, color: NSColor) {
                    guard end > start else { return }
                    color.setStroke()
                    let path = NSBezierPath()
                    path.lineWidth = 2.5
                    path.lineCapStyle = .round
                    path.appendArc(
                        withCenter: NSPoint(x: 11, y: 11), radius: 7.5,
                        startAngle: 90 - 360 * CGFloat(start), endAngle: 90 - 360 * CGFloat(end),
                        clockwise: true)
                    path.stroke()
                }
                if let remaining = state.fraction {
                    // Green still encodes remaining quota. Red fills only the consumed
                    // interval beyond today's plan, ending at the reference marker.
                    arc(from: 0, to: remaining, color: state.dailyColor?.nativeColor ?? .systemGreen)
                    arc(
                        from: remaining, to: min(1, remaining + state.overBudgetFraction),
                        color: .systemRed)
                }
                if let reference = state.dailyReferenceFraction {
                    let angle = (90 - 360 * reference) * .pi / 180
                    let point = NSPoint(x: 11 + 9.75 * cos(angle), y: 11 + 9.75 * sin(angle))
                    NSColor.systemBlue.setFill()
                    NSBezierPath(
                        ovalIn: NSRect(x: point.x - 1.25, y: point.y - 1.25, width: 2.5, height: 2.5)
                    )
                    .fill()
                }
                let center = labels(for: state).center
                if !center.isEmpty {
                    let marker = state.fraction == nil || state.isOverBudget
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: marker ? NSFont.systemFont(ofSize: 10, weight: .bold) : numberFont,
                        .foregroundColor: NSColor.labelColor,
                    ]
                    let label = NSAttributedString(string: center, attributes: attributes)
                    let labelSize = label.size()
                    label.draw(at: NSPoint(x: (22 - labelSize.width) / 2, y: (22 - labelSize.height) / 2))
                }
            }
            return true
        }
        // Preserve green/red/blue; the binding follows the actual status-button
        // appearance for neutral text/track colors, independently of popover theme.
        image.isTemplate = false
        image.accessibilityDescription = state.tooltip
        return image
    }
}
