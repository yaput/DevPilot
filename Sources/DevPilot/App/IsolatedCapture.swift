import AppKit
import DevPilotCore
import SwiftUI

/// Isolated copies only (scripts/run-isolated.sh): `kill -USR1 <pid>` renders a window to a PNG,
/// after optionally selecting a ticket or opening a window, so UI changes can be checked without
/// screen-recording permission. The request is `capture-request.json` in the data directory:
///
///     {"out": "/path/shot.png", "ticket": "DP-1", "window": "dashboard", "width": 1400, "height": 900}
///
/// `window` is "dashboard" (default), "changes" (of `ticket`), "settings" or "menubar". Optional
/// `messages` are posted first, to see the banners.
@MainActor
enum IsolatedCapture {
    private static var signalSource: DispatchSourceSignal?
    /// Set by the dashboard, which has the environment's window and settings openers.
    static var openWindow: OpenWindowAction?
    static var openSettings: OpenSettingsAction?

    private struct Request: Decodable {
        var out: String
        var ticket: String?
        var window: String?
        var width: Double?
        var height: Double?
        var messages: [String]?
    }

    static func install(model: AppModel) {
        guard AppDatabase.isIsolated, signalSource == nil else { return }
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                Task { await capture(model: model) }
            }
        }
        source.resume()
        signalSource = source
    }

    private static func capture(model: AppModel) async {
        let requestURL = AppDatabase.defaultDirectory.appending(path: "capture-request.json")
        guard let data = try? Data(contentsOf: requestURL),
              let request = try? JSONDecoder().decode(Request.self, from: data) else { return }
        let ticket = request.ticket.flatMap { key in
            (model.tickets + model.unfollowedTickets).first { $0.id == key || $0.externalID == key }
        }
        let kind = request.window ?? "dashboard"
        request.messages?.forEach { model.lastError = $0 }
        if kind != "changes", let ticket { model.selectedTicketID = ticket.id }

        var rep: NSBitmapImageRep?
        switch kind {
        case "menubar":
            try? await Task.sleep(for: .milliseconds(300))
            let renderer = ImageRenderer(content: MenuBarView().environment(model).background(.background))
            renderer.scale = 2
            rep = renderer.cgImage.map(NSBitmapImageRep.init(cgImage:))
        default:
            if kind == "changes", let ticket {
                openWindow?(id: AppWindow.changes, value: ticket.id)
            } else if kind == "settings" {
                openSettings?()
            }
            try? await Task.sleep(for: .milliseconds(kind == "dashboard" ? 300 : 900))
            guard let window = target(kind) else { return }
            if let width = request.width, let height = request.height {
                window.setContentSize(NSSize(width: width, height: height))
            }
            // Let lists, async loads and animations settle.
            try? await Task.sleep(for: .milliseconds(900))
            guard let view = window.contentView?.superview ?? window.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            rep = bitmap
        }
        try? rep?.representation(using: .png, properties: [:])?.write(to: URL(filePath: request.out))
    }

    private static func target(_ kind: String) -> NSWindow? {
        let windows = NSApp.orderedWindows.filter { $0.isVisible && $0.styleMask.contains(.titled) }
        switch kind {
        case "changes": return windows.first { $0.title.hasPrefix("Changes") }
        // The settings window is titled after its selected tab.
        case "settings": return windows.first { $0.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true } ?? windows.first
        default: return windows.first { $0.title == "DevPilot" } ?? windows.max { $0.frame.width < $1.frame.width }
        }
    }
}
