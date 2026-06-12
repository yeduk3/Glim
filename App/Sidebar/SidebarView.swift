import SwiftUI
import UniformTypeIdentifiers

/// Bumped whenever a file is created or trashed so the tree re-reads from disk.
/// Both the root list and every expanded `FileRow` observe it.
final class FileTreeModel: ObservableObject {
    @Published var version = 0
    func reload() { version &+= 1 }
}

struct SidebarView: View {
    let rootURL: URL?
    let currentFile: URL?
    @ObservedObject var tree: FileTreeModel
    @Environment(\.openDocument) private var openDocument

    var body: some View {
        Group {
            if let rootURL {
                List {
                    Section {
                        ForEach(FileEntry.children(of: rootURL)) { entry in
                            FileRow(entry: entry, currentFile: currentFile, tree: tree)
                        }
                    } header: {
                        HStack {
                            Text(rootURL.lastPathComponent.removingPercentEncoding ?? rootURL.lastPathComponent)
                            Spacer()
                            Button { newFile(in: rootURL) } label: {
                                Image(systemName: "doc.badge.plus")
                            }
                            .buttonStyle(.plain)
                            .help("New Markdown File  (⌘N)")
                        }
                    }
                }
                .listStyle(.sidebar)
            } else {
                ContentUnavailableView("No Folder", systemImage: "folder",
                    description: Text("Open a Markdown file to browse its folder."))
            }
        }
        .frame(minWidth: 180)
    }

    private func newFile(in dir: URL) {
        guard let url = FileEntry.makeNewFile(in: dir) else { return }
        tree.reload()
        Task { try? await openDocument(at: url) }
    }
}

private struct FileRow: View {
    let entry: FileEntry
    let currentFile: URL?
    @ObservedObject var tree: FileTreeModel

    @State private var expanded = false
    @State private var children: [FileEntry] = []
    @Environment(\.openDocument) private var openDocument

    var body: some View {
        if entry.isDirectory {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(children) { FileRow(entry: $0, currentFile: currentFile, tree: tree) }
            } label: {
                Label(entry.name, systemImage: "folder")
                    .lineLimit(1)
            }
            .onChange(of: expanded) { _, now in
                if now { children = FileEntry.children(of: entry.url) }
            }
            .onChange(of: tree.version) { _, _ in
                if expanded { children = FileEntry.children(of: entry.url) }
            }
            .contextMenu { rowMenu(newFileTarget: entry.url) }
        } else {
            Button { open() } label: {
                Label {
                    Text(entry.name).lineLimit(1)
                } icon: {
                    Image(systemName: entry.isMarkdown ? "doc.text" : "doc")
                        .foregroundStyle(entry.isMarkdown ? Color.accentColor : Color.secondary)
                }
            }
            .buttonStyle(.plain)
            .fontWeight(isCurrent ? .semibold : .regular)
            .listRowBackground(isCurrent ? Color.accentColor.opacity(0.15) : nil)
            .contextMenu { rowMenu(newFileTarget: entry.url.deletingLastPathComponent()) }
        }
    }

    /// `newFileTarget` is the folder a "New File" here lands in: the directory itself
    /// for a folder row, the containing folder for a file row.
    @ViewBuilder private func rowMenu(newFileTarget: URL) -> some View {
        Button("New File") { newFile(in: newFileTarget) }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
        }
        Divider()
        Button("Move to Trash", role: .destructive) {
            FileEntry.trash(entry.url)
            tree.reload()
        }
    }

    private var isCurrent: Bool {
        guard let currentFile else { return false }
        return entry.url.standardizedFileURL == currentFile.standardizedFileURL
    }

    private func newFile(in dir: URL) {
        guard let url = FileEntry.makeNewFile(in: dir) else { return }
        if entry.isDirectory { expanded = true }
        tree.reload()
        Task { try? await openDocument(at: url) }
    }

    private func open() {
        if entry.isMarkdown {
            Task { try? await openDocument(at: entry.url) }
        } else {
            NSWorkspace.shared.open(entry.url)
        }
    }
}

struct FileEntry: Identifiable {
    let url: URL
    let name: String
    let isDirectory: Bool

    var id: URL { url }

    var isMarkdown: Bool {
        ["md", "markdown", "mdown", "mkd", "mdwn", "mkdn"].contains(url.pathExtension.lowercased())
    }

    static func children(of dir: URL) -> [FileEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .nameKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]) else { return [] }

        return items.compactMap { url -> FileEntry? in
            let vals = try? url.resourceValues(forKeys: Set(keys))
            let isDir = vals?.isDirectory ?? false
            let name = vals?.name ?? url.lastPathComponent
            return FileEntry(url: url, name: name, isDirectory: isDir)
        }
        .sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Creates a unique `Untitled[ N].md` in `dir` and returns it (nil on write failure).
    static func makeNewFile(in dir: URL) -> URL? {
        let fm = FileManager.default
        var url = dir.appendingPathComponent("Untitled.md")
        var i = 2
        while fm.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("Untitled \(i).md")
            i += 1
        }
        do {
            try "".write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    /// Moves `url` to the Trash (reversible, so no confirmation needed).
    static func trash(_ url: URL) {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}
