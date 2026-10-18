import Foundation

/// Counts only time spent outside the toast, using a monotonic clock.
struct SessionToastLifetime {
    private(set) var remaining: TimeInterval
    private var lastUpdate: TimeInterval
    private var wasHovered: Bool

    init(duration: TimeInterval, now: TimeInterval, hovered: Bool) {
        remaining = duration
        lastUpdate = now
        wasHovered = hovered
    }

    mutating func advance(now: TimeInterval, hovered: Bool) -> Bool {
        // Do not charge the interval containing an enter/exit transition.
        if !hovered && !wasHovered {
            remaining = max(0, remaining - max(0, now - lastUpdate))
        }
        lastUpdate = now
        wasHovered = hovered
        return !hovered && remaining <= 0
    }
}
