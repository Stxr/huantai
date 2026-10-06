import AppKit
import HuantaiCore
import XCTest

@testable import HuantaiApp

final class MenuBarIconTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private func date(_ day: Int, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }
    private func usage(_ used: Double, reset: Date? = nil) -> UsageSummary {
        UsageSummary(
            weekly: UsageWindow(
                usedPercent: used, windowDurationMins: 10080, resetsAt: reset ?? date(8)),
            status: "合成额度", source: "synthetic")
    }
    private func state(_ mode: MenuBarIconMode, _ usage: UsageSummary, now: Date? = nil)
        -> MenuBarUsageState
    {
        .calculate(mode: mode, usage: usage, now: now ?? date(3, hour: 12), calendar: calendar)
    }

    func testWeeklyRingUsesRemainingAndDistinguishesExhaustedFromUnknown() throws {
        XCTAssertEqual(try XCTUnwrap(state(.weekly, usage(75)).fraction), 0.25, accuracy: 0.0001)
        XCTAssertEqual(state(.weekly, usage(100)).fraction, 0)
        XCTAssertEqual(state(.weekly, usage(130)).fraction, 0)
        XCTAssertNil(state(.weekly, UsageSummary()).fraction)
        for invalid in [Double.nan, .infinity, -1] {
            XCTAssertNil(state(.weekly, usage(invalid)).fraction)
        }
        XCTAssertNil(state(.weekly, usage(75), now: date(8)).fraction)
        XCTAssertNil(state(.weekly, usage(75), now: date(1).addingTimeInterval(-1)).fraction)
    }

    func testDailyRingNormalizesToSuggestedDayAndPreservesCarryoverAndOverage() throws {
        let allowance = 100.0 / 7
        let budget = allowance * 3
        let half = state(.daily, usage(budget - allowance / 2))
        XCTAssertEqual(try XCTUnwrap(half.fraction), 0.5, accuracy: 0.0001)
        XCTAssertTrue(half.tooltip.contains("今日参考剩余 7.1% 周额度"))
        XCTAssertEqual(state(.daily, usage(0)).fraction, 1)
        XCTAssertTrue(state(.daily, usage(0)).tooltip.contains("含结转额度"))
        let zero = state(.daily, usage(budget))
        XCTAssertEqual(try XCTUnwrap(zero.fraction), 0, accuracy: 0.0001)
        XCTAssertFalse(zero.isOverBudget)
        let over = state(.daily, usage(budget + 0.001))
        XCTAssertEqual(over.fraction, 0)
        XCTAssertTrue(over.isOverBudget)
        XCTAssertTrue(over.tooltip.contains("今日超出 <0.1%"))
    }

    func testDailyRingHandlesPartialDaysNaturalDayChangeAndExpiredWindow() throws {
        let reset = date(8, hour: 12)
        let halfDayAllowance = 100.0 / 14
        let first = state(.daily, usage(halfDayAllowance / 2, reset: reset), now: date(1, hour: 18))
        XCTAssertEqual(try XCTUnwrap(first.fraction), 0.5, accuracy: 0.0001)
        let last = state(.daily, usage(100 - halfDayAllowance / 2, reset: reset), now: date(8, hour: 6))
        XCTAssertEqual(try XCTUnwrap(last.fraction), 0.5, accuracy: 0.0001)
        let unchangedUsage = usage(100.0 / 7 * 3)
        XCTAssertEqual(try XCTUnwrap(state(.daily, unchangedUsage).fraction), 0, accuracy: 0.0001)
        XCTAssertEqual(
            try XCTUnwrap(state(.daily, unchangedUsage, now: date(4)).fraction), 1, accuracy: 0.0001)
        XCTAssertNil(state(.daily, unchangedUsage, now: date(8)).fraction)
        XCTAssertNil(state(.daily, UsageSummary()).fraction)
    }

    func testWeeklyOverageOccupiesOnlyConsumedIntervalUpToDayEndMarker() throws {
        let before = state(.weekly, usage(25))
        let reference = 4.0 / 7
        XCTAssertEqual(before.fraction, 0.75)
        XCTAssertEqual(before.overBudgetFraction, 0)
        XCTAssertEqual(try XCTUnwrap(before.dailyReferenceFraction), reference, accuracy: 0.0001)
        let over = state(.weekly, usage(60))
        XCTAssertEqual(try XCTUnwrap(over.fraction), 0.4, accuracy: 0.0001)
        XCTAssertEqual(over.overBudgetFraction, reference - 0.4, accuracy: 0.0001)
        XCTAssertEqual(
            try XCTUnwrap(over.fraction) + over.overBudgetFraction,
            try XCTUnwrap(over.dailyReferenceFraction), accuracy: 0.0001)
        XCTAssertEqual(state(.weekly, usage(130)).overBudgetFraction, reference, accuracy: 0.0001)
        let nextDay = state(.weekly, usage(60), now: date(4))
        XCTAssertEqual(try XCTUnwrap(nextDay.dailyReferenceFraction), 3.0 / 7, accuracy: 0.0001)
        XCTAssertLessThan(nextDay.overBudgetFraction, over.overBudgetFraction)
        XCTAssertNil(state(.weekly, usage(60), now: date(8)).dailyReferenceFraction)
        XCTAssertNil(state(.weekly, UsageSummary()).dailyReferenceFraction)
        XCTAssertNil(state(.daily, usage(25)).dailyReferenceFraction)
    }

    func testDailyUncappedNumberAndColorBandsUseActualRatioAtTenAndHundredPercent() throws {
        let allowance = 100.0 / 7
        for (ratio, expected): (Double, DailyQuotaColor) in [
            (-0.5, .red), (0, .red), (0.05, .red), (0.0999, .red), (0.1, .green),
            (0.5, .green), (0.9999, .green), (1, .green), (1.001, .blue), (1.5, .blue), (3, .blue),
        ] {
            let value = state(.daily, usage(allowance * (3 - ratio)))
            XCTAssertEqual(try XCTUnwrap(value.dailyRemainingRatio), ratio, accuracy: 0.0001)
            XCTAssertEqual(try XCTUnwrap(value.displayedPercent), max(0, ratio) * 100, accuracy: 0.0001)
            XCTAssertEqual(try XCTUnwrap(value.fraction), min(1, max(0, ratio)), accuracy: 0.0001)
            XCTAssertEqual(value.dailyColor, expected)
        }
        let carry = state(.daily, usage(0))
        XCTAssertEqual(MenuBarIcon.labels(for: carry).beside, "300%")
        XCTAssertEqual(MenuBarIcon.labels(for: state(.daily, usage(allowance * 1.5))).beside, "150%")
        XCTAssertEqual(MenuBarIcon.labels(for: state(.daily, usage(allowance * 2))).beside, "100%")
        XCTAssertEqual(MenuBarIcon.labels(for: state(.daily, usage(allowance * 1.999))).beside, ">100%")
        XCTAssertEqual(MenuBarIcon.labels(for: state(.daily, usage(allowance * 2.9001))).beside, "<10%")
        XCTAssertNil(state(.daily, UsageSummary()).dailyColor)
        XCTAssertNil(state(.weekly, usage(0)).dailyRemainingRatio)
    }

    @MainActor
    func testSettingPersistsAndStatusButtonUpdatesWithoutOpeningPopover() throws {
        let suite = "huantai.menu-bar.fixture." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set("invalid", forKey: "menuBarIconMode")
        let model = AppModel(startServices: false, preferences: preferences)
        XCTAssertEqual(model.menuBarIconMode, .daily)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let button = try XCTUnwrap(item.button)
        let binding = MenuBarIcon.bind(
            model: model, button: button, now: { self.date(3, hour: 12) }, calendar: { self.calendar })
        withExtendedLifetime(binding) {
            XCTAssertTrue(button.toolTip?.contains("额度未连接") == true)
            model.snapshot.usage = usage(0)
            model.setMenuBarIconMode(.weekly)
            XCTAssertEqual(button.title, "100%")
            model.snapshot.usage = usage(75)
            XCTAssertEqual(button.title, "25%")
            XCTAssertTrue(button.toolTip?.contains("本周剩余 25.0%") == true)
            XCTAssertEqual(button.image?.size, MenuBarIcon.size)
            model.snapshot.usage = usage(90)
            XCTAssertTrue(button.toolTip?.contains("本周剩余 10.0%") == true)
            model.snapshot.usage = usage(91)
            XCTAssertEqual(button.title, "")
            XCTAssertEqual(MenuBarIcon.labels(for: state(.weekly, usage(91))).center, "9")
            XCTAssertTrue(button.image?.isTemplate == false)
            let oldImage = button.image
            button.appearance = NSAppearance(named: .darkAqua)
            XCTAssertFalse(button.image === oldImage, "菜单栏外观变化应重绘彩色图像的中性色")
            model.snapshot.usage = usage(0)
            model.setMenuBarIconMode(.logo)
            XCTAssertEqual(button.title, "")
            XCTAssertEqual(button.toolTip, "换台")
            XCTAssertTrue(button.image?.isTemplate == true)
            XCTAssertEqual(AppModel(startServices: false, preferences: preferences).menuBarIconMode, .logo)
            model.setMenuBarIconMode(.daily)
            XCTAssertEqual(AppModel(startServices: false, preferences: preferences).menuBarIconMode, .daily)
            XCTAssertEqual(button.title, "300%")
            XCTAssertEqual(
                button.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                .labelColor)
            model.snapshot.usage = usage(100.0 / 7 * 2.5)
            XCTAssertEqual(button.title, "50%")
            XCTAssertEqual(
                button.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                .labelColor)
            model.snapshot.usage = usage(100.0 / 7 * 2.9001)
            XCTAssertEqual(button.title, "<10%")
            XCTAssertEqual(
                button.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                .labelColor)
            model.setMenuBarIconMode(.weekly)
            XCTAssertEqual(
                button.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                .labelColor)
        }
    }

    func testSimpleNumbersFitInsideRingAndLongNumbersFallBackToBeside() {
        XCTAssertEqual(MenuBarIcon.labels(for: state(.weekly, usage(31))), .init(center: "", beside: "69%"))
        XCTAssertEqual(MenuBarIcon.labels(for: state(.weekly, usage(91))), .init(center: "9", beside: ""))
        XCTAssertEqual(MenuBarIcon.labels(for: state(.weekly, usage(100))), .init(center: "0", beside: ""))
        XCTAssertEqual(MenuBarIcon.labels(for: state(.weekly, usage(0))), .init(center: "", beside: "100%"))
        XCTAssertEqual(MenuBarIcon.labels(for: state(.daily, usage(100))), .init(center: "!", beside: "0%"))
        XCTAssertEqual(MenuBarIcon.labels(for: state(.daily, UsageSummary())), .init(center: "?", beside: ""))
    }

    @MainActor
    func testMenuBarImagesRenderAtNativeSizeInAllStates() throws {
        let cases: [(String, MenuBarIconMode, MenuBarUsageState)] = [
            ("full", .weekly, state(.weekly, usage(0))),
            ("half", .weekly, state(.weekly, usage(50))),
            ("quarter", .weekly, state(.weekly, usage(75))),
            ("empty", .weekly, state(.weekly, usage(100))),
            ("over", .daily, state(.daily, usage(100))),
            ("unknown", .daily, state(.daily, UsageSummary())),
            ("daily150", .daily, state(.daily, usage(100.0 / 7 * 1.5))),
            ("daily100", .daily, state(.daily, usage(100.0 / 7 * 2))),
            ("daily10", .daily, state(.daily, usage(100.0 / 7 * 2.9))),
            ("daily5", .daily, state(.daily, usage(100.0 / 7 * 2.95))),
        ]
        var greenCounts: [String: Int] = [:]
        var redCounts: [String: Int] = [:]
        var markerCounts: [String: Int] = [:]
        for (name, mode, state) in cases {
            let image = MenuBarIcon.image(mode: mode, state: state, appearance: NSAppearance(named: .aqua)!)
            XCTAssertEqual(image.size, MenuBarIcon.size)
            XCTAssertFalse(image.isTemplate)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
            greenCounts[name] = (0..<bitmap.pixelsHigh).reduce(0) { count, y in
                count
                    + (0..<bitmap.pixelsWide).filter {
                        guard let color = bitmap.colorAt(x: $0, y: y)?.usingColorSpace(.deviceRGB) else {
                            return false
                        }
                        return color.alphaComponent > 0.75 && color.greenComponent > color.redComponent * 1.4
                            && color.greenComponent > color.blueComponent * 1.4
                    }.count
            }
            let colors = (0..<bitmap.pixelsHigh).flatMap { y in
                (0..<bitmap.pixelsWide).compactMap {
                    bitmap.colorAt(x: $0, y: y)?.usingColorSpace(.deviceRGB)
                }
            }.filter { $0.alphaComponent > 0.75 }
            redCounts[name] =
                colors.filter {
                    $0.redComponent > $0.greenComponent * 1.8 && $0.redComponent > $0.blueComponent * 1.4
                }.count
            markerCounts[name] =
                colors.filter {
                    $0.blueComponent > $0.redComponent * 1.4 && $0.blueComponent > $0.greenComponent * 1.4
                }.count
            if let directory = ProcessInfo.processInfo.environment["HUANTAI_RENDER_MENU_BAR_DIR"] {
                let url = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: url.appendingPathComponent("ring-\(name).png"))
            }
        }
        XCTAssertGreaterThan(try XCTUnwrap(greenCounts["full"]), try XCTUnwrap(greenCounts["half"]))
        XCTAssertGreaterThan(try XCTUnwrap(greenCounts["half"]), try XCTUnwrap(greenCounts["quarter"]))
        XCTAssertGreaterThan(try XCTUnwrap(greenCounts["quarter"]), try XCTUnwrap(greenCounts["empty"]))
        XCTAssertEqual(redCounts["full"], 0)
        XCTAssertGreaterThan(try XCTUnwrap(redCounts["half"]), 0)
        XCTAssertGreaterThan(try XCTUnwrap(redCounts["quarter"]), try XCTUnwrap(redCounts["half"]))
        XCTAssertGreaterThan(try XCTUnwrap(redCounts["empty"]), try XCTUnwrap(redCounts["quarter"]))
        for name in ["full", "half", "quarter", "empty"] {
            XCTAssertGreaterThan(try XCTUnwrap(markerCounts[name]), 0)
        }
        XCTAssertEqual(markerCounts["unknown"], 0)
        XCTAssertEqual(markerCounts["over"], 0)
        XCTAssertGreaterThan(try XCTUnwrap(markerCounts["daily150"]), 0)
        XCTAssertEqual(greenCounts["daily150"], 0)
        XCTAssertEqual(redCounts["daily150"], 0)
        XCTAssertGreaterThan(try XCTUnwrap(greenCounts["daily100"]), 0)
        XCTAssertGreaterThan(try XCTUnwrap(greenCounts["daily10"]), 0)
        XCTAssertEqual(greenCounts["daily5"], 0)
        XCTAssertGreaterThan(try XCTUnwrap(redCounts["daily5"]), 0)
        if let directory = ProcessInfo.processInfo.environment["HUANTAI_RENDER_MENU_BAR_DIR"] {
            let width = CGFloat(cases.count * 84)
            let preview = NSImage(size: NSSize(width: width, height: 120), flipped: false) { _ in
                for (row, theme) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
                    let offset = CGFloat(row * 60)
                    let foreground: NSColor = row == 0 ? .black : .white
                    (row == 0 ? NSColor.white : NSColor(white: 0.12, alpha: 1)).setFill()
                    NSRect(x: 0, y: offset, width: width, height: 60).fill()
                    for (index, entry) in cases.enumerated() {
                        let icon = MenuBarIcon.image(
                            mode: entry.1, state: entry.2, appearance: NSAppearance(named: theme)!)
                        icon.draw(
                            in: NSRect(x: CGFloat(index * 84 + 12), y: offset + 30, width: 22, height: 22))
                        NSAppearance(named: theme)!.performAsCurrentDrawingAppearance {
                            let beside = MenuBarIcon.numberTitle(mode: entry.1, state: entry.2)
                            beside.draw(
                                at: NSPoint(
                                    x: CGFloat(index * 84 + 37), y: offset + 41 - beside.size().height / 2))
                        }
                        let label = NSAttributedString(
                            string: entry.0,
                            attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: foreground])
                        label.draw(
                            at: NSPoint(x: CGFloat(index * 84) + (84 - label.size().width) / 2, y: offset + 8)
                        )
                    }
                }
                return true
            }
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(preview.tiffRepresentation)))
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("ring-states.png"))
        }
    }
}
