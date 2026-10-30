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

    /// Opens a file at a line through the editor's URL scheme (`idea://`, `vscode://`), falling
    /// back to just opening the file.
    func open(_ file: URL, line: Int) {
        let path = file.path
        // Strict: `&`, `?`, `#` etc. in a path must not break the link.
        let encoded = path.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "/-._~").union(.alphanumerics)) ?? path
        let link: String? = switch bundleID {
        case "com.jetbrains.intellij", "com.jetbrains.intellij.ce": "idea://open?file=\(encoded)&line=\(line)"
        case "com.jetbrains.WebStorm": "webstorm://open?file=\(encoded)&line=\(line)"
        case "com.microsoft.VSCode": "vscode://file\(encoded):\(line)"
        case "com.todesktop.230313mzl4w4u92": "cursor://file\(encoded):\(line)"
        case "dev.zed.Zed": "zed://file\(encoded):\(line)"
        default: nil
        }
        if line > 0, let link, let url = URL(string: link), NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else {
            open(file)
        }
    }
}
