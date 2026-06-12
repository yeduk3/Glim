import SwiftUI
import AppKit

@main
struct qmdApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: MarkdownDocument()) { config in
            ContentView(document: config.$document, fileURL: config.fileURL)
        }
        // NOTE: no .defaultSize — SwiftUI re-applies it after a tab is added,
        // snapping the group back to the default size. Window sizing is managed
        // manually in ContentView's WindowAccessor (cached size, default fallback).
        .commands {
            CommandGroup(replacing: .newItem) {
                NewFileCommands()
            }
            CommandGroup(after: .textEditing) {
                FindCommands()
            }
            CommandGroup(after: .toolbar) {
                ModeCommands()
            }
            CommandGroup(after: .windowArrangement) {
                TabCommands()
            }
        }
    }
}

/// Window-menu items for native tab navigation:
/// ⌘⌥← / ⌘⌥→ previous/next tab, ⌘1…⌘9 jump to the Nth tab.
private struct TabCommands: View {
    var body: some View {
        Divider()
        Button("Show Previous Tab") { NSApp.keyWindow?.selectPreviousTab(nil) }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
        Button("Show Next Tab") { NSApp.keyWindow?.selectNextTab(nil) }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
        Divider()
        ForEach(1...9, id: \.self) { i in
            Button("Show Tab \(i)") { selectTab(i - 1) }
                .keyboardShortcut(KeyEquivalent(Character(String(i))), modifiers: .command)
        }
    }

    private func selectTab(_ index: Int) {
        guard let group = NSApp.keyWindow?.tabGroup,
              index < group.windows.count else { return }
        group.selectedWindow = group.windows[index]
    }
}

/// File-menu New, replacing the default. When a document window is focused it creates
/// a new markdown file in that file's folder and opens it as a tab; otherwise it falls
/// back to a fresh untitled document so ⌘N always does something.
private struct NewFileCommands: View {
    @FocusedValue(\.newFileAction) private var newFile: (() -> Void)?

    var body: some View {
        Button("New") {
            if let newFile { newFile() }
            else { NSDocumentController.shared.newDocument(nil) }
        }
        .keyboardShortcut("n", modifiers: .command)
    }
}

/// Edit-menu Find items wired to the focused window's find controller.
private struct FindCommands: View {
    @FocusedValue(\.findController) private var find: FindController?

    var body: some View {
        Button("Find…") { find?.show() }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(find == nil)
        Button("Find Next") { find?.next() }
            .keyboardShortcut("g", modifiers: .command)
            .disabled(find == nil)
        Button("Find Previous") { find?.prev() }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(find == nil)
    }
}

/// View-menu items wired to the focused window's mode / sidebar bindings.
private struct ModeCommands: View {
    @FocusedBinding(\.editorMode) private var mode: EditorMode?
    @FocusedBinding(\.sidebarVisible) private var sidebarVisible: Bool?

    var body: some View {
        Button(mode == .edit ? "Switch to View" : "Switch to Edit") {
            mode = (mode == .edit) ? .view : .edit
        }
        .keyboardShortcut("e", modifiers: .command)
        .disabled(mode == nil)

        Button("Toggle Sidebar") {
            if let v = sidebarVisible { sidebarVisible = !v }
        }
        .keyboardShortcut("\\", modifiers: .command)
        .disabled(sidebarVisible == nil)
    }
}

enum EditorMode: String { case view, edit }

private struct EditorModeKey: FocusedValueKey { typealias Value = Binding<EditorMode> }
private struct SidebarVisibleKey: FocusedValueKey { typealias Value = Binding<Bool> }
private struct NewFileActionKey: FocusedValueKey { typealias Value = () -> Void }

extension FocusedValues {
    var editorMode: Binding<EditorMode>? {
        get { self[EditorModeKey.self] }
        set { self[EditorModeKey.self] = newValue }
    }
    var sidebarVisible: Binding<Bool>? {
        get { self[SidebarVisibleKey.self] }
        set { self[SidebarVisibleKey.self] = newValue }
    }
    var newFileAction: (() -> Void)? {
        get { self[NewFileActionKey.self] }
        set { self[NewFileActionKey.self] = newValue }
    }
}
