import AppKit
import XCTest

@testable import HuantaiApp

final class TextEditingMenuTests: XCTestCase {
    @MainActor
    func testEditingShortcutsDispatchStandardTextActions() throws {
        let application = NSApplication.shared
        let previousMenu = application.mainMenu
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        applicationItem.submenu = NSMenu(title: "Test")
        menu.addItem(applicationItem)
        menu.addItem(TextEditingMenu.makeItem())
        application.mainMenu = menu
        let editor = RecordingTextView()
        // XCTest has no active application window. Bind a recipient explicitly after
        // checking that production items use the focused responder (a nil target).
        for item in try XCTUnwrap(menu.items.last?.submenu).items where !item.isSeparatorItem {
            XCTAssertNil(item.target)
            item.target = editor
        }
        defer { application.mainMenu = previousMenu }

        for (key, code, action) in [("c", UInt16(8), "copy"), ("v", 9, "paste"),
                                    ("x", 7, "cut"), ("a", 0, "selectAll")] {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: 0, windowNumber: 0, context: nil,
                characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
            XCTAssertTrue(menu.performKeyEquivalent(with: event), key)
            XCTAssertEqual(editor.lastAction, action)
        }
    }
}

private final class RecordingTextView: NSTextView {
    var lastAction: String?
    override func copy(_ sender: Any?) { lastAction = "copy" }
    override func paste(_ sender: Any?) { lastAction = "paste" }
    override func cut(_ sender: Any?) { lastAction = "cut" }
    override func selectAll(_ sender: Any?) { lastAction = "selectAll" }
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { true }
}
