import AppKit
import Foundation
import WebKit

/// Bridges `webkit.messageHandlers.mirage` back to the view.
///
/// `WKUserContentController` keeps a strong reference to every message handler it
/// is given, and the configuration outlives the web view, so handing it the view
/// directly would keep a torn-down wallpaper alive. The weak hop breaks that.
private final class WebWallpaperBridge: NSObject, WKScriptMessageHandler {
    weak var view: WebWallpaperView?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        view?.handleBridgeMessage(body)
    }
}

/// Runs a Wallpaper Engine *web* wallpaper: a local HTML page plus the small
/// JavaScript API those pages expect the host to provide.
///
/// None of that API exists in WebKit, so it is injected at document start and
/// driven from here. Everything the page can reach is treated as hostile input:
/// values are sanitised before they cross into JavaScript, and every callback the
/// page installs is invoked inside a `try` on the JavaScript side so one broken
/// wallpaper cannot take the host API down with it.
final class WebWallpaperView: NSView, WKNavigationDelegate {
    private let webView: WKWebView
    private let bridge = WebWallpaperBridge()
    /// Read access is granted to this folder and file requests resolve inside it.
    private let wallpaperFolder: URL
    private let indexURL: URL

    /// Every user property seen so far, so a reload or a late listener still gets
    /// the complete set rather than the last delta.
    private var properties: [String: Any]
    private var muted: Bool
    private var paused = false
    private var pointer = CGPoint(x: 0.5, y: 0.5)
    private var lastPointerSend: CFTimeInterval = 0
    private var isStopped = false
    /// A web view has no per-frame hook to sample the cursor from, the way the
    /// scene view samples it in `draw`, so it polls instead. `updatePointer`
    /// throttles and ignores an unmoved cursor, so an idle desktop costs nothing.
    private var pointerTimer: Timer?

    private static let messageHandlerName = "mirage"

    /// `url` is the wallpaper's index.html. `properties` are the wallpaper's user
    /// properties, delivered to the page as Wallpaper Engine delivers them.
    init(url: URL, properties: [String: Any], muted: Bool) {
        self.indexURL = url
        self.wallpaperFolder = WebWallpaperView.folder(containing: url)
        self.properties = properties
        self.muted = muted

        let configuration = WKWebViewConfiguration()
        // Wallpapers start their own music and video without a click, which is the
        // whole point of them; muting is handled per media element instead.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.suppressesIncrementalRendering = false
        configuration.preferences.isTextInteractionEnabled = false
        // Many web wallpapers fetch their own JSON/shader files with XHR, which
        // WebKit refuses for file:// documents unless these flags are set. They are
        // private, so only poke them when the setter really exists.
        WebWallpaperView.setPrivateFlag(configuration.preferences, "allowFileAccessFromFileURLs", true)
        WebWallpaperView.setPrivateFlag(configuration, "allowUniversalAccessFromFileURLs", true)

        let script = WKUserScript(source: WebWallpaperView.bridgeScript,
                                  injectionTime: .atDocumentStart,
                                  forMainFrameOnly: false)
        configuration.userContentController.addUserScript(script)

        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: .zero)

        bridge.view = self
        configuration.userContentController.add(bridge, name: WebWallpaperView.messageHandlerName)

        wantsLayer = true
        // The window behind us is opaque black; the page is what should be seen, so
        // the web view must not paint its own white sheet over the desktop before
        // the first frame of the wallpaper exists.
        layer?.backgroundColor = NSColor.black.cgColor
        WebWallpaperView.setPrivateFlag(webView, "drawsBackground", false)
        webView.underPageBackgroundColor = .clear
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.navigationDelegate = self
        webView.autoresizingMask = [.width, .height]
        webView.frame = bounds
        addSubview(webView)

        webView.loadFileURL(url, allowingReadAccessTo: wallpaperFolder)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func layout() {
        super.layout()
        webView.frame = bounds
    }

    /// The wallpaper lives behind the desktop icons and must never take a click,
    /// which is also the cheapest way to disable interaction with the page.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: Host API

    /// Freezes the page without tearing anything down.
    ///
    /// Deliberately simple: the injected shim holds `requestAnimationFrame`
    /// callbacks instead of running them, pauses playing media, stops the audio
    /// pump and fires `wallpaperPause`. That covers the frame loops real wallpapers
    /// use. CSS animations and pages driven purely by `setInterval` keep running,
    /// which is a known and accepted gap. The view stays visible so the last frame
    /// remains on screen rather than going black.
    func setPaused(_ paused: Bool) {
        guard paused != self.paused else { return }
        self.paused = paused
        if paused { stopPointerTimer() } else { startPointerTimer() }
        evaluate("window.__mirage.setPaused(\(paused ? "true" : "false"));")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, !paused, !isStopped { startPointerTimer() } else { stopPointerTimer() }
    }

    private func startPointerTimer() {
        guard pointerTimer == nil, !isStopped else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            self?.samplePointer()
        }
        // The desktop has no run loop activity of its own, so the timer has to
        // keep firing through menu tracking and window drags.
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
    }

    private func stopPointerTimer() {
        pointerTimer?.invalidate()
        pointerTimer = nil
    }

    private func samplePointer() {
        guard let window, !isStopped else { return }
        let frame = window.frame
        guard frame.width > 0, frame.height > 0 else { return }
        let point = NSEvent.mouseLocation
        updatePointer(CGPoint(x: (point.x - frame.minX) / frame.width,
                              y: 1 - (point.y - frame.minY) / frame.height))
    }

    func setMuted(_ muted: Bool) {
        self.muted = muted
        evaluate("window.__mirage.setMuted(\(muted ? "true" : "false"));")
    }

    /// Merges `properties` into what the page has already been given and delivers
    /// the change, in Wallpaper Engine's shape.
    func updateProperties(_ properties: [String: Any]) {
        for (key, value) in properties { self.properties[key] = value }
        guard let payload = WebWallpaperView.userPropertyPayload(properties) else { return }
        evaluate("window.__mirage.userProperties(\(payload));")
    }

    /// Normalised cursor position, `(0,0)` at the top-left of the wallpaper.
    ///
    /// Throttled to roughly 30 Hz: each update also synthesises a `mousemove` for
    /// pages that follow the cursor through DOM events, and those handlers are not
    /// always cheap.
    func updatePointer(_ normalized: CGPoint) {
        guard normalized.x.isFinite, normalized.y.isFinite else { return }
        let x = min(1, max(0, normalized.x))
        let y = min(1, max(0, normalized.y))
        let now = CACurrentMediaTime()
        let moved = abs(x - pointer.x) > 0.0005 || abs(y - pointer.y) > 0.0005
        guard moved, now - lastPointerSend > 0.03 else { return }
        pointer = CGPoint(x: x, y: y)
        lastPointerSend = now
        evaluate(String(format: "window.__mirage.setPointer(%.5f, %.5f);", x, y))
    }

    /// Leaves nothing running: the page is replaced by a blank document and the
    /// delegate and message handler are dropped so no callback can reach a view
    /// that is on its way out.
    func stop() {
        guard !isStopped else { return }
        isStopped = true
        stopPointerTimer()
        webView.navigationDelegate = nil
        bridge.view = nil
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: WebWallpaperView.messageHandlerName)
        controller.removeAllUserScripts()
        webView.stopLoading()
        if let blank = URL(string: "about:blank") {
            webView.load(URLRequest(url: blank))
        }
    }

    deinit { pointerTimer?.invalidate() }

    // MARK: Navigation

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !isStopped else { return }
        if let payload = WebWallpaperView.generalPropertyPayload() {
            evaluate("window.__mirage.generalProperties(\(payload));")
        }
        if let payload = WebWallpaperView.userPropertyPayload(properties) {
            evaluate("window.__mirage.userProperties(\(payload));")
        }
        evaluate("window.__mirage.setMuted(\(muted ? "true" : "false"));")
        if paused {
            evaluate("window.__mirage.setPaused(true);")
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("Mirage: web wallpaper %@ failed: %@", indexURL.lastPathComponent, String(describing: error))
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        NSLog("Mirage: web wallpaper %@ could not load: %@", indexURL.lastPathComponent, String(describing: error))
    }

    /// The page may load whatever resources and iframes it likes, but it may not
    /// replace itself: a wallpaper that navigates the main frame to a remote page
    /// would put an uncontrolled document on the desktop.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.targetFrame?.isMainFrame ?? false else {
            decisionHandler(.allow)
            return
        }
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if url.isFileURL || url.scheme == "about" {
            decisionHandler(.allow)
        } else {
            NSLog("Mirage: blocked web wallpaper navigation to %@", url.absoluteString)
            decisionHandler(.cancel)
        }
    }

    // MARK: Bridge

    fileprivate func handleBridgeMessage(_ body: [String: Any]) {
        guard !isStopped, let type = body["type"] as? String else { return }
        switch type {
        case "randomFile":
            let id = body["id"] as? String ?? ""
            let name = body["property"] as? String ?? ""
            guard !id.isEmpty else { return }
            let file = randomFile(forProperty: name)
            let value = file.map(WebWallpaperView.jsString) ?? "null"
            evaluate("window.__mirage.randomFile(\(WebWallpaperView.jsString(id)), \(WebWallpaperView.jsString(name)), \(value));")
        default:
            break
        }
    }

    /// Picks a file for `wallpaperRequestRandomFileForProperty`.
    ///
    /// The property holds a folder relative to the wallpaper, which is all the page
    /// is allowed to read, so anything that escapes it is refused and the request is
    /// answered with "no file" rather than a guess.
    private func randomFile(forProperty name: String) -> String? {
        guard let raw = properties[name] as? String else { return nil }
        let normalized = raw.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty, !components.contains("..") else { return nil }
        var directory = wallpaperFolder
        for component in components { directory.appendPathComponent(component) }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return nil }
        let files = entries.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        guard let pick = files.randomElement() else { return nil }
        return (components + [pick.lastPathComponent]).joined(separator: "/")
    }

    private func evaluate(_ script: String) {
        guard !isStopped else { return }
        // Guarded on the JavaScript side too: an evaluation that lands between a
        // navigation and the injected script would otherwise report an error.
        webView.evaluateJavaScript("if (window.__mirage) { \(script) }", completionHandler: nil)
    }

    // MARK: Encoding

    /// Wallpaper Engine hands the page `{"prop": {"value": ...}}`, never a bare
    /// value, and pages read `properties.prop.value` directly.
    private static func userPropertyPayload(_ properties: [String: Any]) -> String? {
        var wrapped: [String: Any] = [:]
        for (key, value) in properties {
            guard let sanitized = jsonValue(value) else { continue }
            wrapped[key] = ["value": sanitized]
        }
        guard !wrapped.isEmpty else { return nil }
        return jsonText(wrapped)
    }

    /// Only what Mirage can honestly report. `fps` and `audioprocessing` are left
    /// out rather than invented; pages treat missing general properties as unset.
    private static func generalPropertyPayload() -> String? {
        let language = Locale.current.identifier.replacingOccurrences(of: "_", with: "-").lowercased()
        return jsonText(["language": language])
    }

    /// Wallpaper JSON is third-party data: only values that survive
    /// `JSONSerialization` are forwarded, and non-finite numbers are dropped
    /// instead of producing invalid JavaScript.
    private static func jsonValue(_ value: Any) -> Any? {
        switch value {
        case let string as String:
            return string
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            let double = number.doubleValue
            return double.isFinite ? number : nil
        case let array as [Any]:
            return array.compactMap(jsonValue)
        case let dictionary as [String: Any]:
            var result: [String: Any] = [:]
            for (key, item) in dictionary {
                if let sanitized = jsonValue(item) { result[key] = sanitized }
            }
            return result
        default:
            return nil
        }
    }

    private static func jsonText(_ object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    /// A JSON string literal, quotes included, so page-supplied text cannot break
    /// out of the script being evaluated.
    private static func jsString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let text = String(data: data, encoding: .utf8),
              text.count > 2 else { return "\"\"" }
        return String(text.dropFirst().dropLast())
    }

    // MARK: Setup helpers

    /// `project.json` marks the wallpaper's root, and the page may sit a level or
    /// two below it while loading assets from anywhere inside, so read access is
    /// granted to the root when it can be found and to the page's own folder
    /// otherwise.
    private static func folder(containing url: URL) -> URL {
        let immediate = url.deletingLastPathComponent()
        var candidate = immediate
        for _ in 0..<4 {
            let marker = candidate.appendingPathComponent("project.json")
            if FileManager.default.fileExists(atPath: marker.path) { return candidate }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { break }
            candidate = parent
        }
        return immediate
    }

    /// Sets one of WebKit's private KVC flags, but only when a setter for it really
    /// exists: an unknown key raises an Objective-C exception that Swift cannot
    /// catch, and these keys are not API.
    private static func setPrivateFlag(_ object: NSObject, _ key: String, _ value: Bool) {
        guard let first = key.first else { return }
        let capitalized = first.uppercased() + key.dropFirst()
        let selectors = ["set\(capitalized):", "_set\(capitalized):"]
        guard selectors.contains(where: { object.responds(to: NSSelectorFromString($0)) }) else { return }
        object.setValue(value, forKey: key)
    }

    // MARK: Injected API

    /// The Wallpaper Engine web API, injected at document start so it exists before
    /// any of the page's own scripts run.
    private static let bridgeScript = #"""
    (function () {
        if (window.__mirage) { return; }

        var listener = null;
        var userProperties = {};
        var generalProperties = null;
        var audioListeners = [];
        var audioTimer = null;
        var paused = false;
        var muted = false;
        var queuedFrames = [];
        var pausedMedia = [];
        var fileRequests = {};
        var requestCounter = 0;
        var muteScheduled = false;

        var silence = [];
        for (var i = 0; i < 128; i++) { silence.push(0); }

        var nativeRequestFrame = typeof window.requestAnimationFrame === 'function'
            ? window.requestAnimationFrame.bind(window) : null;

        // A wallpaper is third-party code: an exception thrown by one of its
        // callbacks must not stop the host API.
        function guarded(fn) {
            try { fn(); } catch (error) { }
        }

        function post(message) {
            guarded(function () {
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.mirage) {
                    window.webkit.messageHandlers.mirage.postMessage(message);
                }
            });
        }

        function dispatch(name) {
            guarded(function () {
                var event;
                if (typeof Event === 'function') {
                    event = new Event(name);
                } else {
                    event = document.createEvent('Event');
                    event.initEvent(name, false, false);
                }
                window.dispatchEvent(event);
            });
        }

        function notifyPaused(value) {
            if (listener && typeof listener.setPaused === 'function') {
                guarded(function () { listener.setPaused(value); });
            }
        }

        function deliverGeneral(properties) {
            if (!listener || !properties) { return; }
            if (typeof listener.applyGeneralProperties !== 'function') { return; }
            guarded(function () { listener.applyGeneralProperties(properties); });
        }

        function deliverUser(properties) {
            if (!listener || !properties) { return; }
            if (typeof listener.applyUserProperties !== 'function') { return; }
            guarded(function () { listener.applyUserProperties(properties); });
        }

        function isEmpty(object) {
            for (var key in object) {
                if (Object.prototype.hasOwnProperty.call(object, key)) { return false; }
            }
            return true;
        }

        // The page assigns window.wallpaperPropertyListener whenever its own scripts
        // run, which is usually after the host already has the values, so intercept
        // the assignment and hand the listener everything collected so far.
        guarded(function () {
            Object.defineProperty(window, 'wallpaperPropertyListener', {
                configurable: true,
                enumerable: true,
                get: function () { return listener; },
                set: function (value) {
                    listener = value;
                    deliverGeneral(generalProperties);
                    if (!isEmpty(userProperties)) { deliverUser(userProperties); }
                    if (paused) { notifyPaused(true); }
                }
            });
        });

        function fireAudio(callback) {
            guarded(function () { callback(silence.slice(0)); });
        }

        function pumpAudio() {
            for (var i = 0; i < audioListeners.length; i++) { fireAudio(audioListeners[i]); }
        }

        function startAudio() {
            if (audioTimer !== null || paused || audioListeners.length === 0) { return; }
            audioTimer = window.setInterval(pumpAudio, 33);
        }

        function stopAudio() {
            if (audioTimer === null) { return; }
            window.clearInterval(audioTimer);
            audioTimer = null;
        }

        // Real system audio is not captured yet, so audio-reactive pages get a silent
        // 128-band spectrum about 30 times a second. They stay flat instead of
        // throwing on a callback that is never called.
        window.wallpaperRegisterAudioListener = function (callback) {
            if (typeof callback !== 'function') { return; }
            audioListeners.push(callback);
            startAudio();
        };

        window.wallpaperRequestRandomFileForProperty = function (name, callback) {
            if (typeof callback !== 'function') { return; }
            requestCounter += 1;
            var id = String(requestCounter);
            fileRequests[id] = { name: String(name), callback: callback };
            post({ type: 'randomFile', id: id, property: String(name) });
        };

        // Media integration is not implemented; accepting the registrations keeps
        // pages that expect these globals from failing at load.
        function ignoreListener() { }
        window.wallpaperRegisterMediaStatusListener = ignoreListener;
        window.wallpaperRegisterMediaPropertiesListener = ignoreListener;
        window.wallpaperRegisterMediaThumbnailListener = ignoreListener;
        window.wallpaperRegisterMediaTimelineListener = ignoreListener;
        window.wallpaperRegisterMediaPlaybackListener = ignoreListener;

        window.wallpaperMouseX = 0.5;
        window.wallpaperMouseY = 0.5;

        function scheduleFrame(callback) {
            if (nativeRequestFrame) { return nativeRequestFrame(callback); }
            return window.setTimeout(function () { callback(Date.now()); }, 16);
        }

        // Pausing holds requestAnimationFrame callbacks instead of running them. The
        // queue cannot grow without bound because a held callback never gets to ask
        // for the frame after it.
        window.requestAnimationFrame = function (callback) {
            if (typeof callback !== 'function') { return 0; }
            if (paused) { queuedFrames.push(callback); return 0; }
            return scheduleFrame(callback);
        };

        function mediaElements() {
            if (!document.querySelectorAll) { return []; }
            var found = [];
            guarded(function () {
                var nodes = document.querySelectorAll('video, audio');
                for (var i = 0; i < nodes.length; i++) { found.push(nodes[i]); }
            });
            return found;
        }

        function muteElement(element) {
            guarded(function () { element.muted = muted; });
        }

        function applyMuted() {
            muteScheduled = false;
            var elements = mediaElements();
            for (var i = 0; i < elements.length; i++) { muteElement(elements[i]); }
        }

        function pauseElement(element) {
            guarded(function () { element.pause(); });
        }

        function playElement(element) {
            guarded(function () {
                var result = element.play();
                if (result && typeof result.catch === 'function') { result.catch(function () { }); }
            });
        }

        function pauseMedia() {
            pausedMedia = [];
            var elements = mediaElements();
            for (var i = 0; i < elements.length; i++) {
                if (elements[i].paused) { continue; }
                pausedMedia.push(elements[i]);
                pauseElement(elements[i]);
            }
        }

        function resumeMedia() {
            var elements = pausedMedia;
            pausedMedia = [];
            for (var i = 0; i < elements.length; i++) { playElement(elements[i]); }
        }

        // Media added after the page loaded has to be muted too, but only when the
        // wallpaper is muted, and coalesced so a busy page is not re-scanned on
        // every DOM change.
        guarded(function () {
            if (typeof MutationObserver !== 'function' || !document.documentElement) { return; }
            var observer = new MutationObserver(function () {
                if (!muted || muteScheduled) { return; }
                muteScheduled = true;
                window.setTimeout(applyMuted, 0);
            });
            observer.observe(document.documentElement, { childList: true, subtree: true });
        });

        window.__mirage = {
            userProperties: function (properties) {
                for (var key in properties) {
                    if (Object.prototype.hasOwnProperty.call(properties, key)) {
                        userProperties[key] = properties[key];
                    }
                }
                deliverUser(properties);
            },

            generalProperties: function (properties) {
                generalProperties = properties;
                deliverGeneral(properties);
            },

            setMuted: function (value) {
                muted = !!value;
                applyMuted();
            },

            setPaused: function (value) {
                var next = !!value;
                if (next === paused) { return; }
                paused = next;
                if (paused) {
                    stopAudio();
                    pauseMedia();
                    dispatch('wallpaperPause');
                } else {
                    resumeMedia();
                    startAudio();
                    var queued = queuedFrames;
                    queuedFrames = [];
                    for (var i = 0; i < queued.length; i++) { scheduleFrame(queued[i]); }
                    dispatch('wallpaperResume');
                }
                notifyPaused(paused);
            },

            setPointer: function (x, y) {
                window.wallpaperMouseX = x;
                window.wallpaperMouseY = y;
                // The view takes no clicks, so a page that follows the cursor with
                // DOM events would otherwise never see it move.
                guarded(function () {
                    if (typeof MouseEvent !== 'function' || !document.body) { return; }
                    document.dispatchEvent(new MouseEvent('mousemove', {
                        bubbles: true,
                        cancelable: false,
                        clientX: x * (window.innerWidth || 0),
                        clientY: y * (window.innerHeight || 0)
                    }));
                });
            },

            randomFile: function (id, name, file) {
                var key = String(id);
                var request = fileRequests[key];
                delete fileRequests[key];
                if (!request || typeof file !== 'string') { return; }
                guarded(function () { request.callback(name, file); });
            }
        };
    })();
    """#
}
