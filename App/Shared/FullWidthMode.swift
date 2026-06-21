import SwiftUI

/// App-wide layout-width toggle shared by the rendered view and the raw editor.
/// A single shared instance so both modes stay in sync and the choice survives
/// across launches (persisted in UserDefaults). Off by default: content is capped
/// to a readable measure and centered; on lets it fill the whole viewport width.
final class FullWidthMode: ObservableObject {
    static let shared = FullWidthMode()

    private static let key = "glim.fullWidth"

    @Published private(set) var isFullWidth: Bool

    private init() {
        isFullWidth = UserDefaults.standard.bool(forKey: Self.key)
    }

    func toggle() { set(!isFullWidth) }

    private func set(_ value: Bool) {
        guard value != isFullWidth else { return }
        isFullWidth = value
        UserDefaults.standard.set(value, forKey: Self.key)
    }
}
