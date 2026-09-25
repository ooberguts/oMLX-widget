import AppKit
import WebKit
import IOKit

// ── Config ───────────────────────────────────────────────────────────────────
let kHome    = FileManager.default.homeDirectoryForCurrentUser.path
/// Root of the AI tree. Override with OMLX_HOME if yours lives elsewhere.
let kRoot    = ProcessInfo.processInfo.environment["OMLX_HOME"] ?? "\(kHome)/AI"
let kBase    = ProcessInfo.processInfo.environment["OMLX_URL"] ?? "http://127.0.0.1:8000"
let kCtl     = "\(kRoot)/omlx/bin/omlxctl"
let kRepo    = "ooberguts/oMLX-widget"
let kPoll    = 1.5
/// Stable name clients ask for; whichever model holds this alias answers.
let kAlias   = "local"

// ── Shell helper ─────────────────────────────────────────────────────────────
@discardableResult
func shell(_ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-lc", args.joined(separator: " ")]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return "error: \(error.localizedDescription)" }
    let d = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: d, encoding: .utf8) ?? ""
}

// ── GPU ──────────────────────────────────────────────────────────────────────
/// Live GPU utilisation from the IOKit accelerator's PerformanceStatistics.
/// This is the same number `ioreg -c AGXAccelerator` prints, read directly so
/// we are not spawning a process on every poll.
func gpuUtilization() -> Double? {
    for cls in ["AGXAccelerator", "IOAccelerator"] {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &it) == KERN_SUCCESS
        else { continue }
        defer { IOObjectRelease(it) }

        var svc = IOIteratorNext(it)
        while svc != 0 {
            defer { IOObjectRelease(svc); svc = IOIteratorNext(it) }
            var raw: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(svc, &raw, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let props = raw?.takeRetainedValue() as? [String: Any],
                  let perf = props["PerformanceStatistics"] as? [String: Any]
            else { continue }
            if let u = perf["Device Utilization %"] as? Int { return Double(u) }
            if let u = perf["GPU Activity(%)"] as? Int { return Double(u) }
        }
    }
    return nil
}

// ── Networking ───────────────────────────────────────────────────────────────
func getJSON(_ path: String, _ done: @escaping (Any?) -> Void) {
    guard let url = URL(string: kBase + path) else { return done(nil) }
    var r = URLRequest(url: url)
    r.timeoutInterval = 3
    URLSession.shared.dataTask(with: r) { d, _, _ in
        guard let d = d, let j = try? JSONSerialization.jsonObject(with: d) else { return done(nil) }
        done(j)
    }.resume()
}

func sendJSON(_ method: String, _ path: String, body: [String: Any]? = nil,
              timeout: TimeInterval = 120, _ done: @escaping (Any?) -> Void) {
    guard let url = URL(string: kBase + path) else { return done(nil) }
    var r = URLRequest(url: url)
    r.httpMethod = method
    r.timeoutInterval = timeout
    r.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let b = body { r.httpBody = try? JSONSerialization.data(withJSONObject: b) }
    URLSession.shared.dataTask(with: r) { d, _, _ in
        done(d.flatMap { try? JSONSerialization.jsonObject(with: $0) })
    }.resume()
}

func postJSON(_ path: String, _ done: @escaping (Any?) -> Void) {
    guard let url = URL(string: kBase + path) else { return done(nil) }
    var r = URLRequest(url: url)
    r.httpMethod = "POST"
    r.timeoutInterval = 120
    r.setValue("application/json", forHTTPHeaderField: "Content-Type")
    URLSession.shared.dataTask(with: r) { d, _, _ in
        done(d.flatMap { try? JSONSerialization.jsonObject(with: $0) })
    }.resume()
}

// ── Updater ──────────────────────────────────────────────────────────────────
/// Source-based self-update. The bundle records the commit it was built from;
/// we compare that against the tip of `main` on GitHub, then download that
/// commit's tarball, rebuild with build.sh, and hot-swap the bundle.
enum Updater {
    static var currentCommit: String {
        (Bundle.main.object(forInfoDictionaryKey: "OMLXWidgetCommit") as? String) ?? "unknown"
    }
    static var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
    }

    /// Ask GitHub for the tip of main.
    static func check(_ done: @escaping (_ latest: String?, _ subject: String?) -> Void) {
        guard let url = URL(string: "https://api.github.com/repos/\(kRepo)/commits/main") else {
            return done(nil, nil)
        }
        var r = URLRequest(url: url)
        r.timeoutInterval = 12
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: r) { d, _, _ in
            guard let d = d,
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let sha = j["sha"] as? String else { return done(nil, nil) }
            let msg = ((j["commit"] as? [String: Any])?["message"] as? String)?
                .components(separatedBy: "\n").first
            done(sha, msg)
        }.resume()
    }

    /// Download `sha`, build it, and swap it in. `log` reports progress.
    static func apply(sha: String, log: @escaping (String) -> Void,
                      done: @escaping (Bool, String) -> Void) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("omlx-widget-update-\(sha.prefix(7))")
        try? fm.removeItem(at: tmp)
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        let tarURL = URL(string: "https://codeload.github.com/\(kRepo)/tar.gz/\(sha)")!
        log("downloading…")
        URLSession.shared.downloadTask(with: tarURL) { loc, resp, err in
            guard let loc = loc,
                  (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false
            else { return done(false, "download failed: \(err?.localizedDescription ?? "bad response")") }

            let tgz = tmp.appendingPathComponent("src.tar.gz")
            try? fm.moveItem(at: loc, to: tgz)

            log("extracting…")
            guard run("/usr/bin/tar", ["-xzf", tgz.path, "-C", tmp.path]).0 == 0 else {
                return done(false, "extract failed")
            }
            // GitHub tarballs unpack into a single <repo>-<sha> directory.
            guard let root = (try? fm.contentsOfDirectory(atPath: tmp.path))?
                    .first(where: { $0.hasPrefix("oMLX-widget-") }) else {
                return done(false, "unexpected archive layout")
            }
            let srcDir = tmp.appendingPathComponent(root)
            let script = srcDir.appendingPathComponent("build.sh")
            guard fm.fileExists(atPath: script.path) else {
                return done(false, "build.sh missing from archive")
            }
            _ = run("/bin/chmod", ["+x", script.path])

            // Build into a staging bundle first so a failure cannot destroy the
            // installed app.
            let staged = tmp.appendingPathComponent("oMLX Widget.app")
            log("building…")
            var env = ProcessInfo.processInfo.environment
            env["OMLX_WIDGET_APP"] = staged.path
            let (code, out) = run("/bin/zsh", [script.path], env: env, cwd: srcDir.path)
            guard code == 0, fm.fileExists(atPath: staged.path) else {
                return done(false, "build failed: \(out.suffix(160))")
            }

            // Swap after we exit: the running bundle cannot replace itself.
            let installed = Bundle.main.bundleURL.path
            let swap = tmp.appendingPathComponent("swap.sh")
            let sh = """
            #!/bin/zsh
            while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.3; done
            rm -rf "\(installed)"
            mv "\(staged.path)" "\(installed)"
            sleep 0.4
            open "\(installed)"
            """
            try? sh.write(to: swap, atomically: true, encoding: .utf8)
            _ = run("/bin/chmod", ["+x", swap.path])

            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = [swap.path]
            try? p.run()   // detached; it waits for us to quit

            done(true, "restarting…")
        }.resume()
    }

    @discardableResult
    static func run(_ exe: String, _ args: [String],
                    env: [String: String]? = nil, cwd: String? = nil) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let e = env { p.environment = e }
        if let c = cwd { p.currentDirectoryURL = URL(fileURLWithPath: c) }
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: d, encoding: .utf8) ?? "")
    }
}

// ── Main menu ────────────────────────────────────────────────────────────────
/// Without a menu bar, AppKit never matches Cmd-key equivalents, so Cmd+V and
/// Cmd+A silently do nothing in text fields. These items carry the standard
/// selectors; the responder chain delivers them to the focused web view.
func buildMainMenu() {
    let main = NSMenu()

    let appItem = NSMenuItem()
    main.addItem(appItem)
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "About oMLX Widget", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Hide oMLX Widget", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    appMenu.addItem(withTitle: "Quit oMLX Widget", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu

    let editItem = NSMenuItem()
    main.addItem(editItem)
    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Undo",       action: Selector(("undo:")),        keyEquivalent: "z")
    let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")),   keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    edit.addItem(.separator())
    edit.addItem(withTitle: "Cut",        action: #selector(NSText.cut(_:)),       keyEquivalent: "x")
    edit.addItem(withTitle: "Copy",       action: #selector(NSText.copy(_:)),      keyEquivalent: "c")
    edit.addItem(withTitle: "Paste",      action: #selector(NSText.paste(_:)),     keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = edit

    NSApp.mainMenu = main
}

// ── Drag surface ─────────────────────────────────────────────────────────────
/// WKWebView consumes every mouse event, so `isMovableByWindowBackground` never
/// triggers over web content. A transparent view above the web view restores it.
final class DragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    // Double-click the drag strip = the usual titlebar zoom/minimise behaviour.
    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 { window?.performZoom(nil) }
    }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
    // The strips overlap the scrollable page; forward the wheel so scrolling still works.
    override func scrollWheel(with event: NSEvent) {
        (superview?.subviews.first as? WKWebView)?.scrollWheel(with: event)
    }
}

// ── Per-model TPS extremes ───────────────────────────────────────────────────
/// oMLX persists per-model averages but not peak/low, so the widget observes
/// the live decode rate and keeps its own extremes on disk.
struct TpsStat: Codable { var peak: Double = 0; var low: Double = 0; var samples: Int = 0 }

final class StatStore {
    private(set) var stats: [String: TpsStat] = [:]
    private let url = URL(fileURLWithPath: "\(kRoot)/omlx/data/widget-tps.json")
    private var dirty = false

    init() {
        if let d = try? Data(contentsOf: url),
           let s = try? JSONDecoder().decode([String: TpsStat].self, from: d) { stats = s }
    }

    /// Record a live sample. Zero means idle — not a real low.
    func observe(_ model: String, _ tps: Double) {
        guard tps > 0.01 else { return }
        var st = stats[model] ?? TpsStat()
        st.peak = max(st.peak, tps)
        st.low = st.low == 0 ? tps : min(st.low, tps)
        st.samples += 1
        stats[model] = st
        dirty = true
    }

    func reset(_ model: String) { stats[model] = nil; dirty = true; flush() }

    func flush() {
        guard dirty, let d = try? JSONEncoder().encode(stats) else { return }
        try? d.write(to: url, options: .atomic)
        dirty = false
    }
}

// ── App ──────────────────────────────────────────────────────────────────────
final class Controller: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    var window: NSWindow!
    var web: WKWebView!
    var timer: Timer?
    var ready = false
    let store = StatStore()
    var lifetime: [String: [String: Any]] = [:]   // model -> alltime stats
    var loadBase: [String: Int] = [:]             // model -> completion tokens when it loaded
    var tickN = 0
    var flushN = 0

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMainMenu()
        let cfg = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.add(self, name: "bridge")
        cfg.userContentController = ucc
        cfg.setValue(true, forKey: "drawsBackground")

        web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "oMLX"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.10, alpha: 1)
        window.minSize = NSSize(width: 320, height: 380)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 700))
        web.frame = container.bounds
        web.autoresizingMask = [.width, .height]
        container.addSubview(web)

        // Full-width strip along the very top.
        let topStrip = DragView(frame: NSRect(x: 0, y: 700 - 26, width: 380, height: 26))
        topStrip.autoresizingMask = [.width, .minYMargin]
        container.addSubview(topStrip)

        // The title row, stopping short of the Start/Stop button on the right.
        let titleStrip = DragView(frame: NSRect(x: 0, y: 700 - 26 - 36, width: 380 - 96, height: 36))
        titleStrip.autoresizingMask = [.width, .minYMargin]
        container.addSubview(titleStrip)

        window.contentView = container
        window.setFrameAutosaveName("OMLXWidgetWindow")
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let html = Bundle.main.url(forResource: "index", withExtension: "html")!
        web.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
    }

    func webView(_ w: WKWebView, didFinish nav: WKNavigation!) {
        ready = true
        tick()
        call("window.onVersion", ["version": Updater.version,
                                  "commit": String(Updater.currentCommit.prefix(7))])
        // one quiet check a few seconds in, so startup is not blocked
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            Updater.check { latest, subject in
                guard let latest = latest else { return }
                let cur = Updater.currentCommit
                guard cur != "unknown", cur != latest else { return }
                DispatchQueue.main.async {
                    self.call("window.onUpdate", [
                        "current": String(cur.prefix(7)), "latest": String(latest.prefix(7)),
                        "sha": latest, "version": Updater.version,
                        "available": true, "unknown": false, "subject": subject ?? "",
                    ])
                }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: kPoll, repeats: true) { [weak self] _ in self?.tick() }
    }

    // Collect all three endpoints, then push one snapshot to the page.
    func tick() {
        guard ready else { return }
        let group = DispatchGroup()
        var activity: Any?, tasks: Any?, models: Any?, stats: Any?
        let gpu = gpuUtilization()

        group.enter(); getJSON("/admin/api/activity")   { activity = $0; group.leave() }
        group.enter(); getJSON("/admin/api/hf/tasks")   { tasks    = $0; group.leave() }
        group.enter(); getJSON("/v1/models/status")     { models   = $0; group.leave() }
        group.enter(); getJSON("/admin/api/stats")      { stats    = $0; group.leave() }

        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            let up = activity != nil || models != nil
            var snap: [String: Any] = ["up": up, "t": Date().timeIntervalSince1970, "alias": kAlias]
            if let g = gpu { snap["gpu"] = g }
            if let a = activity as? [String: Any], let am = a["active_models"] { snap["activity"] = am }
            if let t = tasks as? [String: Any], let tt = t["tasks"] { snap["tasks"] = tt }
            if let m = models as? [String: Any] { snap["models"] = m }
            // Observe live decode rate per model for peak/low.
            if let am = (activity as? [String: Any])?["active_models"] as? [String: Any],
               let rows = am["models"] as? [[String: Any]] {
                for r in rows {
                    guard let id = r["id"] as? String else { continue }
                    let gen = (r["generating"] as? [[String: Any]]) ?? []
                    let tps = gen.reduce(0.0) { $0 + (($1["tokens_per_second"] as? Double) ?? 0) }
                    self.store.observe(id, tps)
                }
            }

            // Track load baselines so "since loaded" resets on unload.
            if let ms = (models as? [String: Any])?["models"] as? [[String: Any]] {
                for m in ms {
                    guard let id = m["id"] as? String else { continue }
                    let loaded = (m["loaded"] as? Bool) ?? false
                    if !loaded {
                        self.loadBase[id] = nil
                    } else if self.loadBase[id] == nil {
                        let n = (self.lifetime[id]?["completion"] as? Int) ?? 0
                        self.loadBase[id] = n
                    }
                }
            }

            // Attach the cached lifetime numbers plus the widget's own extremes.
            var per: [String: Any] = [:]
            for (id, lt) in self.lifetime {
                var row = lt
                if let st = self.store.stats[id] {
                    row["peak"] = st.peak
                    row["low"] = st.low
                }
                if let base = self.loadBase[id], let now = lt["completion"] as? Int {
                    row["since_load"] = max(0, now - base)
                }
                per[id] = row
            }
            snap["per"] = per

            self.flushN += 1
            if self.flushN % 10 == 0 { self.store.flush() }

            if let st = stats as? [String: Any] {
                // only the counters the graphs need — the full payload is large
                snap["stats"] = [
                    "completion_tokens": st["total_completion_tokens"] ?? 0,
                    "prompt_tokens":     st["total_prompt_tokens"] ?? 0,
                    "requests":          st["total_requests"] ?? 0,
                    "avg_gen_tps":       st["avg_generation_tps"] ?? 0,
                    "avg_prefill_tps":   st["avg_prefill_tps"] ?? 0,
                    "cache_efficiency":  st["cache_efficiency"] ?? 0,
                ]
            }
            self.push(snap)

            self.tickN += 1
            if self.tickN % 4 == 1,
               let ms = (models as? [String: Any])?["models"] as? [[String: Any]] {
                self.refreshLifetime(ms.compactMap { $0["id"] as? String })
            }
        }
    }

    /// Per-model persisted totals. Cheap but not worth polling at 1.5s, so this
    /// runs every fourth tick.
    func refreshLifetime(_ ids: [String]) {
        for id in ids {
            getJSON("/admin/api/stats?scope=alltime&model=\(enc(id))") { [weak self] r in
                guard let self = self, let d = r as? [String: Any] else { return }
                DispatchQueue.main.async {
                    self.lifetime[id] = [
                        "completion": (d["total_completion_tokens"] as? Int) ?? 0,
                        "prompt":     (d["total_prompt_tokens"] as? Int) ?? 0,
                        "requests":   (d["total_requests"] as? Int) ?? 0,
                        "avg":        (d["avg_generation_tps"] as? Double) ?? 0,
                    ]
                }
            }
        }
    }

    func push(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: d, encoding: .utf8) else { return }
        let esc = s.replacingOccurrences(of: "\\", with: "\\\\")
                   .replacingOccurrences(of: "'", with: "\\'")
        web.evaluateJavaScript("window.render && window.render(JSON.parse('\(esc)'))", completionHandler: nil)
    }

    /// Percent-encode a single path/query component.
    func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._~"))) ?? s
    }

    /// Invoke a JS function with one JSON argument.
    func call(_ fn: String, _ arg: Any) {
        guard let d = try? JSONSerialization.data(withJSONObject: arg, options: [.fragmentsAllowed]),
              let j = String(data: d, encoding: .utf8) else { return }
        let esc = j.replacingOccurrences(of: "\\", with: "\\\\")
                   .replacingOccurrences(of: "'", with: "\\'")
        web.evaluateJavaScript("\(fn) && \(fn)(JSON.parse('\(esc)'))", completionHandler: nil)
    }

    func toast(_ msg: String) {
        let esc = msg.replacingOccurrences(of: "'", with: "")
        web.evaluateJavaScript("window.toast && window.toast('\(esc)')", completionHandler: nil)
    }

    func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let body = m.body as? [String: Any], let action = body["action"] as? String else { return }
        let arg = body["arg"] as? String ?? ""

        switch action {
        case "start", "stop", "restart":
            toast("\(action)ing server…")
            DispatchQueue.global().async {
                let out = shell([kCtl, action])
                DispatchQueue.main.async { self.toast(out.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
        case "load":
            toast("loading \(arg)…")
            postJSON("/v1/models/\(arg)/load") { _ in DispatchQueue.main.async { self.tick() } }
        case "unload":
            toast("unloading \(arg)…")
            postJSON("/v1/models/\(arg)/unload") { _ in DispatchQueue.main.async { self.tick() } }
        case "copy":
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(arg, forType: .string)
            let n = arg.split(separator: "\n").count
            toast(n > 1 ? "copied \(n) lines" : "copied")
        case "delete":
            toast("deleting \(arg)…")
            sendJSON("DELETE", "/admin/api/hf/models/\(enc(arg))", timeout: 300) { r in
                DispatchQueue.main.async {
                    let ok = (r as? [String: Any])?["success"] as? Bool ?? true
                    let detail = (r as? [String: Any])?["detail"] as? String
                    self.toast(detail ?? (ok ? "deleted \(arg)" : "delete failed"))
                    self.tick()
                }
            }
        case "download":
            let repo = arg.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !repo.isEmpty else { return toast("enter a repo id") }
            toast("queuing \(repo)…")
            sendJSON("POST", "/admin/api/hf/download", body: ["repo_id": repo]) { r in
                DispatchQueue.main.async {
                    let d = r as? [String: Any]
                    self.toast((d?["detail"] as? String) ?? "queued \(repo)")
                    self.tick()
                }
            }
        case "cancel":
            sendJSON("POST", "/admin/api/hf/cancel/\(enc(arg))") { _ in
                DispatchQueue.main.async { self.toast("cancelled"); self.tick() }
            }
        case "search":
            let q = arg.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else { return }
            toast("searching…")
            getJSON("/admin/api/hf/search?limit=25&mlx_only=true&q=\(enc(q))") { r in
                DispatchQueue.main.async {
                    let list = (r as? [String: Any])?["models"] ?? []
                    self.call("window.onSearch", list)
                }
            }
        case "serve":
            let target = arg
            toast("routing '\(kAlias)' to \(target)…")
            // Move the alias: clear it wherever it sits, then set it on the target.
            getJSON("/v1/models/status") { st in
                let models = (st as? [String: Any])?["models"] as? [[String: Any]] ?? []
                let holders = models.compactMap { m -> String? in
                    guard let id = m["id"] as? String,
                          (m["model_alias"] as? String) == kAlias, id != target else { return nil }
                    return id
                }
                let group = DispatchGroup()
                for id in holders {
                    group.enter()
                    sendJSON("PUT", "/admin/api/models/\(self.enc(id))/settings",
                             body: ["model_alias": NSNull()]) { _ in group.leave() }
                }
                group.notify(queue: .main) {
                    sendJSON("PUT", "/admin/api/models/\(self.enc(target))/settings",
                             body: ["model_alias": kAlias]) { _ in
                        DispatchQueue.main.async {
                            self.toast("'\(kAlias)' → \(target)")
                            self.tick()
                        }
                    }
                }
            }
        case "resetStats":
            store.reset(arg)
            toast("reset tps extremes for \(arg)")
            tick()
        case "checkUpdate":
            toast("checking for updates…")
            Updater.check { latest, subject in
                DispatchQueue.main.async {
                    guard let latest = latest else {
                        self.call("window.onUpdate", ["error": "could not reach GitHub"]); return
                    }
                    let cur = Updater.currentCommit
                    self.call("window.onUpdate", [
                        "current": String(cur.prefix(7)),
                        "latest": String(latest.prefix(7)),
                        "sha": latest,
                        "version": Updater.version,
                        "available": cur != latest && cur != "unknown",
                        "unknown": cur == "unknown",
                        "subject": subject ?? "",
                    ])
                }
            }
        case "applyUpdate":
            toast("updating…")
            Updater.apply(sha: arg,
                          log: { m in DispatchQueue.main.async { self.toast(m) } },
                          done: { ok, msg in
                DispatchQueue.main.async {
                    self.toast(msg)
                    if ok {
                        self.store.flush()
                        // the swap script is waiting for this process to exit
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { NSApp.terminate(nil) }
                    }
                }
            })
        case "admin":
            NSWorkspace.shared.open(URL(string: kBase + "/admin")!)
        case "pin":
            let on = (body["arg"] as? String) == "1"
            self.window.level = on ? .floating : .normal
        case "logs":
            NSWorkspace.shared.open(URL(fileURLWithPath: "\(kRoot)/logs"))
        default: break
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ a: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ n: Notification) { store.flush() }
}

let app = NSApplication.shared
let c = Controller()
app.delegate = c
app.setActivationPolicy(.regular)
app.run()
