import SwiftUI
#if os(macOS)
import AppKit

/// The pointing-hand cursor over anything clickable (Nat: "if link clickable, open web, show hand cursor").
/// macOS 14 has no `.pointerStyle`, so push/pop — tracked so a view that vanishes under the pointer cannot leave
/// the hand stuck or pop somebody else's cursor.
private struct HandCursor: ViewModifier {
    @State private var inside = false
    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                guard hovering != inside else { return }
                inside = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .onDisappear { if inside { inside = false; NSCursor.pop() } }
    }
}

extension View { func handCursor() -> some View { modifier(HandCursor()) } }
#else
extension View { func handCursor() -> some View { self } }
#endif
