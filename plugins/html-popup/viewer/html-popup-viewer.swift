// html-popup-viewer — show an HTML page in a native macOS window.
//
// Usage: html-popup-viewer PAGE.html --session DIR [--data FILE]
//          [--title TEXT] [--size WxH] [--timeout SEC] [--test-script FILE]
//
// Called only by scripts/html-popup.sh, which compiles this file on first
// use. Session files in DIR: `pid`, `in` (FIFO), `events.jsonl` (one JSON
// event per line), `viewer.log`.
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

enum UsageError: Error {
    case message(String)
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
            throw UsageError.message("\(flag) needs a value")
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
                throw UsageError.message("bad --size: \(text)")
            }
            size = parsed
        case "--timeout":
            let text = try value(for: arg)
            guard let seconds = Double(text), seconds > 0 else {
                throw UsageError.message("bad --timeout: \(text)")
            }
            timeout = seconds
        default:
            if arg.hasPrefix("--") {
                throw UsageError.message("unknown option: \(arg)")
            }
            if page != nil {
                throw UsageError.message("unexpected argument: \(arg)")
            }
            page = arg
        }
    }

    guard let page else { throw UsageError.message("missing PAGE") }
    guard let session else { throw UsageError.message("missing --session") }
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
        withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes])
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
            throw UsageError.message("cannot open \(path): \(errnoText())")
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

// Prepare the session dir: own session, log, FIFO, pid file, events.
func startSession(_ dir: String) throws -> EventLog {
    // Leave the caller's process group so a killed agent shell or a Ctrl-C
    // in it does not take the window down. Fails harmlessly if we already
    // lead a group.
    _ = setsid()

    try FileManager.default.createDirectory(
        atPath: dir, withIntermediateDirectories: true)

    let logPath = dir + "/viewer.log"
    if freopen(logPath, "a", stderr) == nil {
        throw UsageError.message("cannot open \(logPath): \(errnoText())")
    }

    let fifo = dir + "/in"
    if mkfifo(fifo, 0o600) != 0 && errno != EEXIST {
        throw UsageError.message("cannot create \(fifo): \(errnoText())")
    }
    try "\(getpid())\n".write(toFile: dir + "/pid", atomically: true, encoding: .utf8)
    return try EventLog(path: dir + "/events.jsonl")
}

// Read and validate --data. Returns the JSON text, kept as-is so numbers
// reach the page exactly as written.
func loadData(_ path: String) throws -> String {
    guard let bytes = FileManager.default.contents(atPath: path) else {
        throw UsageError.message("data file not found or not readable: \(path)")
    }
    do {
        _ = try JSONSerialization.jsonObject(with: bytes, options: .fragmentsAllowed)
    } catch {
        throw UsageError.message("data file is not valid JSON: \(path)")
    }
    return String(decoding: bytes, as: UTF8.self)
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
          document.addEventListener("keydown", (event) => {
            if (event.key !== "Escape" || event.defaultPrevented) return;
            if (!popup.closeOnEscape || editable(document.activeElement)) return;
            post("escape");
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

        let frame = NSRect(x: 0, y: 0, width: options.width, height: options.height)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable,
                        .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = options.title ?? pageURL.lastPathComponent
        window.isReleasedWhenClosed = false
        window.delegate = self

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

        if testMode {
            // Ordered front but invisible, not hidden: WebKit then keeps
            // visibilityState=visible with timers and rAF running.
            window.alphaValue = 0
            window.orderFrontRegardless()
        } else {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(web)
            NSApp.activate(ignoringOtherApps: true)
        }

        if let timeout = options.timeout {
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [events] in
                events.close(.timeout)
            }
        }

        web.loadFileURL(
            pageURL, allowingReadAccessTo: pageURL.deletingLastPathComponent())
    }

    // An unbundled binary has no menu; without one, inputs lose the standard
    // Edit shortcuts and Cmd-W does nothing.
    private func makeMainMenu() -> NSMenu {
        func item(_ title: String, _ action: Selector, _ key: String,
                  _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
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
        main.addItem(submenu("html-popup", [
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
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

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        navigationFailed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                 withError error: Error) {
        navigationFailed(error)
    }

    private func navigationFailed(_ error: Error) {
        // Cancelled navigations include http links handed to the browser.
        if (error as NSError).code == NSURLErrorCancelled { return }
        let text = "page failed to load: \(error.localizedDescription)"
        if !isReady { events.close(.error, message: text) }
        log(text)
    }

    // Web links open in the default browser; the popup only shows local files.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else {
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
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url,
            ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
            let type = body["type"] as? String
        else {
            log("dropped malformed bridge message: \(message.body)")
            return
        }
        switch type {
        case "send", "answer":
            guard let value = eventData(body["value"]) else {
                log("dropped \(type) with a value that is not JSON")
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

    // The bridge sends JSON.stringify output; pages can also post directly,
    // so check it is JSON and fits on one event line.
    private func eventData(_ value: Any?) -> String? {
        guard let text = value as? String,
            let object = try? JSONSerialization.jsonObject(
                with: Data(text.utf8), options: .fragmentsAllowed)
        else { return nil }
        if !text.contains(where: \.isNewline) { return text }
        let compact = try? JSONSerialization.data(
            withJSONObject: object, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return compact.flatMap { String(data: $0, encoding: .utf8) }
    }

    private func runTestScript(in webView: WKWebView) {
        guard let path = options.testScript else { return }
        guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
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
} catch UsageError.message(let text) {
    log("\(text)\n\(usage)")
    exit(2)
}

let events: EventLog
do {
    events = try startSession(options.session)
} catch UsageError.message(let text) {
    log(text)
    exit(2)
} catch {
    log("cannot set up session: \(error.localizedDescription)")
    exit(2)
}

let pageURL = URL(fileURLWithPath: options.page).standardizedFileURL
if !FileManager.default.isReadableFile(atPath: pageURL.path) {
    events.close(.error, message: "page not found or not readable: \(options.page)")
}

var dataJSON: String?
if let dataPath = options.data {
    do {
        dataJSON = try loadData(dataPath)
    } catch UsageError.message(let text) {
        events.close(.error, message: text)
    }
}

let app = NSApplication.shared
// No app bundle: run as an accessory so the window can show and take focus
// without a Dock icon.
app.setActivationPolicy(.accessory)
let viewer = Viewer(options: options, pageURL: pageURL, dataJSON: dataJSON, events: events)
app.delegate = viewer
app.run()
