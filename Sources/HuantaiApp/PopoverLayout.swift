import AppKit

enum PopoverLayout {
    static let preferredSize = NSSize(width: 430, height: 560)
    static let screenMargin: CGFloat = 12
    static let chromeAllowance: CGFloat = 20

    static func contentSize(visibleFrame: NSRect, anchor: NSRect) -> NSSize {
        let availableHeight =
            min(visibleFrame.maxY, anchor.minY) - visibleFrame.minY
            - screenMargin - chromeAllowance
        return NSSize(
            width: min(preferredSize.width, max(1, visibleFrame.width - 2 * screenMargin)),
            height: min(preferredSize.height, max(1, availableHeight)))
    }

    /// NSPopover's preferred edge follows the positioning view's coordinate system.
    static func bottomEdge(isFlipped: Bool) -> NSRectEdge {
        isFlipped ? .maxY : .minY
    }
}
