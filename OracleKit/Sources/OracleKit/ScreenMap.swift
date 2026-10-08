import CoreGraphics
import Foundation

/// The geometry behind the hub's Screens page (#62), kept pure so it is tested: displays and windows in one
/// global space (top-left origin, y down — the space yabai and CGWindowList use), scaled into a view.
public enum ScreenMap {
    public struct Display: Equatable, Sendable, Identifiable {
        public let id: Int          // CGDirectDisplayID (they reshuffle across reboots — never store one)
        public let name: String     // NSScreen.localizedName, "DELL S2725QS"
        public let frame: CGRect    // top-left global coordinates, points
        public let main: Bool       // the menu-bar screen
        public init(id: Int, name: String, frame: CGRect, main: Bool) { self.id = id; self.name = name; self.frame = frame; self.main = main }
    }

    /// An AppKit frame (bottom-left origin at the main screen, y up) in top-left global coordinates.
    public static func topLeft(_ f: CGRect, mainHeight: CGFloat) -> CGRect {
        CGRect(x: f.minX, y: mainHeight - f.maxY, width: f.width, height: f.height)
    }

    /// The display a window is on: the one holding its centre, else the one it overlaps most, else none.
    public static func display(of r: CGRect, in displays: [Display]) -> Display? {
        let c = CGPoint(x: r.midX, y: r.midY)
        if let d = displays.first(where: { $0.frame.contains(c) }) { return d }
        let best = displays.max { area($0.frame.intersection(r)) < area($1.frame.intersection(r)) }
        return best.flatMap { area($0.frame.intersection(r)) > 0 ? $0 : nil }
    }

    /// Scale and offset that fit every display into `size` with `pad` around, keeping their shapes.
    public static func fit(_ displays: [Display], into size: CGSize, pad: CGFloat = 12) -> (scale: CGFloat, origin: CGPoint) {
        guard let first = displays.first else { return (1, .zero) }
        let box = displays.dropFirst().reduce(first.frame) { $0.union($1.frame) }
        let s = min((size.width - 2 * pad) / max(box.width, 1), (size.height - 2 * pad) / max(box.height, 1))
        return (max(s, 0), CGPoint(x: box.minX, y: box.minY))
    }

    /// A global rectangle in the view, given `fit`'s scale and origin.
    public static func place(_ r: CGRect, scale: CGFloat, origin: CGPoint, pad: CGFloat = 12) -> CGRect {
        CGRect(x: pad + (r.minX - origin.x) * scale, y: pad + (r.minY - origin.y) * scale, width: r.width * scale, height: r.height * scale)
    }

    static func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }
}
