import UIKit
import WebKit
import AVFoundation

/// Schlanke Hülle um das Spiel: Die HTML-Datei liegt in der App (web/index.html)
/// und läuft in einem WKWebView. Die App fragt nur die Projektseite nach einer neueren
/// Spieldatei (siehe GameUpdater); ohne Netz läuft die vorhandene Fassung.
final class GameViewController: UIViewController, WKNavigationDelegate, WKUIDelegate,
                                WKScriptMessageHandler, UIDocumentPickerDelegate {

    private static let scheme = "trainerbank"
    private static let startURL = URL(string: "trainerbank://app/index.html")!
    private static let bg = UIColor(red: 15 / 255, green: 90 / 255, blue: 84 / 255, alpha: 1)

    private var web: WKWebView!
    private var pendingSaveURL: URL?
    private var pendingUpdate: String?

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Self.bg

        // Ton wie bei einem Spiel: Der Stummschalter am Gerät gilt, fremde Musik läuft weiter.
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)

        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()                       // Spielstand bleibt auf dem Gerät erhalten
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.setURLSchemeHandler(BundleSchemeHandler(), forURLScheme: Self.scheme)

        // Brücke zum Spiel: window.TBApp (wie in der Android-App)
        let bridge = """
        window.TBApp = {
          ios: true,
          saveFile: function (name, json) {
            window.webkit.messageHandlers.tb.postMessage({ a: 'save', name: String(name), json: String(json) });
          },
          haptic: function (kind) {
            window.webkit.messageHandlers.tb.postMessage({ a: 'haptic', kind: String(kind || '') });
          },
          checkUpdate: function () {
            window.webkit.messageHandlers.tb.postMessage({ a: 'upd' });
          }
        };
        """
        let noSelect = """
        (function () {
          var s = document.createElement('style');
          s.textContent = 'html,body{-webkit-touch-callout:none;-webkit-user-select:none;overscroll-behavior:none}' +
                          'input,textarea{-webkit-user-select:text}';
          document.documentElement.appendChild(s);
        })();
        """
        cfg.userContentController.addUserScript(
            WKUserScript(source: bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        cfg.userContentController.addUserScript(
            WKUserScript(source: noSelect, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        cfg.userContentController.add(WeakHandler(self), name: "tb")

        web = WKWebView(frame: .zero, configuration: cfg)

        // Zurück aus dem Hintergrund: Tonsitzung wieder aktivieren und das Spiel den Ton aufwecken lassen
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            try? AVAudioSession.sharedInstance().setActive(true)
            self?.web.evaluateJavaScript("window.TBWake && window.TBWake()", completionHandler: nil)
            self?.checkUpdate()
        }
        web.navigationDelegate = self
        web.uiDelegate = self
        web.isOpaque = false
        web.backgroundColor = Self.bg
        web.scrollView.backgroundColor = Self.bg
        web.scrollView.bounces = false
        web.scrollView.alwaysBounceVertical = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.showsHorizontalScrollIndicator = false
        web.allowsBackForwardNavigationGestures = false
        web.allowsLinkPreview = false
        web.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(web)

        // Inhalt nicht unter Statusleiste, Notch oder Home-Balken schieben
        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: g.topAnchor),
            web.bottomAnchor.constraint(equalTo: g.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: g.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: g.trailingAnchor)
        ])

        web.load(URLRequest(url: Self.startURL))
        checkUpdate(force: true)
    }

    // MARK: Aktualisierung der Spieldatei

    /// Fragt die Projektseite nach einer neueren Spieldatei. Liegt eine vor, wird sie geladen und das Spiel
    /// bietet den Neustart an. `notify` meldet dem Spiel auch, wenn es nichts Neues gibt.
    private func checkUpdate(force: Bool = false, notify: Bool = false) {
        GameUpdater.shared.check(force: force) { [weak self] build in
            guard let self = self else { return }
            if let build = build {
                self.pendingUpdate = build
                self.announceUpdate()
            } else if notify {
                self.web.evaluateJavaScript("window.TBNoUpdate && window.TBNoUpdate()", completionHandler: nil)
            }
        }
    }

    private func announceUpdate() {
        guard let build = pendingUpdate,
              let json = try? JSONSerialization.data(withJSONObject: [build]),
              let arg = String(data: json, encoding: .utf8) else { return }
        web.evaluateJavaScript("window.TBUpdate && window.TBUpdate(\(arg)[0])", completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        announceUpdate()
    }

    // MARK: Navigation – die App bleibt bei der eigenen Spieldatei

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { return decisionHandler(.cancel) }
        if url.scheme == Self.scheme || url.scheme == "about" || url.scheme == "blob" || url.scheme == "data" {
            return decisionHandler(.allow)
        }
        decisionHandler(.cancel)
    }

    /// Falls iOS den Webinhalt wegen Speichermangel beendet: Spiel neu laden (der Spielstand ist gesichert).
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.load(URLRequest(url: Self.startURL))
    }

    // MARK: Meldungen des Spiels (alert / confirm / prompt)

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(a, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Abbrechen", style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        present(a, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let a = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        a.addTextField { $0.text = defaultText }
        a.addAction(UIAlertAction(title: "Abbrechen", style: .cancel) { _ in completionHandler(nil) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(a.textFields?.first?.text) })
        present(a, animated: true)
    }

    // MARK: Brücke

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let action = body["a"] as? String else { return }
        switch action {
        case "save":
            saveFile(name: body["name"] as? String ?? "trainerbank-spielstand.json",
                     json: body["json"] as? String ?? "")
        case "haptic":
            let kind = body["kind"] as? String ?? ""
            if kind == "goal" {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        case "upd":
            checkUpdate(force: true, notify: true)
        default:
            break
        }
    }

    /// Spielstand sichern: Datei anlegen und den Speicherort vom Nutzer wählen lassen (Dateien-App).
    private func saveFile(name: String, json: String) {
        let safe = name.replacingOccurrences(of: "/", with: "-")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(safe)
        do {
            try json.data(using: .utf8)?.write(to: tmp, options: .atomic)
        } catch {
            return saved(false)
        }
        pendingSaveURL = tmp
        let picker = UIDocumentPickerViewController(forExporting: [tmp], asCopy: true)
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        cleanup()
        saved(true)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        cleanup()
        saved(false)
    }

    private func cleanup() {
        if let u = pendingSaveURL { try? FileManager.default.removeItem(at: u) }
        pendingSaveURL = nil
    }

    private func saved(_ ok: Bool) {
        web.evaluateJavaScript("window.tbSaved&&window.tbSaved(\(ok ? "true" : "false"))", completionHandler: nil)
    }
}

/// Liefert die mitgelieferten Dateien aus dem Ordner web/ der App aus.
/// Eine feste Adresse (trainerbank://app/…) sorgt dafür, dass der Spielstand zuverlässig erhalten bleibt.
final class BundleSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            return task.didFailWithError(URLError(.badURL))
        }
        var path = url.path
        if path.isEmpty || path == "/" { path = "/index.html" }
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        // Nur Dateien direkt aus web/ – keine Unterordner, kein Zugriff nach außen.
        // Die Spieldatei selbst kommt in der neuesten vorhandenen Fassung (geladen oder mitgeliefert).
        let found: Data?
        if name == "index.html" {
            found = GameUpdater.shared.indexData()
        } else if !name.contains(".."), let file = Bundle.main.url(forResource: base, withExtension: ext, subdirectory: "web") {
            found = try? Data(contentsOf: file)
        } else {
            found = nil
        }
        guard let data = found else {
            return task.didFailWithError(URLError(.fileDoesNotExist))
        }
        let mime: String
        switch ext.lowercased() {
        case "html": mime = "text/html"
        case "json": mime = "application/json"
        case "js": mime = "text/javascript"
        case "css": mime = "text/css"
        case "png": mime = "image/png"
        default: mime = "application/octet-stream"
        }
        let headers = [
            "Content-Type": mime + (mime.hasPrefix("text/") ? "; charset=utf-8" : ""),
            "Content-Length": String(data.count),
            "Cache-Control": "no-store"
        ]
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(resp)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

/// Hält das Spiel aktuell: prüft auf der Projektseite, ob eine neuere Spieldatei vorliegt, lädt sie und
/// legt sie in der App ab. Ohne Netz läuft die zuletzt geladene oder die mitgelieferte Fassung.
/// Übertragen wird dabei nichts außer der Abfrage selbst.
final class GameUpdater {
    static let shared = GameUpdater()

    private static let base = URL(string: "https://emilazar82.github.io/trainerbank/")!
    private struct Stamp: Codable { let b: String; let t: Double }   // version.json, z. B. {"b":"18.11. 17:26","t":1795019202}

    private let dir: URL
    private var busy = false
    private var lastCheck = Date.distantPast

    private init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = root.appendingPathComponent("web", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private var cachedFile: URL { dir.appendingPathComponent("index.html") }
    private var stampFile: URL { dir.appendingPathComponent("stamp.json") }

    private func read(_ url: URL) -> Stamp? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Stamp.self, from: data)
    }

    private var bundled: Stamp? {
        guard let url = Bundle.main.url(forResource: "version", withExtension: "json", subdirectory: "web") else { return nil }
        return read(url)
    }

    private var cached: Stamp? {
        FileManager.default.fileExists(atPath: cachedFile.path) ? read(stampFile) : nil
    }

    private var current: Double { max(cached?.t ?? 0, bundled?.t ?? 0) }

    /// Die Spieldatei, die ausgeliefert wird: die geladene, wenn sie neuer ist als die mitgelieferte.
    func indexData() -> Data? {
        if let c = cached, c.t > (bundled?.t ?? 0), let data = try? Data(contentsOf: cachedFile) {
            return data
        }
        guard let file = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "web") else { return nil }
        return try? Data(contentsOf: file)
    }

    /// Prüft höchstens einmal pro Stunde (außer mit `force`). `done` läuft auf dem Hauptthread und bekommt
    /// den Stand der neu geladenen Fassung oder nil.
    func check(force: Bool, done: @escaping (String?) -> Void) {
        if busy || (!force && Date().timeIntervalSince(lastCheck) < 3600) { return done(nil) }
        busy = true
        lastCheck = Date()
        let session = URLSession(configuration: .ephemeral)
        let have = current
        let versionReq = URLRequest(url: Self.base.appendingPathComponent("version.json"),
                                    cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        session.dataTask(with: versionReq) { [weak self] data, resp, _ in
            guard let self = self else { return }
            guard let data = data, (resp as? HTTPURLResponse)?.statusCode == 200 else {
                return self.finish(nil, retrySoon: true, done)   // kein Netz: bald noch einmal versuchen
            }
            guard let remote = try? JSONDecoder().decode(Stamp.self, from: data), remote.t > have else {
                return self.finish(nil, retrySoon: false, done)
            }
            let htmlReq = URLRequest(url: Self.base.appendingPathComponent("index.html"),
                                     cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
            session.dataTask(with: htmlReq) { html, resp2, _ in
                // Nur eine vollständige Spieldatei mit genau dem angekündigten Stand wird übernommen.
                guard let html = html, (resp2 as? HTTPURLResponse)?.statusCode == 200, html.count > 500_000,
                      html.range(of: Data("var BUILD = '\(remote.b)'".utf8)) != nil,
                      html.range(of: Data("<script id=\"logic\">".utf8)) != nil else {
                    return self.finish(nil, retrySoon: true, done)
                }
                do {
                    try html.write(to: self.cachedFile, options: .atomic)
                    try data.write(to: self.stampFile, options: .atomic)
                    self.finish(remote.b, retrySoon: false, done)
                } catch {
                    self.finish(nil, retrySoon: true, done)
                }
            }.resume()
        }.resume()
    }

    private func finish(_ build: String?, retrySoon: Bool, _ done: @escaping (String?) -> Void) {
        DispatchQueue.main.async {
            self.busy = false
            if retrySoon { self.lastCheck = Date().addingTimeInterval(-3300) }   // in fünf Minuten noch einmal
            done(build)
        }
    }
}

/// Verhindert, dass der WebView den Controller dauerhaft festhält.
final class WeakHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        target?.userContentController(c, didReceive: m)
    }
}
