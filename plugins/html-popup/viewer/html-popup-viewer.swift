// html-popup-viewer — show an HTML page in a native macOS window.
//
// Usage: html-popup-viewer PAGE.html --session DIR [--data FILE]
//          [--title TEXT] [--size WxH] [--timeout SEC] [--test-script FILE]
//
// Called only by scripts/html-popup.sh, which compiles this file on first
// use. Exit codes: 0 normal close, 2 usage error, 3 page or data invalid,
// 4 --timeout reached.

import Foundation

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

do {
    _ = try parseOptions(Array(CommandLine.arguments.dropFirst()))
} catch UsageError.message(let text) {
    FileHandle.standardError.write(Data("html-popup-viewer: \(text)\n\(usage)\n".utf8))
    exit(2)
}

// The window is not implemented yet.
exit(0)
