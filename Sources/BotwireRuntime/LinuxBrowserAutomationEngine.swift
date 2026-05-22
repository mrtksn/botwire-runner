#if os(Linux) && canImport(CJavaScriptCoreGTK)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#endif

// MARK: - Headless Chrome CDP Client for Linux

/// A lightweight Chrome DevTools Protocol (CDP) client that manages
/// headless Chromium instances with per-project isolation.
///
/// Security model (multi-tenant):
/// - Each project gets its own Chrome process with a unique user-data-dir
/// - Each process gets a random debug port to avoid collisions
/// - Processes are killed when the execution completes
/// - Temp directories are cleaned up after execution
public final class LinuxBrowserAutomationEngine: @unchecked Sendable {

    struct ManagedPage {
        let pageId: String
        let targetId: String
        let wsURL: String
    }

    private let projectId: String
    private let responseQueue: JSResponseQueue
    private let lock = NSLock()

    private var chromeProcess: Process?
    private var debugPort: Int = 0
    private var wsEndpoint: String = ""
    private var pages: [String: ManagedPage] = [:]
    private var userDataDir: String = ""
    private var isShutDown = false

    init(projectId: String, responseQueue: JSResponseQueue) {
        self.projectId = projectId
        self.responseQueue = responseQueue
    }

    // MARK: - Chrome Process Management

    func launch() -> Bool {
        let port = findFreePort()
        guard port > 0 else { return false }
        self.debugPort = port

        let tempBase = "/tmp/botwire_browser"
        let sanitizedProjectId = projectId
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "..", with: "_")
        userDataDir = "\(tempBase)/\(sanitizedProjectId)_\(UUID().uuidString.prefix(8))"

        do {
            try FileManager.default.createDirectory(atPath: userDataDir, withIntermediateDirectories: true)
        } catch {
            print("[BrowserAutomation] Failed to create user-data-dir: \(error)")
            return false
        }

        guard let chromePath = findChromeBinary() else {
            print("[BrowserAutomation] No Chrome/Chromium binary found.")
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: chromePath)
        process.arguments = [
            "--headless=new", "--no-sandbox", "--disable-gpu",
            "--disable-dev-shm-usage", "--disable-software-rasterizer",
            "--disable-extensions", "--disable-background-networking",
            "--disable-default-apps", "--no-first-run",
            "--remote-debugging-port=\(port)",
            "--user-data-dir=\(userDataDir)",
            "--window-size=1280,720", "about:blank"
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch {
            print("[BrowserAutomation] Failed to launch Chrome: \(error)")
            cleanupUserDataDir()
            return false
        }

        self.chromeProcess = process

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let endpoint = fetchWebSocketEndpoint(port: port) {
                self.wsEndpoint = endpoint
                print("[BrowserAutomation] Chrome launched on port \(port)")
                return true
            }
            usleep(200_000)
        }

        print("[BrowserAutomation] Chrome failed to start within 10s")
        shutdown()
        return false
    }

    func shutdown() {
        lock.lock()
        guard !isShutDown else { lock.unlock(); return }
        isShutDown = true
        lock.unlock()

        if let process = chromeProcess, process.isRunning {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                self?.cleanupUserDataDir()
            }
        } else {
            cleanupUserDataDir()
        }
    }

    private func cleanupUserDataDir() {
        guard !userDataDir.isEmpty else { return }
        try? FileManager.default.removeItem(atPath: userDataDir)
    }

    // MARK: - Request Dispatch

    func handleRequest(_ req: JSHostRequest) {
        guard let data = req.args.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            responseQueue.push(JSHostResponse(id: req.id, success: false,
                payload: Self.jsonString(["error": "Invalid browser automation args"])))
            return
        }

        let method = args["method"] as? String ?? ""
        let params = args["params"] as? [String: Any] ?? [:]

        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            do {
                let result = try self.dispatch(method: method, params: params)
                self.responseQueue.push(JSHostResponse(id: req.id, success: true,
                    payload: Self.jsonString(result)))
            } catch {
                self.responseQueue.push(JSHostResponse(id: req.id, success: false,
                    payload: Self.jsonString(["error": error.localizedDescription])))
            }
        }
    }

    private func dispatch(method: String, params: [String: Any]) throws -> Any {
        let pageId = params["pageId"] as? String ?? ""
        let selector = params["selector"] as? String ?? ""

        switch method {
        case "browser.newPage":
            return ["pageId": try createNewPage(url: params["url"] as? String)]
        case "browser.pages":
            return pages.values.map { ["pageId": $0.pageId] }
        case "browser.closeAll":
            let count = pages.count
            for page in pages.values { try? closeCDPPage(targetId: page.targetId) }
            pages.removeAll()
            return ["closed": count]
        case "page.goto":
            try navigatePage(pageId: pageId, url: params["url"] as? String ?? "")
            return try getPageInfo(pageId: pageId)
        case "page.click":
            let clickPage = try requirePage(pageId)
            let clickCenter = try resolveElementCenter(pageId: pageId, selector: selector)
            let clickInfo = try evaluateOnPage(pageId: pageId, js: """
                (() => { const el = document.querySelector(\(Self.jsQuote(selector)));
                return el ? JSON.stringify({found:true,tagName:el.tagName,text:(el.textContent||'').trim().slice(0,100)}) : JSON.stringify({found:false}); })()
                """)
            _ = try sendCDPCommand(wsURL: clickPage.wsURL, method: "Input.dispatchMouseEvent",
                params: ["type": "mousePressed", "x": clickCenter.x, "y": clickCenter.y, "button": "left", "clickCount": 1])
            _ = try sendCDPCommand(wsURL: clickPage.wsURL, method: "Input.dispatchMouseEvent",
                params: ["type": "mouseReleased", "x": clickCenter.x, "y": clickCenter.y, "button": "left", "clickCount": 1])
            return clickInfo
        case "page.fill":
            let fillPage = try requirePage(pageId)
            let value = params["value"] as? String ?? ""
            // Focus + select all existing content
            _ = try evaluateOnPage(pageId: pageId, js: """
                (() => { const el = document.querySelector(\(Self.jsQuote(selector)));
                if (!el) throw new Error('Element not found: \(selector)');
                el.focus(); if (el.select) el.select(); })()
                """)
            // Ctrl+A to select all, then Backspace to clear
            _ = try sendCDPCommand(wsURL: fillPage.wsURL, method: "Input.dispatchKeyEvent",
                params: ["type": "keyDown", "key": "a", "code": "KeyA", "windowsVirtualKeyCode": 65, "modifiers": 2])
            _ = try sendCDPCommand(wsURL: fillPage.wsURL, method: "Input.dispatchKeyEvent",
                params: ["type": "keyUp", "key": "a", "code": "KeyA", "windowsVirtualKeyCode": 65, "modifiers": 2])
            _ = try sendCDPCommand(wsURL: fillPage.wsURL, method: "Input.dispatchKeyEvent",
                params: ["type": "keyDown", "key": "Backspace", "code": "Backspace", "windowsVirtualKeyCode": 8])
            _ = try sendCDPCommand(wsURL: fillPage.wsURL, method: "Input.dispatchKeyEvent",
                params: ["type": "keyUp", "key": "Backspace", "code": "Backspace", "windowsVirtualKeyCode": 8])
            // Insert text via native CDP
            _ = try sendCDPCommand(wsURL: fillPage.wsURL, method: "Input.insertText", params: ["text": value])
            return ["filled": true]
        case "page.textContent":
            return try evaluateOnPage(pageId: pageId, js: """
                (() => { const el = document.querySelector(\(Self.jsQuote(selector))); return el ? (el.textContent||'') : null; })()
                """)
        case "page.innerHTML":
            return try evaluateOnPage(pageId: pageId, js: """
                (() => { const el = document.querySelector(\(Self.jsQuote(selector))); return el ? el.innerHTML : null; })()
                """)
        case "page.evaluate":
            return try evaluateOnPage(pageId: pageId, js: params["expression"] as? String ?? "")
        case "page.title":
            return try evaluateOnPage(pageId: pageId, js: "document.title")
        case "page.url":
            return try evaluateOnPage(pageId: pageId, js: "window.location.href")
        case "page.content":
            return try evaluateOnPage(pageId: pageId, js: "document.documentElement.outerHTML")
        case "page.waitForSelector":
            let timeout = (params["options"] as? [String: Any])?["timeout"] as? Int ?? 10000
            return try evaluateOnPage(pageId: pageId, js: """
                new Promise((resolve, reject) => {
                    const sel = \(Self.jsQuote(selector)); const el = document.querySelector(sel);
                    if (el) { resolve(JSON.stringify({found:true})); return; }
                    const obs = new MutationObserver(() => { const e = document.querySelector(sel);
                        if (e) { obs.disconnect(); clearTimeout(t); resolve(JSON.stringify({found:true})); } });
                    obs.observe(document.body||document.documentElement,{childList:true,subtree:true});
                    const t = setTimeout(() => { obs.disconnect(); reject(new Error('Timeout')); }, \(timeout)); })
                """)
        case "page.waitForTimeout":
            let ms = params["timeout"] as? Int ?? 1000
            Thread.sleep(forTimeInterval: Double(ms) / 1000.0)
            return ["waited": ms]
        case "page.goBack":
            let goBackPage = try requirePage(pageId)
            let backHist = try sendCDPCommand(wsURL: goBackPage.wsURL, method: "Page.getNavigationHistory", params: [:])
            if let r = backHist["result"] as? [String: Any], let ci = r["currentIndex"] as? Int,
               let entries = r["entries"] as? [[String: Any]], ci > 0, let eid = entries[ci-1]["id"] as? Int {
                _ = try sendCDPCommand(wsURL: goBackPage.wsURL, method: "Page.navigateToHistoryEntry", params: ["entryId": eid])
                usleep(300_000)
            }
            return try getPageInfo(pageId: pageId)
        case "page.goForward":
            let goFwdPage = try requirePage(pageId)
            let fwdHist = try sendCDPCommand(wsURL: goFwdPage.wsURL, method: "Page.getNavigationHistory", params: [:])
            if let r = fwdHist["result"] as? [String: Any], let ci = r["currentIndex"] as? Int,
               let entries = r["entries"] as? [[String: Any]], ci < entries.count-1, let eid = entries[ci+1]["id"] as? Int {
                _ = try sendCDPCommand(wsURL: goFwdPage.wsURL, method: "Page.navigateToHistoryEntry", params: ["entryId": eid])
                usleep(300_000)
            }
            return try getPageInfo(pageId: pageId)
        case "page.reload":
            let reloadPage = try requirePage(pageId)
            _ = try sendCDPCommand(wsURL: reloadPage.wsURL, method: "Page.reload", params: [:])
            usleep(500_000)
            return try getPageInfo(pageId: pageId)
        case "page.querySelector":
            return try evaluateOnPage(pageId: pageId, js: """
                (() => { const el = document.querySelector(\(Self.jsQuote(selector)));
                if (!el) return null;
                return JSON.stringify({tagName:el.tagName,id:el.id,text:(el.textContent||'').trim().slice(0,200)}); })()
                """)
        case "page.querySelectorAll":
            let max = params["maxResults"] as? Int ?? 50
            return try evaluateOnPage(pageId: pageId, js: """
                (() => { const els = Array.from(document.querySelectorAll(\(Self.jsQuote(selector)))).slice(0,\(max));
                return JSON.stringify(els.map(e => ({tagName:e.tagName,id:e.id,text:(e.textContent||'').trim().slice(0,200)}))); })()
                """)
        case "page.close":
            if let page = pages[pageId] {
                try? closeCDPPage(targetId: page.targetId)
                pages.removeValue(forKey: pageId)
            }
            return ["closed": true]

        case "page.type":
            let typePage = try requirePage(pageId)
            let typeText = params["text"] as? String ?? ""
            let typeDelay = params["options"].flatMap { ($0 as? [String: Any])?["delay"] as? Int } ?? 0
            // Focus element first
            _ = try evaluateOnPage(pageId: pageId, js: """
                (() => { const el = document.querySelector(\(Self.jsQuote(selector)));
                if (!el) throw new Error('Element not found'); el.focus(); })()
                """)
            // Type each character via native CDP key events
            for ch in typeText {
                let k = String(ch)
                _ = try sendCDPCommand(wsURL: typePage.wsURL, method: "Input.dispatchKeyEvent",
                    params: ["type": "keyDown", "key": k, "text": k])
                _ = try sendCDPCommand(wsURL: typePage.wsURL, method: "Input.dispatchKeyEvent",
                    params: ["type": "keyUp", "key": k])
                if typeDelay > 0 { usleep(UInt32(typeDelay) * 1000) }
            }
            return ["typed": true, "length": typeText.count]

        case "page.press":
            let pressPage = try requirePage(pageId)
            let pressKey = params["key"] as? String ?? ""
            if !selector.isEmpty {
                _ = try evaluateOnPage(pageId: pageId, js: """
                    (() => { const el = document.querySelector(\(Self.jsQuote(selector))); if (el) el.focus(); })()
                    """)
            }
            let kd = Self.keyDescriptor(for: pressKey)
            var downP = kd; downP["type"] = "keyDown"
            var upP = kd; upP["type"] = "keyUp"
            _ = try sendCDPCommand(wsURL: pressPage.wsURL, method: "Input.dispatchKeyEvent", params: downP)
            _ = try sendCDPCommand(wsURL: pressPage.wsURL, method: "Input.dispatchKeyEvent", params: upP)
            return ["pressed": pressKey]

        case "page.select":
            let values = params["values"] as? [String] ?? []
            let valuesJS = values.map { Self.jsQuote($0) }.joined(separator: ",")
            return try evaluateOnPage(pageId: pageId, js: """
                (() => { const el = document.querySelector(\(Self.jsQuote(selector)));
                if (!el || el.tagName !== 'SELECT') return JSON.stringify({error:'Select element not found'});
                const vals = [\(valuesJS)];
                Array.from(el.options).forEach(o => { o.selected = vals.includes(o.value); });
                el.dispatchEvent(new Event('change',{bubbles:true}));
                return JSON.stringify({selected:vals}); })()
                """)

        case "page.check":
            let checkPage = try requirePage(pageId)
            let isChecked = try evaluateOnPage(pageId: pageId, js: """
                (() => { const el = document.querySelector(\(Self.jsQuote(selector)));
                if (!el) throw new Error('Element not found');
                return el.checked ? 'true' : 'false'; })()
                """)
            if "\(isChecked)" != "true" {
                let checkCenter = try resolveElementCenter(pageId: pageId, selector: selector)
                _ = try sendCDPCommand(wsURL: checkPage.wsURL, method: "Input.dispatchMouseEvent",
                    params: ["type": "mousePressed", "x": checkCenter.x, "y": checkCenter.y, "button": "left", "clickCount": 1])
                _ = try sendCDPCommand(wsURL: checkPage.wsURL, method: "Input.dispatchMouseEvent",
                    params: ["type": "mouseReleased", "x": checkCenter.x, "y": checkCenter.y, "button": "left", "clickCount": 1])
            }
            return ["checked": true]

        case "page.uncheck":
            let uncheckPage = try requirePage(pageId)
            let wasChecked = try evaluateOnPage(pageId: pageId, js: """
                (() => { const el = document.querySelector(\(Self.jsQuote(selector)));
                if (!el) throw new Error('Element not found');
                return el.checked ? 'true' : 'false'; })()
                """)
            if "\(wasChecked)" == "true" {
                let uncheckCenter = try resolveElementCenter(pageId: pageId, selector: selector)
                _ = try sendCDPCommand(wsURL: uncheckPage.wsURL, method: "Input.dispatchMouseEvent",
                    params: ["type": "mousePressed", "x": uncheckCenter.x, "y": uncheckCenter.y, "button": "left", "clickCount": 1])
                _ = try sendCDPCommand(wsURL: uncheckPage.wsURL, method: "Input.dispatchMouseEvent",
                    params: ["type": "mouseReleased", "x": uncheckCenter.x, "y": uncheckCenter.y, "button": "left", "clickCount": 1])
            }
            return ["unchecked": true]

        case "page.hover":
            let hoverPage = try requirePage(pageId)
            let hoverCenter = try resolveElementCenter(pageId: pageId, selector: selector)
            _ = try sendCDPCommand(wsURL: hoverPage.wsURL, method: "Input.dispatchMouseEvent",
                params: ["type": "mouseMoved", "x": hoverCenter.x, "y": hoverCenter.y])
            return ["hovered": true]

        case "page.focus":
            return try evaluateOnPage(pageId: pageId, js: """
                (() => { const el = document.querySelector(\(Self.jsQuote(selector)));
                if (!el) return JSON.stringify({error:'Element not found'});
                el.focus();
                return JSON.stringify({focused:true}); })()
                """)

        case "page.dblclick":
            let dblPage = try requirePage(pageId)
            let dblCenter = try resolveElementCenter(pageId: pageId, selector: selector)
            _ = try sendCDPCommand(wsURL: dblPage.wsURL, method: "Input.dispatchMouseEvent",
                params: ["type": "mousePressed", "x": dblCenter.x, "y": dblCenter.y, "button": "left", "clickCount": 1])
            _ = try sendCDPCommand(wsURL: dblPage.wsURL, method: "Input.dispatchMouseEvent",
                params: ["type": "mouseReleased", "x": dblCenter.x, "y": dblCenter.y, "button": "left", "clickCount": 1])
            _ = try sendCDPCommand(wsURL: dblPage.wsURL, method: "Input.dispatchMouseEvent",
                params: ["type": "mousePressed", "x": dblCenter.x, "y": dblCenter.y, "button": "left", "clickCount": 2])
            _ = try sendCDPCommand(wsURL: dblPage.wsURL, method: "Input.dispatchMouseEvent",
                params: ["type": "mouseReleased", "x": dblCenter.x, "y": dblCenter.y, "button": "left", "clickCount": 2])
            return ["dblclicked": true]

        case "page.selectText":
            return try evaluateOnPage(pageId: pageId, js: """
                (() => { const el = document.querySelector(\(Self.jsQuote(selector)));
                if (!el) return JSON.stringify({error:'Element not found'});
                if (el.select) { el.select(); } else {
                    const range = document.createRange(); range.selectNodeContents(el);
                    const sel = window.getSelection(); sel.removeAllRanges(); sel.addRange(range); }
                return JSON.stringify({selected:true}); })()
                """)

        case "page.getAttribute":
            let attrName = params["name"] as? String ?? ""
            return try evaluateOnPage(pageId: pageId, js: """
                (() => { const el = document.querySelector(\(Self.jsQuote(selector)));
                return el ? el.getAttribute(\(Self.jsQuote(attrName))) : null; })()
                """)

        case "page.screenshot":
            let page = try requirePage(pageId)
            let fmt = (params["options"] as? [String: Any])?["type"] as? String ?? "png"
            let quality = (params["options"] as? [String: Any])?["quality"] as? Int ?? 80
            let response = try sendCDPCommand(wsURL: page.wsURL, method: "Page.captureScreenshot",
                params: ["format": fmt == "jpeg" ? "jpeg" : "png", "quality": quality])
            if let result = response["result"] as? [String: Any],
               let base64 = result["data"] as? String {
                return ["base64": base64, "format": fmt, "dataUrl": "data:image/\(fmt);base64,\(base64)"]
            }
            return ["error": "Screenshot failed"]

        case "page.setViewportSize":
            let width = params["width"] as? Int ?? 1280
            let height = params["height"] as? Int ?? 720
            let page = try requirePage(pageId)
            _ = try sendCDPCommand(wsURL: page.wsURL, method: "Emulation.setDeviceMetricsOverride",
                params: ["width": width, "height": height, "deviceScaleFactor": 1, "mobile": false])
            return ["width": width, "height": height]

        case "page.bringToFront":
            let page = try requirePage(pageId)
            _ = try sendCDPCommand(wsURL: page.wsURL, method: "Page.bringToFront", params: [:])
            return ["ok": true]

        case "page.waitForNavigation":
            let timeout = (params["options"] as? [String: Any])?["timeout"] as? Int ?? 30000
            return try evaluateOnPage(pageId: pageId, js: """
                new Promise((resolve, reject) => {
                    const t = setTimeout(() => reject(new Error('Navigation timeout')), \(timeout));
                    const obs = new MutationObserver(() => {
                        if (document.readyState === 'complete') { obs.disconnect(); clearTimeout(t);
                            resolve(JSON.stringify({url:window.location.href,title:document.title})); }
                    });
                    obs.observe(document,{childList:true,subtree:true});
                    if (document.readyState === 'complete') { obs.disconnect(); clearTimeout(t);
                        resolve(JSON.stringify({url:window.location.href,title:document.title})); } })
                """)

        case "page.waitForURL":
            let pattern = params["url"] as? String ?? params["pattern"] as? String ?? "*"
            let timeout = (params["options"] as? [String: Any])?["timeout"] as? Int ?? 30000
            return try evaluateOnPage(pageId: pageId, js: """
                new Promise((resolve, reject) => {
                    const pattern = \(Self.jsQuote(pattern));
                    function matchURL(url) {
                        const regex = new RegExp('^' + pattern.replace(/\\*/g, '.*').replace(/\\?/g, '.') + '$');
                        return regex.test(url);
                    }
                    if (matchURL(window.location.href)) { resolve(JSON.stringify({url:window.location.href,title:document.title})); return; }
                    const t = setTimeout(() => reject(new Error('URL timeout')), \(timeout));
                    const interval = setInterval(() => {
                        if (matchURL(window.location.href)) { clearInterval(interval); clearTimeout(t);
                            resolve(JSON.stringify({url:window.location.href,title:document.title})); }
                    }, 100); })
                """)

        default:
            throw LinuxBrowserError.unsupportedMethod(method)
        }
    }

    // MARK: - CDP via HTTP + Raw WebSocket

    private func createNewPage(url: String?) throws -> String {
        let targetURL = url ?? "about:blank"
        guard let response = synchronousHTTPGet(url: "http://127.0.0.1:\(debugPort)/json/new?\(targetURL)"),
              let data = response.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let targetId = json["id"] as? String,
              let wsURL = json["webSocketDebuggerUrl"] as? String else {
            throw LinuxBrowserError.failedToCreatePage
        }
        let pageId = "page_\(UUID().uuidString.prefix(8))"
        lock.lock()
        pages[pageId] = ManagedPage(pageId: pageId, targetId: targetId, wsURL: wsURL)
        lock.unlock()
        return pageId
    }

    private func navigatePage(pageId: String, url: String) throws {
        let page = try requirePage(pageId)
        _ = try sendCDPCommand(wsURL: page.wsURL, method: "Page.navigate", params: ["url": url])
        usleep(500_000) // wait for navigation
    }

    private func getPageInfo(pageId: String) throws -> [String: Any] {
        let result = try evaluateOnPage(pageId: pageId, js: "JSON.stringify({url:window.location.href,title:document.title})")
        if let str = result as? String, let data = str.data(using: .utf8),
           let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return info
        }
        return ["url": "", "title": ""]
    }

    private func evaluateOnPage(pageId: String, js: String) throws -> Any {
        let page = try requirePage(pageId)
        let response = try sendCDPCommand(wsURL: page.wsURL, method: "Runtime.evaluate", params: [
            "expression": js, "returnByValue": true, "awaitPromise": true, "timeout": 30000
        ])
        if let result = response["result"] as? [String: Any],
           let resultValue = result["result"] as? [String: Any] {
            if let exc = result["exceptionDetails"] as? [String: Any],
               let excObj = exc["exception"] as? [String: Any] {
                throw LinuxBrowserError.evaluationFailed(excObj["description"] as? String ?? "JS error")
            }
            return resultValue["value"] ?? NSNull()
        }
        return NSNull()
    }

    private func closeCDPPage(targetId: String) throws {
        _ = synchronousHTTPGet(url: "http://127.0.0.1:\(debugPort)/json/close/\(targetId)")
    }

    // MARK: - Raw TCP WebSocket CDP Client (zero external dependencies)

    private var cdpMessageId = 0

    private func sendCDPCommand(wsURL: String, method: String, params: [String: Any]) throws -> [String: Any] {
        cdpMessageId += 1
        let command: [String: Any] = ["id": cdpMessageId, "method": method, "params": params]
        guard let commandData = try? JSONSerialization.data(withJSONObject: command),
              let commandStr = String(data: commandData, encoding: .utf8) else {
            throw LinuxBrowserError.invalidCommand
        }

        // Parse ws://127.0.0.1:PORT/devtools/page/TARGET_ID
        guard let url = URL(string: wsURL),
              let host = url.host,
              let port = url.port else {
            throw LinuxBrowserError.invalidWSURL(wsURL)
        }

        // Open raw TCP socket
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { throw LinuxBrowserError.cdpCommunicationFailed("socket() failed") }
        defer { close(fd) }

        // Set socket timeout (30s)
        var tv = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Connect
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)
        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connectResult == 0 else { throw LinuxBrowserError.cdpCommunicationFailed("connect() failed") }

        // WebSocket handshake
        let wsKey = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let handshake = "GET \(url.path) HTTP/1.1\r\nHost: \(host):\(port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(wsKey)\r\nSec-WebSocket-Version: 13\r\n\r\n"
        guard let handshakeData = handshake.data(using: .utf8) else {
            throw LinuxBrowserError.cdpCommunicationFailed("handshake encoding failed")
        }
        _ = handshakeData.withUnsafeBytes { send(fd, $0.baseAddress!, $0.count, 0) }

        // Read handshake response (just need to drain the HTTP 101 response)
        var headerBuf = [UInt8](repeating: 0, count: 4096)
        let headerLen = recv(fd, &headerBuf, headerBuf.count, 0)
        guard headerLen > 0 else { throw LinuxBrowserError.cdpCommunicationFailed("No handshake response") }
        let headerStr = String(bytes: headerBuf[0..<headerLen], encoding: .utf8) ?? ""
        guard headerStr.contains("101") else {
            throw LinuxBrowserError.cdpCommunicationFailed("WebSocket handshake failed: \(headerStr.prefix(200))")
        }

        // Send WebSocket text frame (masked, as required by RFC 6455 for clients)
        let payload = Array(commandStr.utf8)
        try sendWebSocketFrame(fd: fd, payload: payload)

        // Read WebSocket response frame
        let responsePayload = try readWebSocketFrame(fd: fd)
        guard let responseStr = String(bytes: responsePayload, encoding: .utf8),
              let responseData = responseStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw LinuxBrowserError.cdpCommunicationFailed("Invalid CDP response")
        }

        return json
    }

    /// Send a masked WebSocket text frame per RFC 6455.
    private func sendWebSocketFrame(fd: Int32, payload: [UInt8]) throws {
        var frame = [UInt8]()
        frame.append(0x81) // FIN + text opcode

        let mask: [UInt8] = (0..<4).map { _ in UInt8.random(in: 0...255) }

        if payload.count < 126 {
            frame.append(UInt8(payload.count) | 0x80) // MASK bit set
        } else if payload.count <= 65535 {
            frame.append(126 | 0x80)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(127 | 0x80)
            for i in (0..<8).reversed() {
                frame.append(UInt8((payload.count >> (i * 8)) & 0xFF))
            }
        }

        frame.append(contentsOf: mask)
        for (i, byte) in payload.enumerated() {
            frame.append(byte ^ mask[i % 4])
        }

        let sent = frame.withUnsafeBytes { send(fd, $0.baseAddress!, $0.count, 0) }
        guard sent == frame.count else {
            throw LinuxBrowserError.cdpCommunicationFailed("Failed to send WebSocket frame")
        }
    }

    /// Read a WebSocket frame and return the unmasked payload.
    private func readWebSocketFrame(fd: Int32) throws -> [UInt8] {
        var header = [UInt8](repeating: 0, count: 2)
        guard recvAll(fd: fd, buffer: &header, count: 2) else {
            throw LinuxBrowserError.cdpCommunicationFailed("Failed to read frame header")
        }

        let masked = (header[1] & 0x80) != 0
        var payloadLen = UInt64(header[1] & 0x7F)

        if payloadLen == 126 {
            var ext = [UInt8](repeating: 0, count: 2)
            guard recvAll(fd: fd, buffer: &ext, count: 2) else {
                throw LinuxBrowserError.cdpCommunicationFailed("Failed to read extended length")
            }
            payloadLen = UInt64(ext[0]) << 8 | UInt64(ext[1])
        } else if payloadLen == 127 {
            var ext = [UInt8](repeating: 0, count: 8)
            guard recvAll(fd: fd, buffer: &ext, count: 8) else {
                throw LinuxBrowserError.cdpCommunicationFailed("Failed to read extended length")
            }
            payloadLen = 0
            for i in 0..<8 { payloadLen = (payloadLen << 8) | UInt64(ext[i]) }
        }

        // Safety: cap at 10MB
        guard payloadLen < 10_000_000 else {
            throw LinuxBrowserError.cdpCommunicationFailed("Frame too large: \(payloadLen)")
        }

        var maskKey = [UInt8]()
        if masked {
            maskKey = [UInt8](repeating: 0, count: 4)
            guard recvAll(fd: fd, buffer: &maskKey, count: 4) else {
                throw LinuxBrowserError.cdpCommunicationFailed("Failed to read mask key")
            }
        }

        var payload = [UInt8](repeating: 0, count: Int(payloadLen))
        if payloadLen > 0 {
            guard recvAll(fd: fd, buffer: &payload, count: Int(payloadLen)) else {
                throw LinuxBrowserError.cdpCommunicationFailed("Failed to read payload")
            }
        }

        if masked {
            for i in 0..<payload.count { payload[i] ^= maskKey[i % 4] }
        }

        return payload
    }

    /// Read exactly `count` bytes from a socket.
    private func recvAll(fd: Int32, buffer: inout [UInt8], count: Int) -> Bool {
        var offset = 0
        while offset < count {
            let n = buffer.withUnsafeMutableBytes { ptr in
                recv(fd, ptr.baseAddress! + offset, count - offset, 0)
            }
            if n <= 0 { return false }
            offset += n
        }
        return true
    }

    // MARK: - Helpers

    private func requirePage(_ pageId: String) throws -> ManagedPage {
        lock.lock()
        let page = pages[pageId]
        lock.unlock()
        guard let page else { throw LinuxBrowserError.pageNotFound(pageId) }
        return page
    }

    /// Resolve a CSS selector to the element's center coordinates, scrolling it into view first.
    private func resolveElementCenter(pageId: String, selector: String) throws -> (x: Int, y: Int) {
        let result = try evaluateOnPage(pageId: pageId, js: """
            (() => { const el = document.querySelector(\(Self.jsQuote(selector)));
            if (!el) return null;
            el.scrollIntoView({block:'center',inline:'center'});
            const r = el.getBoundingClientRect();
            return JSON.stringify({x:Math.round(r.x+r.width/2),y:Math.round(r.y+r.height/2)}); })()
            """)
        if let str = result as? String, let data = str.data(using: .utf8),
           let coords = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let x = coords["x"] as? Int, let y = coords["y"] as? Int {
            return (x, y)
        }
        throw LinuxBrowserError.evaluationFailed("Element not found: \(selector)")
    }

    /// Map a key name (e.g. "Enter", "Tab", "a") to CDP Input.dispatchKeyEvent parameters.
    static func keyDescriptor(for key: String) -> [String: Any] {
        switch key {
        case "Enter":    return ["key": "Enter", "code": "Enter", "windowsVirtualKeyCode": 13, "nativeVirtualKeyCode": 13]
        case "Tab":      return ["key": "Tab", "code": "Tab", "windowsVirtualKeyCode": 9, "nativeVirtualKeyCode": 9]
        case "Escape":   return ["key": "Escape", "code": "Escape", "windowsVirtualKeyCode": 27, "nativeVirtualKeyCode": 27]
        case "Backspace":return ["key": "Backspace", "code": "Backspace", "windowsVirtualKeyCode": 8, "nativeVirtualKeyCode": 8]
        case "Delete":   return ["key": "Delete", "code": "Delete", "windowsVirtualKeyCode": 46, "nativeVirtualKeyCode": 46]
        case "ArrowUp":  return ["key": "ArrowUp", "code": "ArrowUp", "windowsVirtualKeyCode": 38, "nativeVirtualKeyCode": 38]
        case "ArrowDown":return ["key": "ArrowDown", "code": "ArrowDown", "windowsVirtualKeyCode": 40, "nativeVirtualKeyCode": 40]
        case "ArrowLeft":return ["key": "ArrowLeft", "code": "ArrowLeft", "windowsVirtualKeyCode": 37, "nativeVirtualKeyCode": 37]
        case "ArrowRight":return ["key": "ArrowRight","code": "ArrowRight","windowsVirtualKeyCode": 39, "nativeVirtualKeyCode": 39]
        case " ":        return ["key": " ", "code": "Space", "windowsVirtualKeyCode": 32, "nativeVirtualKeyCode": 32, "text": " "]
        default:         return ["key": key, "text": key.count == 1 ? key : ""]
        }
    }

    private func findFreePort() -> Int {
        // Bind to port 0 to get a kernel-assigned free port
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { return 19222 + Int.random(in: 0..<1000) }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { return 19222 + Int.random(in: 0..<1000) }

        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &addrLen)
            }
        }
        guard nameResult == 0 else { return 19222 + Int.random(in: 0..<1000) }
        return Int(UInt16(bigEndian: boundAddr.sin_port))
    }

    private func fetchWebSocketEndpoint(port: Int) -> String? {
        guard let response = synchronousHTTPGet(url: "http://127.0.0.1:\(port)/json/version"),
              let data = response.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let wsURL = json["webSocketDebuggerUrl"] as? String else { return nil }
        return wsURL
    }

    private func synchronousHTTPGet(url urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        let semaphore = DispatchSemaphore(value: 0)
        var result: String?
        let task = URLSession.shared.dataTask(with: url) { data, _, _ in
            if let data { result = String(data: data, encoding: .utf8) }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 5)
        return result
    }

    private func findChromeBinary() -> String? {
        for path in ["/usr/bin/chromium-browser", "/usr/bin/chromium", "/usr/bin/google-chrome",
                     "/usr/bin/google-chrome-stable", "/snap/bin/chromium", "/usr/lib/chromium/chromium"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    static func jsonString(_ value: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: value),
           let str = String(data: data, encoding: .utf8) { return str }
        return "null"
    }

    static func jsQuote(_ string: String) -> String {
        let escaped = string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "'\(escaped)'"
    }
}

// MARK: - Errors

enum LinuxBrowserError: LocalizedError {
    case failedToCreatePage
    case pageNotFound(String)
    case invalidWSURL(String)
    case invalidCommand
    case evaluationFailed(String)
    case cdpCommunicationFailed(String)
    case unsupportedMethod(String)

    var errorDescription: String? {
        switch self {
        case .failedToCreatePage: return "Failed to create new browser page."
        case .pageNotFound(let id): return "Browser page '\(id)' not found."
        case .invalidWSURL(let url): return "Invalid WebSocket URL: \(url)"
        case .invalidCommand: return "Invalid CDP command."
        case .evaluationFailed(let msg): return "JS evaluation failed: \(msg)"
        case .cdpCommunicationFailed(let msg): return "CDP communication failed: \(msg)"
        case .unsupportedMethod(let method): return "Unsupported browser method: \(method)"
        }
    }
}

#endif
