// html-popup-viewer — show an HTML page in a native macOS window.
//
// Usage: html-popup-viewer PAGE.html --session DIR [--data FILE]
//          [--title TEXT] [--size WxH] [--timeout SEC] [--test-script FILE]
//
// Called only by scripts/html-popup.sh, which builds this file into the
// "HTML Popup" app on first use and launches it with open(1). Session files
// in DIR: `pid`, `in` (FIFO), `events.jsonl` (one JSON event per line),
// `viewer.log`, and `abandoned` once the wrapper gave up waiting for us.
//
// Each line written to `in` is a JSON value passed to the page's
// `htmlPopup.onMessage` handlers; `{"htmlPopup":"close"}` closes the window.
//
// The page talks back through `window.htmlPopup` (see `bridgeSource`).
//
// Exit codes: 0 normal close, 2 usage error, 3 page or data invalid,
// 4 --timeout reached. Every close path except a usage error appends one
// `closed` event with a `reason` before exiting.

import AppKit
import WebKit

struct Options {
    var page: String
    var session: String
    var data: String?
    var title: String?
    var width = 980
    var height = 640
    var timeout: Double?
    var testScript: String?
}

struct ViewerError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

let usage = """
    usage: html-popup-viewer PAGE.html --session DIR [--data FILE] \
    [--title TEXT] [--size WxH] [--timeout SEC] [--test-script FILE]
    """

func parseSize(_ text: String) -> (Int, Int)? {
    let parts = text.split(separator: "x")
    guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]),
        w > 0, h > 0
    else { return nil }
    return (w, h)
}

func parseOptions(_ args: [String]) throws -> Options {
    var page: String?
    var session: String?
    var data: String?
    var title: String?
    var size: (Int, Int)?
    var timeout: Double?
    var testScript: String?

    var rest = args[...]
    func value(for flag: String) throws -> String {
        guard let next = rest.popFirst() else {
            throw ViewerError(message: "\(flag) needs a value")
        }
        return next
    }

    while let arg = rest.popFirst() {
        switch arg {
        case "--session": session = try value(for: arg)
        case "--data": data = try value(for: arg)
        case "--title": title = try value(for: arg)
        case "--test-script": testScript = try value(for: arg)
        case "--size":
            let text = try value(for: arg)
            guard let parsed = parseSize(text) else {
                throw ViewerError(message: "bad --size: \(text)")
            }
            size = parsed
        case "--timeout":
            let text = try value(for: arg)
            guard let seconds = Double(text), seconds > 0 else {
                throw ViewerError(message: "bad --timeout: \(text)")
            }
            timeout = seconds
        default:
            if arg.hasPrefix("--") {
                throw ViewerError(message: "unknown option: \(arg)")
            }
            if page != nil {
                throw ViewerError(message: "unexpected argument: \(arg)")
            }
            page = arg
        }
    }

    guard let page else { throw ViewerError(message: "missing PAGE") }
    guard let session else { throw ViewerError(message: "missing --session") }
    var options = Options(page: page, session: session)
    options.data = data
    options.title = title
    if let size { (options.width, options.height) = size }
    options.timeout = timeout
    options.testScript = testScript
    return options
}

func log(_ text: String) {
    FileHandle.standardError.write(Data("html-popup-viewer: \(text)\n".utf8))
}

func errnoText() -> String { String(cString: strerror(errno)) }

func jsonString(_ text: String) -> String {
    let data = try? JSONSerialization.data(
        withJSONObject: text,
        options: [.fragmentsAllowed, .withoutEscapingSlashes])
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
}

enum CloseReason: String {
    case answer, cancel, user, agent, timeout, error

    var exitCode: Int32 {
        switch self {
        case .error: return 3
        case .timeout: return 4
        default: return 0
        }
    }
}

// Appends events to DIR/events.jsonl. Each line goes out in a single
// write() on an O_APPEND descriptor, so readers never see a torn line.
// Used from the main thread only.
final class EventLog {
    private let fd: Int32
    private var seq = 0
    private var closed = false

    init(path: String) throws {
        fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else {
            throw ViewerError(message: "cannot open \(path): \(errnoText())")
        }
    }

    // `data` is raw JSON text and is written as-is.
    func append(_ type: String, reason: CloseReason? = nil, data: String? = nil,
                message: String? = nil) {
        seq += 1
        var line = "{\"seq\":\(seq),\"type\":\(jsonString(type))"
        if let reason { line += ",\"reason\":\(jsonString(reason.rawValue))" }
        if let data { line += ",\"data\":\(data)" }
        if let message { line += ",\"message\":\(jsonString(message))" }
        line += "}\n"
        let bytes = Array(line.utf8)
        if write(fd, bytes, bytes.count) != bytes.count {
            log("event write failed: \(errnoText())")
        }
    }

    // Write exactly one `closed` event, then exit.
    func close(_ reason: CloseReason, message: String? = nil) -> Never {
        if !closed {
            closed = true
            if let message { log(message) }
            append("closed", reason: reason, message: message)
        }
        exit(reason.exitCode)
    }
}

// Prepare the session dir: FIFO, pid file, events. stderr is not touched:
// the launcher (open --stderr) sends it to DIR/viewer.log, so option errors
// that come before this point land there too.
func startSession(_ dir: String) throws -> (events: EventLog, inbound: Int32) {
    try FileManager.default.createDirectory(
        atPath: dir, withIntermediateDirectories: true)

    let fifo = dir + "/in"
    if mkfifo(fifo, 0o600) != 0 && errno != EEXIST {
        throw ViewerError(message: "cannot create \(fifo): \(errnoText())")
    }
    // Read-write, so the open does not block waiting for a writer and reads
    // never hit EOF when a writer goes away.
    let inbound = open(fifo, O_RDWR)
    guard inbound >= 0 else {
        throw ViewerError(message: "cannot open \(fifo): \(errnoText())")
    }
    // open(1) does not report our pid, so the wrapper reads it from here.
    try "\(getpid())\n".write(
        toFile: dir + "/pid", atomically: true, encoding: .utf8)
    return (try EventLog(path: dir + "/events.jsonl"), inbound)
}

// Reads DIR/in on a background thread and hands each complete line to
// `deliver` on the main thread. Writes over PIPE_BUF are not atomic, so a
// line can span several reads and is buffered until its newline arrives.
func startInboundReader(fd: Int32, deliver: @escaping (Data) -> Void) {
    let thread = Thread {
        var pending = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else {
                log("inbound read stopped: \(count < 0 ? errnoText() : "EOF")")
                return
            }
            pending.append(contentsOf: chunk[0..<count])
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(pending[pending.startIndex..<newline])
                pending.removeSubrange(pending.startIndex...newline)
                DispatchQueue.main.async { deliver(line) }
            }
        }
    }
    thread.name = "html-popup inbound"
    thread.start()
}

enum Inbound {
    case close
    case message(String)
}

// Classify one inbound line. Returns nil for blank or invalid lines.
func parseInbound(_ line: Data) -> Inbound? {
    guard let text = String(data: line, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
    else { return nil }
    guard let value = try? JSONSerialization.jsonObject(
        with: Data(text.utf8), options: .fragmentsAllowed)
    else {
        log("dropped inbound line that is not JSON: \(text.prefix(200))")
        return nil
    }
    if let object = value as? [String: String],
        object == ["htmlPopup": "close"]
    {
        return .close
    }
    return .message(text)
}

// Read and validate --data. Returns the JSON text, kept as-is so numbers
// reach the page exactly as written. Require UTF-8 without a BOM: the page
// decodes it with JSON.parse.
func loadData(_ path: String) throws -> String {
    guard var bytes = FileManager.default.contents(atPath: path) else {
        throw ViewerError(
            message: "data file not found or not readable: \(path)")
    }
    if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
    guard let text = String(data: bytes, encoding: .utf8),
        (try? JSONSerialization.jsonObject(
            with: bytes, options: .fragmentsAllowed)) != nil
    else {
        throw ViewerError(
            message: "data file is not valid JSON (UTF-8 expected): \(path)")
    }
    return text
}

let messageHandlerName = "htmlPopup"

// Injected at document start. Values cross the bridge as JSON.stringify
// strings in both directions, so numbers and top-level scalars survive.
func bridgeSource(dataJSON: String?) -> String {
    let data = dataJSON.map { "JSON.parse(\(jsonString($0)))" } ?? "null"
    return """
        (() => {
          const post = (type, value) => window.webkit.messageHandlers
            .\(messageHandlerName).postMessage({
              type,
              value: value === undefined ? "null" : JSON.stringify(value),
            });
          const handlers = [];
          const popup = {
            data: \(data),
            closeOnEscape: true,
            answer: (value) => post("answer", value),
            cancel: () => post("cancel"),
            send: (value) => post("send", value),
            onMessage: (fn) => { handlers.push(fn); },
            // Called by the viewer with one JSON text per inbound message.
            _receive: (text) => {
              const value = JSON.parse(text);
              for (const fn of handlers) {
                try { fn(value); } catch (e) { console.error(e); }
              }
            },
          };
          Object.defineProperty(window, "htmlPopup", { value: popup });

          const editable = (el) => !!el && (el.isContentEditable ||
            ["INPUT", "TEXTAREA", "SELECT"].includes(el.tagName));
          // Decide after dispatch ends, so page listeners added later on
          // document or window can still call preventDefault().
          document.addEventListener("keydown", (event) => {
            if (event.key !== "Escape") return;
            if (editable(document.activeElement)) return;
            setTimeout(() => {
              if (event.defaultPrevented || !popup.closeOnEscape) return;
              post("escape");
            }, 0);
          });
        })();
        """
}

// The page fills the window up to its top edge, so the web view would
// swallow drags in the title bar area. This strip gives them back.
final class TitleBarDragView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

final class Viewer: NSObject, NSApplicationDelegate, NSWindowDelegate,
    WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler
{
    private let options: Options
    private let pageURL: URL
    private let dataJSON: String?
    private let events: EventLog
    private var window: NSWindow?
    private var webView: WKWebView?
    private var isReady = false

    private var testMode: Bool { options.testScript != nil }

    init(options: Options, pageURL: URL, dataJSON: String?, events: EventLog) {
        self.options = options
        self.pageURL = pageURL
        self.dataJSON = dataJSON
        self.events = events
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()

        let frame = NSRect(
            x: 0, y: 0, width: options.width, height: options.height)
        let window = makeWindow(frame: frame)
        let web = makeWebView(frame: frame)

        let titleBarHeight: CGFloat = 32
        let dragStrip = TitleBarDragView(frame: NSRect(
            x: 0, y: frame.height - titleBarHeight,
            width: frame.width, height: titleBarHeight))
        dragStrip.autoresizingMask = [.width, .minYMargin]

        let container = NSView(frame: frame)
        container.addSubview(web)
        container.addSubview(dragStrip)
        window.contentView = container
        window.center()
        self.window = window
        self.webView = web

        if testMode {
            // Ordered front but invisible, not hidden: WebKit then keeps
            // visibilityState=visible with timers and rAF running.
            window.alphaValue = 0
            window.orderFrontRegardless()
        } else {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            window.makeFirstResponder(web)
            if #available(macOS 14, *) {
                NSApp.activate()
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        if let timeout = options.timeout {
            let deadline = DispatchTime.now() + timeout
            DispatchQueue.main.asyncAfter(deadline: deadline) { [events] in
                events.close(.timeout)
            }
        }

        web.loadFileURL(
            pageURL, allowingReadAccessTo: pageURL.deletingLastPathComponent())
    }

    private func makeWindow(frame: NSRect) -> NSWindow {
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable,
                        .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = options.title ?? pageURL.lastPathComponent
        window.isReleasedWhenClosed = false
        // A regular app with a fixed bundle id would get saved-state restore.
        window.isRestorable = false
        window.delegate = self
        return window
    }

    private func makeWebView(frame: NSRect) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let content = configuration.userContentController
        content.add(self, name: messageHandlerName)
        content.addUserScript(WKUserScript(
            source: bridgeSource(dataJSON: dataJSON),
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = WKWebView(frame: frame, configuration: configuration)
        web.autoresizingMask = [.width, .height]
        web.navigationDelegate = self
        web.uiDelegate = self
        return web
    }

    // The app has no nib, so no menu; without one, inputs lose the standard
    // Edit shortcuts and Cmd-W does nothing.
    private func makeMainMenu() -> NSMenu {
        func item(_ title: String, _ action: Selector, _ key: String,
                  _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(
                title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            top.submenu = menu
            return top
        }

        let main = NSMenu()
        main.addItem(submenu("HTML Popup", [
            item("Quit", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        main.addItem(submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ]))
        main.addItem(submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ]))
        return main
    }

    // The close button and Cmd-W both arrive here.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        events.close(.user)
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        events.close(.user)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if options.title == nil, let title = webView.title, !title.isEmpty {
            window?.title = title
        }
        guard !isReady else { return }
        isReady = true
        events.append("ready")
        runTestScript(in: webView)
    }

    func receive(_ line: Data) {
        switch parseInbound(line) {
        case .close?:
            events.close(.agent)
        case .message(let text)?:
            // The wrapper prints DIR only after ready, so no flow sends
            // earlier.
            if isReady {
                deliverToPage(text)
            } else {
                log("dropped inbound message that arrived before ready")
            }
        case nil:
            break
        }
    }

    // The JSON text goes in as a string literal and is JSON.parse'd by the
    // bridge, so agent data is never evaluated as page source.
    private func deliverToPage(_ json: String) {
        let script = "window.htmlPopup._receive(\(jsonString(json)))"
        webView?.evaluateJavaScript(script) { _, error in
            if let error { log("message delivery failed: \(error)") }
        }
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        navigationFailed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                 withError error: Error) {
        navigationFailed(error)
    }

    // Without this the window would go blank and never report a close.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        events.close(.error, message: "web content process terminated")
    }

    private func navigationFailed(_ error: Error) {
        // Cancelled navigations include http links handed to the browser.
        if (error as NSError).code == NSURLErrorCancelled { return }
        let text = "page failed to load: \(error.localizedDescription)"
        if !isReady { events.close(.error, message: text) }
        log(text)
    }

    // Web links open in the default browser; the popup only shows local files.
    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = action.request.url,
            let scheme = url.scheme?.lowercased()
        else {
            decisionHandler(.cancel)
            return
        }
        switch scheme {
        case "file", "about", "data", "blob":
            decisionHandler(.allow)
        case "http", "https":
            // A remote iframe is blocked quietly instead of opening a tab.
            if action.targetFrame?.isMainFrame ?? true {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        default:
            log("blocked navigation to \(url.absoluteString)")
            decisionHandler(.cancel)
        }
    }

    // target=_blank links and window.open() land here.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = action.request.url,
            ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        // Handlers are exposed to every frame; an embedded iframe must not
        // be able to answer or close on the page's behalf.
        guard message.frameInfo.isMainFrame else {
            log("dropped bridge message from a child frame")
            return
        }
        guard let body = message.body as? [String: Any],
            let type = body["type"] as? String
        else {
            log("dropped malformed bridge message: \(message.body)")
            return
        }
        switch type {
        case "send", "answer":
            guard let value = eventData(body["value"]) else {
                log("dropped \(type) with a value that is not one-line JSON")
                return
            }
            if type == "send" {
                events.append("message", data: value)
            } else {
                events.append("answer", data: value)
                events.close(.answer)
            }
        case "cancel":
            events.close(.cancel)
        case "escape":
            events.close(.user)
        default:
            log("dropped unknown bridge message type: \(type)")
        }
    }

    // The bridge sends single-line JSON.stringify output. Pages can also
    // post directly, so reject anything that is not JSON on one line. Only
    // a raw "\n" splits an event line; U+2028 and friends are fine.
    private func eventData(_ value: Any?) -> String? {
        guard let text = value as? String,
            !text.utf8.contains(UInt8(ascii: "\n")),
            !text.hasPrefix("\u{FEFF}"),
            !hasTrailingComma(text),
            (try? JSONSerialization.jsonObject(
                with: Data(text.utf8), options: .fragmentsAllowed)) != nil
        else { return nil }
        return text
    }

    // JSONSerialization accepts `[1,]` and `{"a":1,}`, which jq and
    // JSON.parse reject; one such line would break readers of the log.
    private func hasTrailingComma(_ text: String) -> Bool {
        var inString = false, escaped = false, afterComma = false
        for byte in text.utf8 {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }
            switch byte {
            case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\r"):
                continue
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                if afterComma { return true }
            case UInt8(ascii: "\""):
                inString = true
            default:
                break
            }
            afterComma = byte == UInt8(ascii: ",")
        }
        return false
    }

    private func runTestScript(in webView: WKWebView) {
        guard let path = options.testScript else { return }
        guard let source = try? String(contentsOfFile: path, encoding: .utf8)
        else {
            log("cannot read test script: \(path)")
            return
        }
        webView.evaluateJavaScript(source) { _, error in
            if let error { log("test script failed: \(error)") }
        }
    }
}

let options: Options
do {
    options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
} catch {
    log("\(error.localizedDescription)\n\(usage)")
    exit(2)
}

let session: (events: EventLog, inbound: Int32)
do {
    session = try startSession(options.session)
} catch {
    log("cannot set up session: \(error.localizedDescription)")
    exit(2)
}
let events = session.events

// The wrapper already reported this session as failed and wrote its closed
// event; a late viewer must not open an untracked window.
func exitIfAbandoned() {
    if FileManager.default.fileExists(atPath: options.session + "/abandoned") {
        log("session abandoned by the wrapper; exiting")
        exit(3)
    }
}
exitIfAbandoned()

let pageURL = URL(fileURLWithPath: options.page).standardizedFileURL
var inputError: String?
var dataJSON: String?
if !FileManager.default.isReadableFile(atPath: pageURL.path) {
    inputError = "page not found or not readable: \(options.page)"
} else if let dataPath = options.data {
    do {
        dataJSON = try loadData(dataPath)
    } catch {
        inputError = error.localizedDescription
    }
}

// A macOS access prompt for protected folders can block the reads above;
// an abandoned session already has its closed event.
exitIfAbandoned()
if let inputError { events.close(.error, message: inputError) }

let app = NSApplication.shared
// Focus on launch needs a regular app; headless test windows stay out of
// the Dock and Cmd-Tab.
app.setActivationPolicy(options.testScript != nil ? .accessory : .regular)
let viewer = Viewer(
    options: options, pageURL: pageURL, dataJSON: dataJSON, events: events)
app.delegate = viewer
startInboundReader(fd: session.inbound, deliver: viewer.receive)
app.run()
