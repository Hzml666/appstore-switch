import AppKit
import ApplicationServices
import Foundation

//
//  sswitch — switch macOS App Store accounts from the terminal.
//
//  Drives the App Store window through the Accessibility API instead of
//  AppleScript: one switch takes ~8s, never opens a window of its own, and
//  hands focus straight back to whatever you were using.
//
//  Requires: macOS 13+, Accessibility permission, and a one-time
//  "control System Events" automation grant (used only to type the password
//  into a secure field — synthetic CGEvents are dropped while Secure Input
//  is active).
//

let service = "appstoreswitch.cli"

func sh(_ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    do { try p.run() } catch { return (1, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
}

func readPassword(_ name: String) -> String? {
    let (code, out) = sh(["find-generic-password", "-s", service, "-a", name, "-w"])
    return code == 0 && !out.isEmpty ? out : nil
}

func indexURL() -> URL {
    let dir = URL(fileURLWithPath: NSHomeDirectory() + "/.config/sswitch")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("accounts")
}

func indexNames() -> [String] {
    (try? String(contentsOf: indexURL(), encoding: .utf8))?
        .split(separator: "\n").map(String.init).filter { !$0.isEmpty } ?? []
}

func indexAdd(_ name: String) {
    var names = indexNames()
    if !names.contains(name) { names.append(name) }
    try? names.joined(separator: "\n").write(to: indexURL(), atomically: true, encoding: .utf8)
}

func indexRemove(_ name: String) {
    let names = indexNames().filter { $0 != name }
    try? names.joined(separator: "\n").write(to: indexURL(), atomically: true, encoding: .utf8)
}

func savePassword(_ name: String, appleID: String, password: String) -> Bool {
    // Stored as a single JSON blob: {"appleID":..,"password":..}
    let payload = "{\"appleID\":\"\(appleID)\",\"password\":\"\(password)\"}"
    let (code, _) = sh(["add-generic-password", "-U", "-a", name, "-s", service, "-l", "sswitch \(name)", "-w", payload])
    return code == 0
}

// MARK: - Accessibility primitives

func axValue(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
}

func axString(_ el: AXUIElement, _ attr: String) -> String {
    if let v = axValue(el, attr) { return v as? String ?? "" }
    return ""
}

func axChildren(_ el: AXUIElement) -> [AXUIElement] {
    guard let v = axValue(el, kAXChildrenAttribute as String) as? [AXUIElement] else { return [] }
    return v
}

func axFrame(_ el: AXUIElement) -> CGRect? {
    guard let p = axValue(el, kAXPositionAttribute as String),
          let s = axValue(el, kAXSizeAttribute as String) else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &point)
    AXValueGetValue(s as! AXValue, .cgSize, &size)
    return CGRect(origin: point, size: size)
}

func walk(_ el: AXUIElement, depth: Int = 0, _ visit: (AXUIElement) -> Bool) -> Bool {
    if visit(el) { return true }
    if depth > 14 { return false }
    for c in axChildren(el) { if walk(c, depth: depth + 1, visit) { return true } }
    return false
}

func find(_ root: AXUIElement, _ match: (AXUIElement) -> Bool) -> AXUIElement? {
    var hit: AXUIElement?
    _ = walk(root) { el in
        if match(el) { hit = el; return true }
        return false
    }
    return hit
}

func role(_ el: AXUIElement) -> String { axString(el, kAXRoleAttribute as String) }
func subrole(_ el: AXUIElement) -> String {
    if let v = axValue(el, "AXSubrole") { return v as? String ?? "" }
    return ""
}
func desc(_ el: AXUIElement) -> String { axString(el, kAXDescriptionAttribute as String) }
func title(_ el: AXUIElement) -> String { axString(el, kAXTitleAttribute as String) }
func identifier(_ el: AXUIElement) -> String {
    if let v = axValue(el, "AXIdentifier") { return v as? String ?? "" }
    return ""
}
func placeholder(_ el: AXUIElement) -> String {
    if let v = axValue(el, "AXPlaceholderValue") { return v as? String ?? "" }
    return ""
}
func textValue(_ el: AXUIElement) -> String { axString(el, kAXValueAttribute as String) }

// MARK: - Actions

func press(_ el: AXUIElement) -> Bool {
    if AXUIElementPerformAction(el, kAXPressAction as CFString) == .success { return true }
    guard let f = axFrame(el) else { return false }
    return clickAt(CGPoint(x: f.midX, y: f.midY))
}

func clickAt(_ p: CGPoint) -> Bool {
    guard let src = CGEventSource(stateID: .hidSystemState) else { return false }
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left) else { return false }
        e.post(tap: .cghidEventTap)
        usleep(30000)
    }
    return true
}

func setValue(_ el: AXUIElement, _ s: String) -> Bool {
    AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, s as CFTypeRef) == .success
}

func seTyping(_ text: String) -> Bool {
    // Secure Input drops synthetic CGEvents; only System Events keystrokes reach the field.
    let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "tell application \"System Events\" to keystroke \"\(escaped)\""]
    let errPipe = Pipe()
    p.standardError = errPipe
    do { try p.run() } catch { return false }
    p.waitUntilExit()
    let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    if p.terminationStatus != 0 { log("seTyping err=\(err)") }
    return p.terminationStatus == 0
}

func submitButton(_ root: AXUIElement) -> AXUIElement? {
    find(root) { el in
        if role(el) != kAXButtonRole as String { return false }
        if identifier(el) == "Primary Button" { return true }
        let t = title(el)
        return t == "登录" || t == "登入" || t == "继续" || t == "Continue"
    }
}

@discardableResult
func clickSubmit(_ sheet: AXUIElement) -> Bool {
    guard let b = submitButton(sheet) else { return false }
    if let f = axFrame(b) { return clickAt(CGPoint(x: f.midX, y: f.midY)) }
    return press(b)
}

func focusField(_ app: AXUIElement, _ el: AXUIElement) {
    AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(app, "AXFocusedUIElement" as CFString, el as CFTypeRef)
    if let f = axFrame(el) { _ = clickAt(CGPoint(x: f.midX, y: f.midY)) }
    usleep(120_000)
}

func focusedElement(_ app: AXUIElement) -> AXUIElement? {
    if let v = axValue(app, "AXFocusedUIElement") { return (v as! AXUIElement) }
    return nil
}

func pressReturn() {
    guard let src = CGEventSource(stateID: .hidSystemState) else { return }
    let code: CGKeyCode = 36
    CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
    usleep(25000)
    CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
    _ = code
}

func selectAll() {
    guard let src = CGEventSource(stateID: .hidSystemState) else { return }
    let keyA: CGKeyCode = 0
    let down = CGEvent(keyboardEventSource: src, virtualKey: keyA, keyDown: true)
    down?.flags = .maskCommand
    down?.post(tap: .cghidEventTap)
    usleep(15000)
    let up = CGEvent(keyboardEventSource: src, virtualKey: keyA, keyDown: false)
    up?.flags = .maskCommand
    up?.post(tap: .cghidEventTap)
    usleep(15000)
}

let keyMap: [Character: (CGKeyCode, Bool)] = [
    "a": (0, false), "s": (1, false), "d": (2, false), "f": (3, false), "h": (4, false),
    "g": (5, false), "z": (6, false), "x": (7, false), "c": (8, false), "v": (9, false),
    "b": (11, false), "q": (12, false), "w": (13, false), "e": (14, false), "r": (15, false),
    "y": (16, false), "t": (17, false), "1": (18, false), "2": (19, false), "3": (20, false),
    "4": (21, false), "6": (22, false), "5": (23, false), "9": (25, false), "7": (26, false),
    "8": (28, false), "0": (29, false), "o": (31, false), "u": (32, false), "i": (34, false),
    "p": (35, false), "l": (37, false), "j": (38, false), "k": (40, false), "n": (45, false),
    "m": (46, false), ".": (47, false), "-": (27, false), "=": (24, false), "/": (44, false),
    ";": (41, false), "'": (39, false), ",": (43, false), "\\": (42, false), "`": (50, false),
    " ": (49, false), "[": (33, false), "]": (30, false),
    "A": (0, true), "S": (1, true), "D": (2, true), "F": (3, true), "H": (4, true),
    "G": (5, true), "Z": (6, true), "X": (7, true), "C": (8, true), "V": (9, true),
    "B": (11, true), "Q": (12, true), "W": (13, true), "E": (14, true), "R": (15, true),
    "Y": (16, true), "T": (17, true), "!": (18, true), "@": (19, true), "#": (20, true),
    "$": (21, true), "^": (22, true), "%": (23, true), "(": (25, true), "&": (26, true),
    "*": (28, true), ")": (29, true), "O": (31, true), "U": (32, true), "I": (34, true),
    "P": (35, true), "L": (37, true), "J": (38, true), "K": (40, true), "N": (45, true),
    "M": (46, true), ">": (47, true), "_": (27, true), "+": (24, true), "?": (44, true),
    ":": (41, true), "\"": (39, true), "<": (43, true), "|": (42, true), "~": (50, true),
    "{": (33, true), "}": (30, true),
]

func typeText(_ s: String) {
    guard let src = CGEventSource(stateID: .hidSystemState) else { return }
    for ch in s {
        guard let (code, shift) = keyMap[ch] else {
            var utf16 = Array(String(ch).utf16)
            let d = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
            let u = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
            d?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            u?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            d?.post(tap: .cghidEventTap); u?.post(tap: .cghidEventTap)
            usleep(15000)
            continue
        }
        let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
        if shift { down?.flags = .maskShift; up?.flags = .maskShift }
        down?.post(tap: .cghidEventTap)
        usleep(12000)
        up?.post(tap: .cghidEventTap)
        usleep(18000)
    }
}

// MARK: - App Store semantics

let appStoreBundle = "com.apple.AppStore"

func appStorePID() -> pid_t? {
    NSRunningApplication.runningApplications(withBundleIdentifier: appStoreBundle).first?.processIdentifier
}

@discardableResult
func ensureRunning() -> pid_t? {
    if let pid = appStorePID() { return pid }
    let cfg = NSWorkspace.OpenConfiguration()
    cfg.activates = false
    let sem = DispatchSemaphore(value: 0)
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appStoreBundle) {
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in sem.signal() }
        _ = sem.wait(timeout: .now() + 10)
    }
    for _ in 0..<100 {
        if let pid = appStorePID() { return pid }
        usleep(100_000)
    }
    return appStorePID()
}

func appElement(_ pid: pid_t) -> AXUIElement { AXUIElementCreateApplication(pid) }

func mainWindow(_ app: AXUIElement) -> AXUIElement? {
    if let w = axValue(app, kAXWindowsAttribute as String) as? [AXUIElement], let first = w.first { return first }
    return nil
}

func accountButton(_ app: AXUIElement) -> AXUIElement? {
    find(app) { identifier($0) == "AppStore.accountButton" }
}

func isSignedOut(_ app: AXUIElement) -> Bool {
    guard let b = accountButton(app) else { return true }
    let label = title(b) + desc(b)
    return label.contains("登录") || label.contains("登入") || label.lowercased().contains("sign in")
}

func sheets(_ app: AXUIElement) -> [AXUIElement] {
    var out: [AXUIElement] = []
    if let w = mainWindow(app) {
        if let s = axValue(w, "AXSheets") as? [AXUIElement] { out = s }
        if out.isEmpty { out = axChildren(w).filter { role($0) == kAXSheetRole as String } }
        if out.isEmpty {
            // Some builds nest the sheet one level deeper.
            for c in axChildren(w) where role(c) == kAXSheetRole as String {
                out.append(contentsOf: axChildren(c).filter { role($0) == kAXSheetRole as String })
            }
        }
    }
    if out.isEmpty { out = axChildren(app).filter { role($0) == kAXSheetRole as String } }
    return out
}

@discardableResult
func dismissSheets(_ app: AXUIElement) -> Bool {
    var did = false
    for s in sheets(app) {
        if let cancel = find(s, { role($0) == kAXButtonRole as String && (title($0) == "取消" || title($0) == "Cancel") }) {
            _ = press(cancel); did = true
        }
    }
    return did
}

func menuBarItem(_ app: AXUIElement) -> AXUIElement? {
    log("menuBar children=\(axChildren(app).count)")
    guard let bar = axValue(app, "AXMenuBar") else { return nil }
    let mb = bar as! AXUIElement
    for item in axChildren(mb) {
        let t = title(item)
        if t == "商店" || t == "Store" { return item }
    }
    return nil
}

func menuItem(_ app: AXUIElement, _ kinds: [String]) -> AXUIElement? {
    guard let mbi = menuBarItem(app) else { return nil }
    _ = press(mbi)
    usleep(120_000)
    var hit: AXUIElement?
    _ = walk(mbi) { el in
        if role(el) == kAXMenuItemRole as String {
            let t = title(el)
            for k in kinds where t.contains(k) { hit = el; return true }
        }
        return false
    }
    return hit
}

func clickMenu(_ app: AXUIElement, _ kinds: [String]) -> Bool {
    guard let item = menuItem(app, kinds) else { log("menu item not found") ; return false }
    // AXPress on a menu item is a no-op here; a real mouse click is required.
    if let f = axFrame(item), f.width > 1 {
        _ = clickAt(CGPoint(x: f.midX, y: f.midY))
        log("menu clicked \(title(item)) at \(Int(f.midX)),\(Int(f.midY))")
    } else {
        _ = press(item)
        log("menu pressed (no frame) \(title(item))")
    }
    usleep(200_000)
    return true
}

// MARK: - Switch flow

func log(_ s: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
    let path = NSHomeDirectory() + "/Library/Logs/sswitch.log"
    if let h = FileHandle(forWritingAtPath: path) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

func notify(_ title: String, _ body: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "display notification \"\(body.replacingOccurrences(of: "\"", with: "'"))\" with title \"\(title)\""]
    try? p.run()
}

func waitUntil(_ seconds: Double, _ cond: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if cond() { return true }
        usleep(120_000)
    }
    return cond()
}

enum SwitchError: Error, CustomStringConvertible {
    case noWindow, stuckSignedIn, noLoginSheet, noEmailField, noPasswordField, authFailed(String), timeout
    var description: String {
        switch self {
        case .noWindow: return "App Store window never appeared"
        case .stuckSignedIn: return "could not sign out of the current account"
        case .noLoginSheet: return "sign-in sheet never appeared"
        case .noEmailField: return "Apple ID field not found"
        case .noPasswordField: return "password field not found"
        case .authFailed(let m): return "App Store said: \(m)"
        case .timeout: return "timed out"
        }
    }
}

func allTexts(_ app: AXUIElement) -> String {
    var parts: [String] = []
    _ = walk(app) { el in
        if role(el) == kAXStaticTextRole as String {
            let v = textValue(el)
            if !v.isEmpty { parts.append(v) }
        }
        return false
    }
    return parts.joined(separator: " ")
}

func switchAccount(appleID: String, password: String) throws {
    let t0 = Date()
    guard let pid = ensureRunning() else { throw SwitchError.noWindow }
    let app = appElement(pid)

    let prevFront = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
    let runner = NSRunningApplication(processIdentifier: pid)
    runner?.activate(options: [.activateAllWindows])
    _ = waitUntil(2.0) { mainWindow(app) != nil }
    guard mainWindow(app) != nil else { throw SwitchError.noWindow }
    log("start id=\(appleID)")

    dismissSheets(app)
    usleep(150_000)

    // 1. Sign out if already signed in.
    if !isSignedOut(app) {
        var out = false
        for _ in 0..<3 {
            if clickMenu(app, ["退出登录", "登出", "Sign Out"]) { }
            out = waitUntil(2.0) { isSignedOut(app) }
            if out { break }
            // Fallback: click the account button and look for sign-out in the popover.
            if let btn = accountButton(app), let f = axFrame(btn) {
                _ = clickAt(CGPoint(x: f.midX, y: f.midY))
                usleep(400_000)
                if let item = find(app, { role($0) == kAXButtonRole as String && (title($0).contains("退出登录") || title($0).contains("登出")) }) {
                    _ = press(item)
                }
                out = waitUntil(2.5) { isSignedOut(app) }
                if out { break }
            }
        }
        log("signOut=\(out)")
        if !out { throw SwitchError.stuckSignedIn }
    }

    // 2. Open the sign-in sheet.
    var opened = false
    for _ in 0..<3 {
        _ = clickMenu(app, ["登录", "登入", "Sign In"])
        opened = waitUntil(4.0) {
            guard let s = sheets(app).first else { return false }
            return find(s, { role($0) == kAXTextFieldRole as String || subrole($0) == "AXSecureTextField" }) != nil
        }
        if opened { break }
        log("login sheet retry")
    }
    guard opened, let sheet0 = sheets(app).first else { throw SwitchError.noLoginSheet }

    // 3. Fill in the Apple ID.
    guard let emailField = find(sheet0, {
        (role($0) == kAXTextFieldRole as String) && subrole($0) != "AXSecureTextField" && subrole($0) != "AXSearchField"
    }) else { throw SwitchError.noEmailField }

    if !setValue(emailField, appleID) || textValue(emailField) != appleID {
        focusField(app, emailField)
        selectAll()
        usleep(80_000)
        typeText(appleID)
        usleep(150_000)
    }
    log("email=\(textValue(emailField))")
    focusField(app, emailField)
    if !clickSubmit(sheets(app).first ?? sheet0) { pressReturn() }

    // 4. Wait for the password field.
    let gotPass = waitUntil(8.0) {
        guard let s = sheets(app).first else { return false }
        return find(s, { subrole($0) == "AXSecureTextField" }) != nil
    }
    guard gotPass, let sheet1 = sheets(app).first,
          let passField = find(sheet1, { subrole($0) == "AXSecureTextField" }) else { throw SwitchError.noPasswordField }

    // 5. Type the password (pasting is rejected by the secure field).
    var typedOK = false
    for _ in 0..<3 {
        focusField(app, passField)
        usleep(200_000)
        if let fe = focusedElement(app), subrole(fe) == "AXSecureTextField" {
            selectAll()
            usleep(60_000)
            typedOK = seTyping(password)
        } else {
            log("secure field not focused, retry")
        }
        if typedOK { break }
    }
    log("typed=\(typedOK)")
    usleep(300_000)
    if !clickSubmit(sheets(app).first ?? sheet1) { pressReturn() }
    log("frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") ; passSubmitted; frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")

    // 6. Decide the outcome.
    let errWords = ["错误", "錯誤", "不正确", "不正確", "无法", "無法", "失败", "失敗", "Error", "incorrect"]
    var hinted = false
    var goneCount = 0
    let deadline = Date().addingTimeInterval(120)
    while Date() < deadline {
        usleep(300_000)
        if isSignedOut(app) == false && sheets(app).isEmpty {
            log("verdict=completed in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
            if prevFront != "" { NSRunningApplication.runningApplications(withBundleIdentifier: "").first?.activate() }
            if let prev = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == prevFront }) {
                prev.activate(options: [])
            }
            return
        }
        if sheets(app).isEmpty && isSignedOut(app) {
            goneCount += 1
            if goneCount >= 22 { log("verdict=sheet dismissed"); throw SwitchError.authFailed("sign-in sheet was dismissed (Apple ID or password rejected)") }
        } else { goneCount = 0 }
        if !sheets(app).isEmpty {
            let text = allTexts(app)
            if let hit = errWords.first(where: { text.contains($0) }) {
                log("verdict=failed \(hit) text=\(text)")
                throw SwitchError.authFailed(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if !hinted && Date().timeIntervalSince(t0) > 14 {
                hinted = true
                log("waiting manual step")
                notify("App Store needs verification", "Enter the 6-digit code. The window stays open for 2 minutes.")
            }
        }
    }
    log("verdict=timeout")
    throw SwitchError.timeout
}

// MARK: - CLI

func usage() {
    print("""
    sswitch — switch the macOS App Store account from the terminal

      sswitch add <name> <apple-id>   store credentials in the keychain
      sswitch list                    list stored accounts
      sswitch rm <name>               remove one
      sswitch <name>                  switch to it (about 8 seconds, no window)
      sswitch --id <apple-id> --password <pwd>
                                      switch with explicit credentials
                                      (used by GUI wrappers such as StoreSwitch)

    Example:
      sswitch add hk you@example.com
      sswitch hk
    """)
}

func askPassword() -> String? {
    print("Password (hidden): ", terminator: "")
    var old = termios()
    var t = termios()
    tcgetattr(0, &old)
    t = old
    t.c_lflag &= ~UInt(ECHO)
    tcsetattr(0, TCSANOW, &t)
    let line = readLine()
    tcsetattr(0, TCSANOW, &old)
    print("")
    return line
}

let args = Array(CommandLine.arguments.dropFirst())

if args.isEmpty || args[0] == "-h" || args[0] == "--help" {
    usage(); exit(0)
}

switch args[0] {
case "add":
    guard args.count >= 3 else { usage(); exit(2) }
    guard let pw = askPassword(), !pw.isEmpty else { print("no password read"); exit(1) }
    if savePassword(args[1], appleID: args[2], password: pw) {
        indexAdd(args[1])
        print("saved \(args[1]) -> \(args[2])")
    } else {
        print("save failed"); exit(1)
    }
case "list":
    let names = indexNames()
    if names.isEmpty { print("(no accounts yet — run: sswitch add NAME APPLE_ID)") }
    for n in names {
        if let raw = readPassword(n), let d = raw.data(using: .utf8),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: String],
           let id = o["appleID"] {
            print("\(n)\t\(id)")
        } else {
            print("\(n)\t(keychain entry missing)")
        }
    }
case "rm":
    guard args.count >= 2 else { usage(); exit(2) }
    let (code, _) = sh(["delete-generic-password", "-s", service, "-a", args[1]])
    indexRemove(args[1])
    print(code == 0 ? "deleted \(args[1])" : "delete failed (no such account?)")
case "--id":
    guard args.count >= 4, args[2] == "--password" else { usage(); exit(2) }
    do {
        try switchAccount(appleID: args[1], password: args[3])
        print("completed"); exit(0)
    } catch {
        if "\(error)".contains("dismissed") {
            log("retry once after rejection")
            if (try? switchAccount(appleID: args[1], password: args[3])) != nil { print("completed"); exit(0) }
        }
        print("needs_attention: \(error)"); notify("App Store switch failed", "\(error)"); exit(3)
    }
default:
    let name = args[0]
    guard let raw = readPassword(name), let data = raw.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
          let appleID = obj["appleID"], let pw = obj["password"] else {
        print("no account named \(name) — run: sswitch add \(name) <APPLE_ID>")
        exit(2)
    }
    do {
        do {
            try switchAccount(appleID: appleID, password: pw)
        } catch {
            if "\(error)".contains("dismissed") {
                log("retry once after rejection")
                try switchAccount(appleID: appleID, password: pw)
            } else { throw error }
        }
        print("completed: \(appleID)")
        notify("App Store switched", "Now signed in as \(appleID)")
        exit(0)
    } catch {
        print("needs_attention: \(error)")
        notify("App Store switch incomplete", "\(error)")
        exit(3)
    }
}
