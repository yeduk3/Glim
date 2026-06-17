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
                OpenFileCommand()
            }
            CommandGroup(after: .textEditing) {
                FindCommands()
            }
            CommandGroup(after: .toolbar) {
                ModeCommands()
                Divider()
                FullWidthCommand()
                Divider()
                FontSizeCommands()
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

/// File-menu Open… (⌘O), raising the focused window's quick-open palette to fuzzy-search
/// and open any markdown file under the browsed folder. Disabled when no document is focused.
private struct OpenFileCommand: View {
    @FocusedValue(\.quickOpenAction) private var openAction: (() -> Void)?

    var body: some View {
        Button("Open…") { openAction?() }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(openAction == nil)
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
    @FocusedValue(\.focusSidebarAction) private var focusSidebar: (() -> Void)?

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

        Button("Focus Sidebar") { focusSidebar?() }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(focusSidebar == nil)
    }
}

/// View-menu full-width toggle, synced across the rendered view and raw editor.
/// Off (default) caps the content to a readable centered measure; on fills the width.
private struct FullWidthCommand: View {
    @ObservedObject private var width = FullWidthMode.shared

    var body: some View {
        Toggle("Full Width", isOn: Binding(get: { width.isFullWidth },
                                           set: { _ in width.toggle() }))
            .keyboardShortcut("f", modifiers: [.command, .shift])
    }
}

/// View-menu font zoom, applied app-wide to both the rendered view and raw editor.
/// ⌘+ bigger, ⌘- smaller, ⌘0 reset. (⌘+ is produced by ⌘⇧=; the menu shows "⌘+".)
private struct FontSizeCommands: View {
    @ObservedObject private var font = FontScale.shared

    var body: some View {
        Button("Increase Font Size") { font.zoomIn() }
            .keyboardShortcut("+", modifiers: .command)
        Button("Decrease Font Size") { font.zoomOut() }
            .keyboardShortcut("-", modifiers: .command)
        Button("Actual Size") { font.reset() }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(font.scale == 1.0)
    }
}

enum EditorMode: String { case view, edit }

private struct EditorModeKey: FocusedValueKey { typealias Value = Binding<EditorMode> }
private struct SidebarVisibleKey: FocusedValueKey { typealias Value = Binding<Bool> }
private struct NewFileActionKey: FocusedValueKey { typealias Value = () -> Void }
private struct FocusSidebarActionKey: FocusedValueKey { typealias Value = () -> Void }

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
    var focusSidebarAction: (() -> Void)? {
        get { self[FocusSidebarActionKey.self] }
        set { self[FocusSidebarActionKey.self] = newValue }
    }
}
