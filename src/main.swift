// ChromeProfileSelector
//
// Registered as the macOS default browser. Every URL open shows a picker:
//   - profile list read live from Chrome's Local State (never goes stale)
//   - preselects the profile you chose last time (UserDefaults)
//   - Return/Enter opens the highlighted profile, Esc cancels
//   - arrow keys move the highlight, 1-9 pick-and-open instantly, double-click opens
//   - URL shown wide (up to 3 lines, monospaced, selectable, full URL in tooltip)
//   - shows which app requested the open ("Requested by Slack"), when determinable
//
// Build & install: ./install.sh (see README.md)

import AppKit

struct Profile {
    let dir: String
    let label: String
    let avatar: NSImage
}

func loadProfiles() -> [Profile] {
    let chromeDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Google/Chrome")
    guard let data = try? Data(contentsOf: chromeDir.appendingPathComponent("Local State")),
          let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let profile = root["profile"] as? [String: Any],
          let cache = profile["info_cache"] as? [String: [String: Any]]
    else { return [] }
    // JSON dicts lose Chrome's ordering; sort Default first, then Profile N by number.
    func order(_ dir: String) -> Int {
        if dir == "Default" { return 0 }
        return Int(dir.replacingOccurrences(of: "Profile ", with: "")) ?? Int.max
    }
    return cache.map { dir, info -> Profile in
        let name = (info["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? dir
        let email = (info["user_name"] as? String) ?? ""
        return Profile(dir: dir,
                       label: email.isEmpty ? name : "\(name)   (\(email))",
                       avatar: avatarImage(profileDir: dir, info: info, chromeDir: chromeDir, name: name))
    }
    .sorted { order($0.dir) < order($1.dir) }
}

// MARK: - Profile avatars

/// The profile's Google account photo (circular-cropped), or a Chrome-style
/// colored monogram circle if no photo exists on disk.
func avatarImage(profileDir: String, info: [String: Any], chromeDir: URL, name: String) -> NSImage {
    let pdir = chromeDir.appendingPathComponent(profileDir)
    var candidates: [URL] = []
    if let f = info["gaia_picture_file_name"] as? String {
        candidates.append(pdir.appendingPathComponent(f))
    }
    candidates.append(pdir.appendingPathComponent("Google Profile Picture.png"))
    if let gaia = info["gaia_id"] as? String {
        candidates.append(pdir.appendingPathComponent("Accounts/Avatar Images/\(gaia)"))
    }
    for url in candidates {
        if let img = NSImage(contentsOf: url), img.isValid {
            return circularCrop(img)
        }
    }
    return monogramAvatar(name: name, argb: info["default_avatar_fill_color"] as? Int)
}

private let avatarSize: CGFloat = 64

func circularCrop(_ image: NSImage) -> NSImage {
    let out = NSImage(size: NSSize(width: avatarSize, height: avatarSize))
    out.lockFocus()
    let rect = NSRect(x: 0, y: 0, width: avatarSize, height: avatarSize)
    NSBezierPath(ovalIn: rect).addClip()
    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    out.unlockFocus()
    return out
}

func monogramAvatar(name: String, argb: Int?) -> NSImage {
    let color: NSColor
    if let argb {
        let v = UInt32(bitPattern: Int32(truncatingIfNeeded: argb))
        color = NSColor(calibratedRed: CGFloat((v >> 16) & 0xFF) / 255,
                        green: CGFloat((v >> 8) & 0xFF) / 255,
                        blue: CGFloat(v & 0xFF) / 255,
                        alpha: 1)
    } else {
        color = .systemGray
    }
    let out = NSImage(size: NSSize(width: avatarSize, height: avatarSize))
    out.lockFocus()
    let rect = NSRect(x: 0, y: 0, width: avatarSize, height: avatarSize)
    color.setFill()
    NSBezierPath(ovalIn: rect).fill()
    let initial = String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: avatarSize * 0.45, weight: .medium),
        .foregroundColor: NSColor.white,
    ]
    let str = NSAttributedString(string: initial, attributes: attrs)
    let ssize = str.size()
    str.draw(at: NSPoint(x: (avatarSize - ssize.width) / 2, y: (avatarSize - ssize.height) / 2))
    out.unlockFocus()
    return out
}

func openInChrome(profileDir: String, url: String) {
    let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    guard FileManager.default.isExecutableFile(atPath: chrome) else {
        let a = NSAlert()
        a.messageText = "Google Chrome not found"
        a.informativeText = "Expected it at /Applications/Google Chrome.app"
        a.runModal()
        return
    }
    // Call the Chrome binary directly: `open -a ... --args` ignores
    // --profile-directory when Chrome is already running.
    let p = Process()
    p.executableURL = URL(fileURLWithPath: chrome)
    p.arguments = ["--profile-directory=\(profileDir)", url]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
}

// MARK: - Sender identification

struct SenderInfo {
    let name: String
    let icon: NSImage?

    /// Must be called while the URL-open Apple Event is still "current",
    /// i.e. synchronously inside application(_:open:).
    static func capture() -> SenderInfo? {
        let keySenderPID = AEKeyword(0x73706964) // 'spid'
        if let event = NSAppleEventManager.shared().currentAppleEvent {
            let pid = event.attributeDescriptor(forKeyword: keySenderPID)?.int32Value ?? 0
            if pid > 0, let info = resolve(pid: pid_t(pid)) { return info }
        }
        // The sender may be a short-lived CLI like `open` that has already
        // exited. The frontmost app is almost always the origin in that case
        // (e.g. the terminal the command was typed in).
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            return SenderInfo(name: front.localizedName ?? "unknown", icon: front.icon)
        }
        return nil
    }

    /// Walk up the process tree from the sender until we hit a real GUI app.
    /// A terminal `open https://…` attributes the event to the `open` process;
    /// its ancestry (open → shell → login → Terminal/iTerm) names the terminal.
    private static func resolve(pid: pid_t) -> SenderInfo? {
        var current = pid
        for _ in 0..<12 {
            guard current > 1 else { break }
            if let app = NSRunningApplication(processIdentifier: current),
               app.bundleIdentifier != nil,
               current != ProcessInfo.processInfo.processIdentifier {
                return SenderInfo(name: app.localizedName ?? app.bundleIdentifier ?? "unknown",
                                  icon: app.icon)
            }
            guard let ppid = parentPID(of: current) else { break }
            current = ppid
        }
        return nil
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0,
              size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}

// MARK: - Picker UI

final class PickerTable: NSTableView {
    var onActivate: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if let chars = event.charactersIgnoringModifiers {
            if let d = Int(chars), d >= 1, d <= numberOfRows {
                selectRowIndexes(IndexSet(integer: d - 1), byExtendingSelection: false)
                onActivate?()
                return
            }
            if chars == "\r" || chars == "\u{3}" { // Return / keypad Enter (belt & braces)
                onActivate?()
                return
            }
        }
        super.keyDown(with: event)
    }
}

final class PickerController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let profiles: [Profile]
    var onActivate: (() -> Void)?
    var onSelectionChange: ((Int) -> Void)?
    var urlToCopy = ""
    init(profiles: [Profile]) { self.profiles = profiles }

    @objc func copyURL(_ sender: Any?) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(urlToCopy, forType: .string)
        // Brief checkmark as "copied" feedback. Use a .common-modes timer so it
        // fires while the modal dialog is still running.
        if let btn = sender as? NSButton {
            let original = btn.image
            btn.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
            let t = Timer(timeInterval: 0.9, repeats: false) { _ in btn.image = original }
            RunLoop.current.add(t, forMode: .common)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { profiles.count }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        onSelectionChange?(table.selectedRow)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let field: NSTextField
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField {
            field = reused
        } else {
            field = NSTextField(labelWithString: "")
            field.identifier = id
            field.font = NSFont.systemFont(ofSize: 13)
            field.lineBreakMode = .byTruncatingTail
        }
        field.stringValue = "\(row + 1)   \(profiles[row].label)"
        return field
    }

    @objc func doubleClicked(_ sender: Any?) { onActivate?() }
}

// MARK: - App lifecycle

final class AppDelegate: NSObject, NSApplicationDelegate {
    private struct Request {
        let url: String
        let sender: SenderInfo?
    }

    private var queue: [Request] = []
    private var busy = false
    private var receivedAny = false

    func applicationDidFinishLaunching(_ note: Notification) {
        // Launched directly (no URL): show a hint (and auto-open status), then quit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, !self.receivedAny else { return }
            NSApp.activate(ignoringOtherApps: true)
            let defaults = UserDefaults.standard
            let a = NSAlert()
            a.messageText = "ChromeProfileSelector"
            a.informativeText = "This app routes links to the Chrome profile you pick. Set it as the default browser (System Settings → Desktop & Dock), then open any link."
            if let until = defaults.object(forKey: "autoOpenUntil") as? Date,
               until > Date(),
               let autoDir = defaults.string(forKey: "autoOpenProfileDir") {
                let label = loadProfiles().first(where: { $0.dir == autoDir })?.label ?? autoDir
                let fmt = DateFormatter()
                fmt.timeStyle = .short
                a.informativeText += "\n\nAuto-open is ON: all links go to \(label) until \(fmt.string(from: until))."
                a.addButton(withTitle: "OK")
                a.addButton(withTitle: "Stop Auto-Open")
                if a.runModal() == .alertSecondButtonReturn {
                    defaults.removeObject(forKey: "autoOpenUntil")
                    defaults.removeObject(forKey: "autoOpenProfileDir")
                }
            } else {
                a.runModal()
            }
            NSApp.terminate(nil)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        receivedAny = true
        let sender = SenderInfo.capture() // must happen now, while the Apple Event is current
        queue.append(contentsOf: urls.map { Request(url: $0.absoluteString, sender: sender) })
        processQueue()
    }

    private func processQueue() {
        guard !busy else { return }
        if queue.isEmpty { NSApp.terminate(nil); return }
        busy = true
        let request = queue.removeFirst()
        present(request)
        busy = false
        // Defer so URLs that arrived while the dialog was up get picked off.
        DispatchQueue.main.async { self.processQueue() }
    }

    private func present(_ request: Request) {
        let url = request.url
        let profiles = loadProfiles()
        guard !profiles.isEmpty else {
            // Can't read the profile list: hand to plain Chrome rather than eat the URL.
            openInChrome(profileDir: "Default", url: url)
            return
        }

        let defaults = UserDefaults.standard

        // "Open for 1 Hour" active? Route straight to that profile, no dialog.
        if let until = defaults.object(forKey: "autoOpenUntil") as? Date,
           until > Date(),
           let autoDir = defaults.string(forKey: "autoOpenProfileDir"),
           profiles.contains(where: { $0.dir == autoDir }) {
            openInChrome(profileDir: autoDir, url: url)
            return
        }

        let lastDir = defaults.string(forKey: "lastProfileDir")
        let preselect = profiles.firstIndex(where: { $0.dir == lastDir }) ?? 0

        let alert = NSAlert()
        alert.messageText = "Open in which Chrome profile?"
        alert.addButton(withTitle: "Open")            // Return
        alert.addButton(withTitle: "Cancel")          // Esc
        alert.addButton(withTitle: "Open for 1 Hour") // this profile, silently, for an hour

        let width: CGFloat = 580
        let urlWidth = width - 30 // leave room for the copy button on the right

        let urlField = NSTextField(wrappingLabelWithString: url)
        urlField.isSelectable = true
        urlField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        urlField.textColor = .secondaryLabelColor
        urlField.maximumNumberOfLines = 3
        urlField.cell?.truncatesLastVisibleLine = true
        urlField.toolTip = url
        urlField.preferredMaxLayoutWidth = urlWidth
        let urlHeight = min(max(urlField.intrinsicContentSize.height, 16), 48)

        let controller = PickerController(profiles: profiles)
        let table = PickerTable(frame: .zero)
        let col = NSTableColumn(identifier: .init("p"))
        col.width = width - 24
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 22
        table.allowsEmptySelection = false
        table.allowsMultipleSelection = false
        table.dataSource = controller
        table.delegate = controller
        table.target = controller
        table.doubleAction = #selector(PickerController.doubleClicked(_:))

        let tableHeight = CGFloat(min(profiles.count, 8)) * (table.rowHeight + 2) + 4
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: tableHeight))
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let gap: CGFloat = 10
        let senderHeight: CGFloat = request.sender == nil ? 0 : 24
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width,
                                             height: tableHeight + gap + urlHeight + senderHeight))
        urlField.frame = NSRect(x: 0, y: tableHeight + gap, width: urlWidth, height: urlHeight)
        container.addSubview(urlField)
        container.addSubview(scroll)

        // Copy-to-clipboard button, top-aligned to the right of the URL.
        controller.urlToCopy = url
        let copyIcon = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy URL")
        let copyButton: NSButton
        if let copyIcon {
            copyButton = NSButton(image: copyIcon, target: controller,
                                  action: #selector(PickerController.copyURL(_:)))
        } else {
            copyButton = NSButton(title: "Copy", target: controller,
                                  action: #selector(PickerController.copyURL(_:)))
        }
        copyButton.isBordered = false
        copyButton.toolTip = "Copy URL"
        copyButton.frame = NSRect(x: width - 22, y: tableHeight + gap + urlHeight - 18,
                                  width: 20, height: 18)
        container.addSubview(copyButton)

        if let sender = request.sender {
            let y = tableHeight + gap + urlHeight + 5
            var labelX: CGFloat = 0
            if let icon = sender.icon {
                let iconView = NSImageView(frame: NSRect(x: 0, y: y, width: 16, height: 16))
                iconView.image = icon
                iconView.imageScaling = .scaleProportionallyUpOrDown
                container.addSubview(iconView)
                labelX = 21
            }
            let senderField = NSTextField(labelWithString: "Requested by \(sender.name)")
            senderField.font = .systemFont(ofSize: 11)
            senderField.textColor = .secondaryLabelColor
            senderField.frame = NSRect(x: labelX, y: y, width: width - labelX, height: 16)
            container.addSubview(senderField)
        }

        alert.accessoryView = container

        let fire = { alert.buttons[0].performClick(nil) }
        table.onActivate = fire
        controller.onActivate = fire

        // The alert's top icon is the selected profile's avatar; it swaps live
        // as the highlight moves.
        controller.onSelectionChange = { [weak alert] row in
            guard let alert, row >= 0, row < profiles.count else { return }
            alert.icon = profiles[row].avatar
        }
        alert.icon = profiles[preselect].avatar

        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: preselect), byExtendingSelection: false)
        table.scrollRowToVisible(preselect)
        alert.window.initialFirstResponder = table

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        let openNow = response == .alertFirstButtonReturn
        let openForHour = response == .alertThirdButtonReturn
        guard openNow || openForHour else { return } // Cancel: URL dropped on purpose

        var row = table.selectedRow
        if row < 0 { row = preselect }
        let chosen = profiles[row]
        defaults.set(chosen.dir, forKey: "lastProfileDir")
        if openForHour {
            defaults.set(Date().addingTimeInterval(3600), forKey: "autoOpenUntil")
            defaults.set(chosen.dir, forKey: "autoOpenProfileDir")
        }
        openInChrome(profileDir: chosen.dir, url: url)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
