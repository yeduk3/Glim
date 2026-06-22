import SwiftUI

/// Slim find bar shown above the detail view. Drives whichever view is active
/// (rendered or raw) through the shared `FindController`.
struct FindBar: View {
    @ObservedObject var find: FindController
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))

            TextField("Find in file", text: $find.query)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { find.next() }
                .frame(minWidth: 120, maxWidth: 280)

            if !find.status.isEmpty {
                Text(find.status)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            Divider().frame(height: 14)

            Toggle(isOn: $find.caseSensitive) {
                Text("Aa").font(.system(size: 11, weight: .semibold))
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Match case")

            Button { find.prev() } label: { Image(systemName: "chevron.up") }
                .help("Previous match (⇧⌘G)")
            Button { find.next() } label: { Image(systemName: "chevron.down") }
                .help("Next match (⌘G)")
            Button { find.hide() } label: { Image(systemName: "xmark.circle.fill") }
                .help("Close (Esc)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .onAppear { focused = true }
        .onChange(of: find.isVisible) { _, vis in if vis { focused = true } }
        .onChange(of: find.focusPulse) { _, _ in focused = true } // ⌘F-again refocuses
        .onExitCommand { find.hide() }
    }
}
