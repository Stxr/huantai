import AppKit
import Combine
import SwiftUI

enum PopoverAppearance {
    static func nativeAppearance(_ value: String) -> NSAppearance? {
        value == "light"
            ? NSAppearance(named: .aqua)
            : value == "dark" ? NSAppearance(named: .darkAqua) : nil
    }
    /// Let NSPopover draw both the arrow and the transparent hosting view's background.
    /// AppKit is the single source of truth; SwiftUI inherits the hosting view's appearance.
    /// Do not also set preferredColorScheme: clearing that preference can leave SwiftUI
    /// using the old scheme while the popover has already restored the system appearance.
    static func bind(
        model: AppModel, popover: NSPopover, controller: NSHostingController<PopoverView>,
        reviewWindow: NSWindow? = nil
    ) -> AnyCancellable {
        model.$appearance.removeDuplicates().sink {
            [weak popover, weak controller, weak reviewWindow] value in
            let appearance = nativeAppearance(value)
            popover?.appearance = appearance
            controller?.view.appearance = appearance
            reviewWindow?.appearance = appearance
        }
    }
}
