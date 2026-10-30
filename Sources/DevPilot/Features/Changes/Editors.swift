import AppKit

/// An installed app that can open a worktree folder or file.
struct EditorApp: Identifiable, Hashable {
    let bundleID: String
    let name: String
    let url: URL

    var id: String { bundleID }

    /// Known editors, in default-preference order, that are installed on this Mac.
    static func installed() -> [EditorApp] {
        let known = [
            ("com.jetbrains.intellij", "IntelliJ IDEA"),
            ("com.jetbrains.intellij.ce", "IntelliJ IDEA CE"),
            ("com.microsoft.VSCode", "Visual Studio Code"),
            ("com.todesktop.230313mzl4w4u92", "Cursor"),
            ("com.jetbrains.WebStorm", "WebStorm"),
            ("dev.zed.Zed", "Zed"),
        ]
        return known.compactMap { bundleID, name in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { EditorApp(bundleID: bundleID, name: name, url: $0) }
        }
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open([url], withApplicationAt: self.url, configuration: NSWorkspace.OpenConfiguration())
    }
}
