// CmuxSwitcher: an Arc/Dia-style recent-tab switcher for cmux.
//
// With cmux in front:
//   Cmd+G            show the eight most recently used tabs, previous one selected
//   G (Cmd held)     move down the list; Shift+G moves up; arrows and 1-8 also work
//   release Cmd      switch to the selected tab (and its workspace)
//   Esc              cancel
//
// How it works:
//   * Recency comes from cmux's own `surface.focused` events (a surface is a
//     tab). The order is saved between runs, and cmux's recent events fill in
//     whatever happened while the helper was off.
//   * It reads cmux through the `cmux` CLI (tab list, workspace colours, the
//     event stream). cmux accepts outside programs only in "password" socket
//     mode, and the CLI reads that password from the Keychain entry cmux saves.
//   * To switch, it sends one `surface.focus` call straight to cmux's socket
//     (a few milliseconds) using a password you give it with
//     `build.sh --set-password`, kept in its own Keychain item. Without that
//     password, or if the socket call fails, it runs the CLI instead (about
//     150 ms). No secret lives in this repo.
//   * A CGEventTap swallows Cmd+G while cmux is the frontmost app and nowhere
//     else. It needs the Accessibility permission.
//
// Safety: the tap passes every key through except G, Esc, Return, the up and
// down arrows and 1-8 while the list is showing, and the list closes itself if
// Cmd is no longer held, so a missed key-up can never leave the keyboard stuck.

import AppKit
import ApplicationServices

// MARK: - Configuration

let cmuxBundleID = "com.cmuxterm.app"
let cmuxCLI = "/Applications/cmux.app/Contents/Resources/bin/cmux"
let maxItems = 8

let keyG: Int64 = 5
let keyEsc: Int64 = 53
let keyReturn: Int64 = 36
let keyEnter: Int64 = 76
let keyDown: Int64 = 125
let keyUp: Int64 = 126
let digitKeys: [Int64: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8]

// MARK: - Logging

let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/CmuxSwitcher.log")

func log(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: logURL)
    }
}

func trimLogIfLarge() {
    let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path)
    let size = (attributes?[.size] as? Int) ?? 0
    if size > 200_000 { try? FileManager.default.removeItem(at: logURL) }
}

// MARK: - cmux CLI

/// The socket password, if you gave the helper one (build.sh --set-password).
/// With it a switch goes straight to the cmux socket in a few milliseconds.
/// Without it every switch runs the cmux CLI, about 150 ms. Never prompts: if
/// the Keychain would ask, the helper just carries on without it.
enum Secrets {
    static var socketPassword: String? = load()

    private static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.jonobri.cmux-switcher",
            kSecAttrAccount as String: "socket-password",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let text = String(data: data, encoding: .utf8) else {
            log("saved socket password not used (Keychain status \(status))")
            return nil
        }
        log("saved socket password loaded")
        let password = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return password.isEmpty ? nil : password
    }
}

func cmuxEnvironment() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    if let password = Secrets.socketPassword { env["CMUX_SOCKET_PASSWORD"] = password }
    return env
}

/// Talks to the cmux socket directly, so a switch skips the CLI's start-up
/// (about 150 ms of a switch). Needs the saved password; any failure returns
/// false and the caller falls back to the CLI.
enum CmuxSocket {
    private static var path: String {
        ProcessInfo.processInfo.environment["CMUX_SOCKET_PATH"]
            ?? NSHomeDirectory() + "/.local/state/cmux/cmux.sock"
    }

    /// Sends one JSON-RPC call. Blocks; call off the main thread.
    static func call(_ method: String, _ params: [String: Any]) -> Bool {
        guard let password = Secrets.socketPassword else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            for (i, b) in bytes.enumerated() { dst[i] = UInt8(bitPattern: b) }
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return false }

        func send(_ line: String) -> Bool {
            let data = Array((line + "\n").utf8)
            return write(fd, data, data.count) == data.count
        }
        func readLine() -> String? {
            var out = [UInt8]()
            var byte: UInt8 = 0
            while read(fd, &byte, 1) == 1 {
                if byte == 10 { break }
                out.append(byte)
            }
            return out.isEmpty ? nil : String(decoding: out, as: UTF8.self)
        }

        guard send("auth \(password)"), let authReply = readLine(), authReply.hasPrefix("OK") else {
            log("socket auth not accepted; using the CLI")
            return false
        }
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": method, "params": params]
        guard let body = try? JSONSerialization.data(withJSONObject: request),
              let line = String(data: body, encoding: .utf8),
              send(line), let reply = readLine(),
              let object = try? JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any] else { return false }
        if (object["ok"] as? Bool) == true { return true }
        log("socket call \(method) failed: \(reply.prefix(200))")
        return false
    }
}

enum CmuxCLI {
    /// Runs the cmux CLI off the main thread; the completion runs on main.
    static func run(_ args: [String], completion: @escaping (Int32, Data, String) -> Void) {
        DispatchQueue.global().async {
            let began = Date()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cmuxCLI)
            process.arguments = args
            process.environment = cmuxEnvironment()
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            do { try process.run() } catch {
                DispatchQueue.main.async { completion(-1, Data(), "\(error)") }
                return
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let errText = String(data: errData, encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                // A stale saved password must not break switching: drop it and
                // let the CLI use cmux's own Keychain entry.
                if process.terminationStatus != 0, errText.contains("Invalid password"), Secrets.socketPassword != nil {
                    log("saved socket password was rejected; falling back to cmux's own")
                    Secrets.socketPassword = nil
                    run(args, completion: completion)
                    return
                }
                completion(process.terminationStatus, data, errText)
            }
        }
    }
}

// MARK: - Tab model

/// One tab (cmux calls it a surface) and the workspace it lives in.
struct Tab {
    let id: String
    let workspaceID: String
    var workspaceTitle: String
    var title: String
    var kind: String
    var color: NSColor?
}

private let spinnerPrefix = try! NSRegularExpression(pattern: "^[\\u2800-\\u28FF\\u2732-\\u273F\\u2217\\u00B7*\\u2022\\s]+")

/// Agent CLIs prefix tab titles with an animated spinner frame; drop it.
func cleanTitle(_ raw: String) -> String {
    let range = NSRange(raw.startIndex..., in: raw)
    let cleaned = spinnerPrefix.stringByReplacingMatches(in: raw, range: range, withTemplate: "")
        .trimmingCharacters(in: .whitespaces)
    // An idle shell titles itself "user@host:~/path". Say what it is instead.
    if let at = cleaned.firstIndex(of: "@"), let colon = cleaned.firstIndex(of: ":"), at < colon,
       !cleaned[..<at].contains(" ") {
        let path = String(cleaned[cleaned.index(after: colon)...])
        let folder = path == "~" ? "~" : (path as NSString).lastPathComponent
        return "Shell · \(folder)"
    }
    return cleaned
}

/// "#RRGGBB" to a colour, or nil.
func color(hex: String?) -> NSColor? {
    guard let hex = hex else { return nil }
    let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    guard digits.count == 6, let n = UInt32(digits, radix: 16) else { return nil }
    return NSColor(
        srgbRed: CGFloat((n >> 16) & 255) / 255,
        green: CGFloat((n >> 8) & 255) / 255,
        blue: CGFloat(n & 255) / 255,
        alpha: 1
    )
}

/// Dark ink on pale colours (the yellow, the orange), white on the rest.
func inkColor(on color: NSColor) -> NSColor {
    guard let c = color.usingColorSpace(.sRGB) else { return .white }
    let lum = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
    return lum > 0.59 ? NSColor(white: 0.11, alpha: 1) : .white
}

final class Model {
    var byID: [String: Tab] = [:]
    /// Most recently focused tab first.
    var mru: [String] = UserDefaults.standard.stringArray(forKey: "mru") ?? []
    var lastError: String?
    private var refreshQueued = false

    /// Kept across restarts, so rebuilding or restarting the helper does not
    /// forget which tabs you were using.
    private func save() { UserDefaults.standard.set(Array(mru.prefix(50)), forKey: "mru") }

    func touch(_ id: String) {
        mru.removeAll { $0 == id }
        mru.insert(id, at: 0)
        save()
    }

    /// The most recently used tabs that still exist.
    func ordered() -> [Tab] {
        Array(mru.compactMap { byID[$0] }.prefix(maxItems))
    }

    func refresh() {
        // Workspace colours live on the workspace list, not in the tree.
        CmuxCLI.run(["rpc", "workspace.list", "{}"]) { [self] status, data, _ in
            var colours: [String: NSColor] = [:]
            if status == 0,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let list = object["workspaces"] as? [[String: Any]] {
                for w in list {
                    if let id = w["id"] as? String, let c = color(hex: w["custom_color"] as? String) { colours[id] = c }
                }
            }
            readTree(colours: colours)
        }
    }

    private func readTree(colours: [String: NSColor]) {
        CmuxCLI.run(["--id-format", "uuids", "--json", "tree"]) { [self] status, data, err in
            guard status == 0,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let windows = object["windows"] as? [[String: Any]] else {
                let text = err.trimmingCharacters(in: .whitespacesAndNewlines)
                lastError = text.isEmpty ? "no response from cmux" : text
                log("refresh failed (status \(status)): \(lastError ?? "")")
                return
            }
            lastError = nil
            var map: [String: Tab] = [:]
            var currentID: String?
            for window in windows {
                for ws in (window["workspaces"] as? [[String: Any]]) ?? [] {
                    guard let wsID = ws["id"] as? String else { continue }
                    let wsTitle = (ws["title"] as? String) ?? "untitled"
                    let isSelectedWorkspace = (ws["selected"] as? Bool) == true
                    for pane in (ws["panes"] as? [[String: Any]]) ?? [] {
                        for s in (pane["surfaces"] as? [[String: Any]]) ?? [] {
                            guard let id = s["id"] as? String else { continue }
                            let kind = (s["type"] as? String) ?? "terminal"
                            let title = cleanTitle((s["title"] as? String) ?? "")
                            map[id] = Tab(
                                id: id,
                                workspaceID: wsID,
                                workspaceTitle: wsTitle.isEmpty ? "untitled" : wsTitle,
                                title: title.isEmpty ? (kind == "terminal" ? "Terminal" : kind.capitalized) : title,
                                kind: kind,
                                color: colours[wsID]
                            )
                            if isSelectedWorkspace, (s["here"] as? Bool) == true { currentID = id }
                        }
                    }
                }
            }
            byID = map
            let before = mru.count
            mru.removeAll { map[$0] == nil }
            if mru.count != before { save() }
            // Events are the source of truth once running. The tree only makes
            // sure the tab you are on is first, which also covers a switch of
            // workspace that produced no tab event.
            if let currentID = currentID, mru.first != currentID { touch(currentID) }
        }
    }

    func refreshSoon() {
        if refreshQueued { return }
        refreshQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
            refreshQueued = false
            refresh()
        }
    }
}

// MARK: - Event stream (surface.focused, workspace.selected)

final class EventStream {
    private let model: Model
    private var buffer = Data()

    init(model: Model) { self.model = model }

    func start() {
        buffer = Data()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cmuxCLI)
        // --after 0 replays the events cmux still retains, oldest first, so the
        // last one seen is the most recent switch. workspace.selected carries no
        // tab, so it only triggers a re-read of the tree.
        process.arguments = ["events", "--name", "surface.focused", "--name", "workspace.selected",
                             "--after", "0", "--no-ack", "--no-heartbeat"]
        process.environment = cmuxEnvironment()
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            DispatchQueue.main.async { self?.ingest(data) }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self?.start() }
        }
        do { try process.run() } catch { log("events failed to start: \(error)") }
    }

    private func ingest(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            guard (event["name"] as? String) == "surface.focused" else { continue }
            let payload = event["payload"] as? [String: Any]
            if let id = (payload?["surface_id"] as? String) ?? (event["surface_id"] as? String) {
                model.touch(id)
            }
        }
        model.refreshSoon()
    }
}

// MARK: - HUD

final class HUDView: NSView {
    var items: [Tab] = []
    var selected = 0
    var message: (String, String)?

    static let width: CGFloat = 480
    static let rowHeight: CGFloat = 50
    static let pad: CGFloat = 12

    override var isFlipped: Bool { true }

    static func height(rows: Int) -> CGFloat { pad * 2 + CGFloat(max(rows, 1)) * rowHeight }

    private func text(_ string: String, in rect: NSRect, font: NSFont, color: NSColor) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        (string as NSString).draw(
            in: rect,
            withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: style]
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        let pad = HUDView.pad
        let rowHeight = HUDView.rowHeight
        if let (title, subtitle) = message {
            let rect = NSRect(x: 20, y: pad + 6, width: bounds.width - 40, height: 20)
            text(title, in: rect, font: .systemFont(ofSize: 15, weight: .semibold), color: .white)
            text(subtitle, in: rect.offsetBy(dx: 0, dy: 22), font: .systemFont(ofSize: 11), color: NSColor(white: 1, alpha: 0.65))
            return
        }
        for (i, tab) in items.enumerated() {
            let row = NSRect(x: 8, y: pad + CGFloat(i) * rowHeight, width: bounds.width - 16, height: rowHeight)
            let isSelected = i == selected
            if isSelected {
                // Neutral, so the workspace colours stay readable on the selected row.
                NSColor(white: 1, alpha: 0.17).setFill()
                NSBezierPath(roundedRect: row.insetBy(dx: 0, dy: 2), xRadius: 10, yRadius: 10).fill()
            }
            // The workspace's colour as a bar down the row's left edge.
            (tab.color ?? NSColor(white: 1, alpha: 0.18)).setFill()
            NSBezierPath(roundedRect: NSRect(x: row.minX + 6, y: row.minY + 9, width: 4, height: rowHeight - 18),
                         xRadius: 2, yRadius: 2).fill()
            let primary = NSColor.white
            let secondary = NSColor(white: 1, alpha: isSelected ? 0.8 : 0.55)
            text("\(i + 1)", in: NSRect(x: row.minX + 14, y: row.minY + 15, width: 18, height: 18),
                 font: .monospacedDigitSystemFont(ofSize: 13, weight: .regular), color: secondary)
            // Line 1: the tab. Line 2: the workspace as a tag, then "current".
            let titleRect = NSRect(x: row.minX + 44, y: row.minY + 6, width: row.width - 60, height: 20)
            text(tab.title, in: titleRect, font: .systemFont(ofSize: 15, weight: .semibold), color: primary)
            let tagFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
            let tagInk = tab.color.map { inkColor(on: $0) } ?? primary
            let tagAttrs: [NSAttributedString.Key: Any] = [.font: tagFont, .foregroundColor: tagInk]
            let tagWidth = min((tab.workspaceTitle as NSString).size(withAttributes: tagAttrs).width + 12, row.width - 150)
            let tagRect = NSRect(x: titleRect.minX, y: row.minY + 28, width: tagWidth, height: 15)
            (tab.color ?? NSColor(white: 1, alpha: isSelected ? 0.25 : 0.16)).setFill()
            NSBezierPath(roundedRect: tagRect, xRadius: 5, yRadius: 5).fill()
            text(tab.workspaceTitle, in: tagRect.insetBy(dx: 6, dy: 1), font: tagFont, color: tagInk)
            if i == 0 {
                text("current", in: NSRect(x: tagRect.maxX + 8, y: row.minY + 29, width: 80, height: 14),
                     font: .systemFont(ofSize: 11), color: secondary)
            }
        }
    }
}

final class HUD {
    private let panel: NSPanel
    private let view = HUDView()
    private var hideTimer: Timer?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: HUDView.width, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named: .vibrantDark)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 16
        blur.layer?.masksToBounds = true
        view.autoresizingMask = [.width, .height]
        blur.addSubview(view)
        panel.contentView = blur
    }

    private func place(rows: Int) {
        let height = HUDView.height(rows: rows)
        let size = NSSize(width: HUDView.width, height: height)
        var center = NSPoint(x: NSScreen.main?.frame.midX ?? 600, y: NSScreen.main?.frame.midY ?? 400)
        if let c = cmuxWindowCenter() { center = c }
        panel.setFrame(NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                              width: size.width, height: size.height), display: true)
        view.frame = NSRect(origin: .zero, size: size)
    }

    func show(items: [Tab], selected: Int) {
        hideTimer?.invalidate()
        view.message = nil
        view.items = items
        view.selected = selected
        place(rows: items.count)
        view.needsDisplay = true
        panel.orderFrontRegardless()
    }

    func select(_ index: Int) {
        view.selected = index
        view.needsDisplay = true
    }

    func showMessage(_ title: String, _ subtitle: String, seconds: TimeInterval = 3) {
        view.message = (title, subtitle)
        place(rows: 1)
        view.needsDisplay = true
        panel.orderFrontRegardless()
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.panel.orderOut(nil)
        }
    }

    func hide() {
        hideTimer?.invalidate()
        panel.orderOut(nil)
    }

    /// Centre of cmux's biggest on-screen window, in Cocoa coordinates.
    private func cmuxWindowCenter() -> NSPoint? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: cmuxBundleID).first,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]],
              let primary = NSScreen.screens.first else { return nil }
        var best: CGRect?
        for w in windows {
            guard (w[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict as CFDictionary) else { continue }
            if best == nil || rect.width * rect.height > best!.width * best!.height { best = rect }
        }
        guard let r = best else { return nil }
        return NSPoint(x: r.midX, y: primary.frame.height - r.midY)
    }
}

func json(_ object: [String: String]) -> String {
    (try? JSONSerialization.data(withJSONObject: object)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
}

// MARK: - Switcher (key handling)

final class Switcher {
    static let shared = Switcher()

    let model = Model()
    let hud = HUD()
    lazy var events = EventStream(model: model)

    private var tap: CFMachPort?
    private var showing = false
    private var items: [Tab] = []
    private var selection = 0
    private var swallowGKeyUp = false
    private var watchdog: Timer?

    func start() {
        trimLogIfLarge()
        log("starting")
        model.refresh()
        events.start()
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.model.refresh() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.bundleIdentifier == cmuxBundleID { self?.cancel() }
        }
        installTapWhenTrusted(prompt: true)
    }

    // MARK: Tap

    private func installTapWhenTrusted(prompt: Bool) {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        if AXIsProcessTrustedWithOptions(options), installTap() { return }
        if prompt { log("waiting for the Accessibility permission") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.installTapWhenTrusted(prompt: false)
        }
    }

    @discardableResult
    private func installTap() -> Bool {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, _ in
            Switcher.shared.handle(type: type, event: event)
        }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: callback, userInfo: nil
        ) else { return false }
        tap = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        log("key tap installed")
        return true
    }

    private func cmuxIsFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == cmuxBundleID
    }

    private func commandIsDown() -> Bool {
        CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand)
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        guard cmuxIsFrontmost() else {
            if showing { cancel() }
            return pass
        }

        let flags = event.flags
        let key = event.getIntegerValueField(.keyboardEventKeycode)

        switch type {
        case .keyDown:
            let mods = flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate])
            let cmdOnly = !flags.contains(.maskControl) && !flags.contains(.maskAlternate)
            if key == keyG, flags.contains(.maskCommand), cmdOnly {
                if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
                if showing {
                    step(flags.contains(.maskShift) ? -1 : 1)
                } else if mods == .maskCommand {
                    begin()
                } else {
                    return pass // Cmd+Shift+G with the list closed keeps its normal meaning
                }
                swallowGKeyUp = true
                return nil
            }
            guard showing else { return pass }
            // A missed Cmd release must never trap the keyboard.
            if !commandIsDown() {
                commit()
                return pass
            }
            switch key {
            case keyEsc: cancel(); return nil
            case keyReturn, keyEnter: commit(); return nil
            case keyDown: step(1); return nil
            case keyUp: step(-1); return nil
            default:
                if let n = digitKeys[key], n <= items.count {
                    selection = n - 1
                    commit()
                    return nil
                }
                return pass
            }
        case .keyUp:
            if key == keyG, swallowGKeyUp {
                swallowGKeyUp = false
                return nil
            }
            return pass
        case .flagsChanged:
            if showing && !flags.contains(.maskCommand) { commit() }
            return pass
        default:
            return pass
        }
    }

    // MARK: List lifecycle

    func begin() {
        let list = model.ordered()
        log("Cmd+G: \(list.count) tabs known")
        guard list.count >= 2 else {
            if model.lastError != nil {
                hud.showMessage("Can't reach cmux",
                                "Set the socket mode to Password in cmux Settings, then Automation. See the log for details.")
            } else {
                hud.showMessage("Not enough history yet",
                                "Switch between a few tabs first, then try again.")
            }
            swallowGKeyUp = true
            return
        }
        items = list
        selection = 1
        showing = true
        hud.show(items: items, selected: selection)
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self = self, self.showing else { return }
            if !self.commandIsDown() { self.commit() }
        }
        model.refreshSoon()
    }

    func step(_ delta: Int) {
        guard showing, !items.isEmpty else { return }
        selection = (selection + delta + items.count) % items.count
        hud.select(selection)
    }

    func commit() {
        guard showing else { return }
        let target = items[selection]
        let current = items.first?.id
        end()
        guard target.id != current else { return }
        model.touch(target.id)
        log("switch to \"\(target.title)\" in \"\(target.workspaceTitle)\"")
        // surface.focus with a workspace id selects the workspace and the tab in
        // one call. Two calls in a row cost twice the CLI's start-up time.
        let focusParams = json(["surface_id": target.id, "workspace_id": target.workspaceID])
        let started = Date()
        let focusObject: [String: Any] = ["surface_id": target.id, "workspace_id": target.workspaceID]
        DispatchQueue.global(qos: .userInteractive).async {
            if CmuxSocket.call("surface.focus", focusObject) {
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                log("switched in \(ms) ms (direct socket)")
                return
            }
            DispatchQueue.main.async { self.focusViaCLI(target: target, focusParams: focusParams, started: started) }
        }
    }

    private func focusViaCLI(target: Tab, focusParams: String, started: Date) {
        CmuxCLI.run(["rpc", "surface.focus", focusParams]) { status, _, err in
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            if status == 0 {
                log("switched in \(ms) ms (saved password \(Secrets.socketPassword == nil ? "off" : "on"))")
                return
            }
            log("surface.focus failed (status \(status)): \(err)")
            let selectParams = json(["workspace_id": target.workspaceID])
            CmuxCLI.run(["rpc", "workspace.select", selectParams]) { status, _, err in
                if status != 0 { log("workspace.select failed (status \(status)): \(err)") }
            }
        }
    }

    func cancel() {
        guard showing else { return }
        end()
    }

    private func end() {
        showing = false
        watchdog?.invalidate()
        watchdog = nil
        hud.hide()
    }

    /// Shows the list with invented tabs over a plain backdrop, then steps down
    /// it. For checking the layout and taking screenshots without exposing real
    /// tab names: nothing here reads cmux.
    func demo() {
        func tab(_ id: String, _ workspace: String, _ title: String, _ hex: String, kind: String = "terminal") -> Tab {
            Tab(id: id, workspaceID: workspace, workspaceTitle: workspace, title: title, kind: kind, color: color(hex: hex))
        }
        let list = [
            tab("1", "api-server", "Fix flaky checkout test", "#0A84FF"),
            tab("2", "marketing", "Draft launch post", "#30B0C7"),
            tab("3", "frontend", "dev server", "#FFD60A"),
            tab("4", "api-server", "Review PR 482", "#0A84FF"),
            tab("5", "data-platform", "Migrate to Postgres 17", "#BF5AF2"),
            tab("6", "frontend", "Shell · web", "#FFD60A"),
            tab("7", "marketing", "Write release notes", "#30B0C7"),
            tab("8", "infra", "Shell · terraform", "#FF9F0A"),
        ]
        if let screen = NSScreen.main {
            let backdrop = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            backdrop.backgroundColor = NSColor(calibratedRed: 0.16, green: 0.18, blue: 0.24, alpha: 1)
            backdrop.level = .normal
            backdrop.orderFrontRegardless()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            hud.show(items: list, selected: 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.hud.select(2) }
        }
    }
}

// MARK: - Main

let application = NSApplication.shared
application.setActivationPolicy(.accessory)

if CommandLine.arguments.contains("--demo") {
    Switcher.shared.demo()
    DispatchQueue.main.asyncAfter(deadline: .now() + 9) { exit(0) }
} else {
    Switcher.shared.start()
}
application.run()
