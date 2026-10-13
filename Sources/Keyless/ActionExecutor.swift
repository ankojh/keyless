import AppKit
import ApplicationServices
import KeylessCore

/// Runs desktop actions and checks an observable postcondition before reporting success.
/// Commands outside the supported set are refused plainly rather than guessed at.
@MainActor
final class ActionExecutor {
    /// Bumped by cancel; an action that finishes under an older generation reports nothing.
    private(set) var generation = 0

    func cancelAll() {
        generation += 1
    }

    /// Returns nil on verified success, or a problem worth telling the user about.
    func perform(_ command: Command) async -> String? {
        let started = generation
        switch command {
        case .openApp(let name):
            guard let url = Self.findApplication(named: name) else { return "I couldn't find an app called \(name)." }
            return await activate(url: url, name: name, generation: started).problem

        case .newTab(let app):
            let target: NSRunningApplication
            if let app {
                guard let url = Self.findApplication(named: app) else { return "I couldn't find an app called \(app)." }
                let result = await activate(url: url, name: app, generation: started)
                guard let running = result.app else { return result.problem }
                target = running
            } else {
                guard let front = Self.frontmostOtherApp() else { return "There's no app in front to open a tab in." }
                target = front
            }
            guard generation == started else { return nil }
            return pressMenuItem(["New Tab"], in: target)

        case .closeTab:
            guard let front = Self.frontmostOtherApp() else { return "There's no app in front." }
            return pressMenuItem(["Close Tab"], in: front)

        case .closeWindow:
            guard let front = Self.frontmostOtherApp() else { return "There's no app in front." }
            return pressMenuItem(["Close Window", "Close"], in: front)

        case .quitApp(let name):
            return await quit(named: name, generation: started)

        default:
            return "That isn't available yet."
        }
    }

    // MARK: Apps

    private func activate(url: URL, name: String, generation started: Int) async -> (app: NSRunningApplication?, problem: String?) {
        let bundleID = Bundle(url: url)?.bundleIdentifier
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let app: NSRunningApplication
        do {
            app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        } catch {
            return (nil, "I couldn't open \(name).")
        }
        guard generation == started else { return (nil, nil) }
        // Postcondition: the app is frontmost within two seconds.
        for _ in 0 ..< 20 {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID { return (app, nil) }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return (nil, "I asked \(name) to open but couldn't confirm it's in front.")
    }

    private func quit(named spoken: String, generation started: Int) async -> String? {
        let wanted = Self.normalizedAppName(spoken)
        if wanted == "keyless" { return "To quit me, say \(Self.addressHint) quit Keyless." }
        // Only regular apps the user sees in the Dock; never background or system processes.
        let matches = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && Self.normalizedAppName($0.localizedName ?? "") == wanted
        }
        guard let app = matches.first, let name = app.localizedName else { return "\(spoken) isn't running." }
        // Polite quit, as if from the app's menu; never force-quit.
        guard app.terminate() else { return "\(name) didn't accept the request to quit." }
        for _ in 0 ..< 30 {
            if app.isTerminated { return nil }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard generation == started else { return nil }
        return "\(name) is still open. It may be asking you to save something."
    }

    private static var addressHint: String {
        (UserDefaults.standard.string(forKey: "addressPhrase") ?? "computer").capitalized + ","
    }

    private static func frontmostOtherApp() -> NSRunningApplication? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }
        return front
    }

    static func normalizedAppName(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: ".app", with: "").filter { $0.isLetter || $0.isNumber }
    }

    /// Exact (case- and space-insensitive) match on an installed app's name. No fuzzy guessing.
    static func findApplication(named spoken: String) -> URL? {
        let wanted = normalizedAppName(spoken)
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.activationPolicy == .regular && normalizedAppName($0.localizedName ?? "") == wanted
        }), let url = running.bundleURL {
            return url
        }
        let roots = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        for root in roots {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for item in items where item.hasSuffix(".app") && normalizedAppName(item) == wanted {
                return URL(fileURLWithPath: root).appendingPathComponent(item)
            }
        }
        return nil
    }

    // MARK: Menu items

    /// Presses the first enabled menu item with one of `titles` in the app's menu bar, through
    /// Accessibility. The app decides what the item does, exactly as if the user clicked it.
    private func pressMenuItem(_ titles: [String], in app: NSRunningApplication) -> String? {
        let name = app.localizedName ?? "That app"
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.5)
        guard let menuBar: AXUIElement = AX.attribute(element, kAXMenuBarAttribute) else {
            return "I can't reach \(name)'s menus."
        }
        guard let item = Self.findMenuItem(titles, under: menuBar, depth: 0) else {
            return "\(name) doesn't have a \(titles[0]) command."
        }
        guard AX.attribute(item, kAXEnabledAttribute) as Bool? ?? true else {
            return "\(titles[0]) isn't available in \(name) right now."
        }
        guard AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else {
            return "\(name) didn't respond to \(titles[0])."
        }
        return nil
    }

    /// Menu bar → menu bar items → menus → items. Submenus are not searched.
    private static func findMenuItem(_ titles: [String], under element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 3, let children: [AXUIElement] = AX.attribute(element, kAXChildrenAttribute) else { return nil }
        for title in titles {
            for child in children where depth == 2 {
                if (AX.attribute(child, kAXTitleAttribute) as String?) == title { return child }
            }
        }
        for child in children {
            if let found = findMenuItem(titles, under: child, depth: depth + 1) { return found }
        }
        return nil
    }
}
