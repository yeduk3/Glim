import SwiftUI

/// App-wide toggle for the outline inspector panel (A2), shared across tabs/windows so the
/// choice is one source of truth and survives across launches (persisted in UserDefaults),
/// mirroring FullWidthMode. Off by default. ⌃⌘1 / the View menu flip it.
final class OutlineVisibility: ObservableObject {
    static let shared = OutlineVisibility()

    private static let key = "glim.outlineVisible"

    @Published var isVisible: Bool {
        didSet {
            guard isVisible != oldValue else { return }
            UserDefaults.standard.set(isVisible, forKey: Self.key)
        }
    }

    private init() {
        isVisible = UserDefaults.standard.bool(forKey: Self.key)
    }

    func toggle() { isVisible.toggle() }
}
