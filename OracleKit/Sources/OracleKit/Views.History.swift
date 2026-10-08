import Foundation

/// Pages visited, like a browser's (Nat: Discord's mouse 4 / 5) — the oracle apps' version of the hub's back/forward.
/// `visit` records the page being left; `goBack` / `goForward` move without being recorded as visits themselves.
/// Pick up and Open session jump from Issues to Work for the agent's pane, so back must land on Issues again (#86).
struct PageHistory<Page: Equatable> {
    private(set) var back: [Page] = []
    private(set) var forward: [Page] = []
    var limit = 50

    /// The human (or Pick up) moved from `old` to `new`: `old` joins the back stack, the forward stack is dropped.
    mutating func visit(from old: Page, to new: Page) {
        guard old != new else { return }
        back.append(old)
        forward = []
        if back.count > limit { back.removeFirst(back.count - limit) }
    }

    /// The page to show instead of `current`, or nil when there is nothing behind it.
    mutating func goBack(from current: Page) -> Page? {
        guard let page = back.popLast() else { return nil }
        forward.append(current)
        return page
    }

    /// The page to show instead of `current`, or nil when nothing was gone back from.
    mutating func goForward(from current: Page) -> Page? {
        guard let page = forward.popLast() else { return nil }
        back.append(current)
        return page
    }
}
