import BotwireCore
import Foundation

#if os(Linux) && canImport(CJavaScriptCoreGTK)
import CJavaScriptCoreGTK

public final class LinuxJavaScriptCoreGTKExecutor: @unchecked Sendable, BotwireJSExecutor {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    private static let concurrencyLimiter = DispatchSemaphore(
        value: Int(ProcessInfo.processInfo.environment["BOTWIRE_MAX_JS_THREADS"] ?? "8") ?? 8
    )

    public func execute(_ request: BotwireJSExecutionRequest, runID: String) async -> BotwireJSExecutionReport {
        let started = Date()
        return await withCheckedContinuation { continuation in
            // Use a shared concurrent queue instead of creating a new queue every time
            DispatchQueue.global(qos: .userInitiated).async {
                Self.concurrencyLimiter.wait()
                defer { Self.concurrencyLimiter.signal() }
                continuation.resume(returning: self.executeSync(request, runID: runID, started: started))
            }
        }
    }

    private func executeSync(
        _ request: BotwireJSExecutionRequest,
        runID: String,
        started: Date
    ) -> BotwireJSExecutionReport {
        guard let context = jsc_context_new() else {
            return BotwireJSExecutionReport(
                success: false,
                events: [BotwireRunEvent(runID: runID, kind: .failed, message: "Failed to create JavaScriptCoreGTK context.")],
                errorMessage: "Failed to create JavaScriptCoreGTK context.",
                durationMs: durationMs(since: started)
            )
        }
        defer { g_object_unref(context) }

        let bootstrap = """
        var __botwireReport = {
          completed: false,
          result: null,
          httpResponse: null,
          logs: [],
          events: [{ kind: 'started', message: 'AgentBlock execution started.' }],
          error: null
        };
        var console = {
          log: function(value) { __botwireReport.logs.push(String(value)); }
        };
        var __botwireRequests = [];
        var __botwirePendingRequests = {};

        var setTimeout = function(callback, delayMs) {
            var reqId = Math.random().toString(36);
            __botwirePendingRequests[reqId] = { resolve: callback, reject: function(){} };
            __botwireRequests.push({ id: reqId, command: 'setTimeout', args: String(delayMs || 0) });
        };

        function __botwireParseSSEText(text, onChunk) {
            var lines = String(text || '').split(/\\r?\\n/);
            var eventType = 'message';
            var eventID = null;
            var dataLines = [];
            function flush() {
                if (!dataLines.length) return;
                var event = { event: eventType, data: dataLines.join('\\n') };
                if (eventID !== null) event.id = eventID;
                if (typeof onChunk === 'function') onChunk(event);
                eventType = 'message';
                eventID = null;
                dataLines = [];
            }
            for (var i = 0; i < lines.length; i++) {
                var line = lines[i];
                if (line === '') flush();
                else if (line.indexOf('data:') === 0) dataLines.push(line.slice(5).trimStart());
                else if (line.indexOf('event:') === 0) eventType = line.slice(6).trim();
                else if (line.indexOf('id:') === 0) eventID = line.slice(3).trim();
            }
            flush();
        }

        function __botwireUnsupportedMedia(feature, reason) {
            var error = new Error(reason || (feature + ' is not supported in this Botwire runtime.'));
            error.code = 'BOTWIRE_MEDIA_UNSUPPORTED';
            error.feature = feature;
            error.supported = false;
            return Promise.reject(error);
        }

        function __botwireMediaKind(mimeType, path) {
            var mime = String(mimeType || '').toLowerCase();
            var filePath = String(path || '').toLowerCase();
            if (mime.indexOf('audio/') === 0 || /\\.(mp3|wav|m4a|aac|flac|ogg|opus)$/i.test(filePath)) return 'audio';
            if (mime.indexOf('video/') === 0 || /\\.(mp4|mov|m4v|webm|avi|mkv)$/i.test(filePath)) return 'video';
            if (mime.indexOf('image/') === 0 || /\\.(png|jpg|jpeg|gif|webp|heic|heif)$/i.test(filePath)) return 'image';
            return 'file';
        }

        var Botwire = {
          input: \(request.inputJSON ?? "null"),
          agent: {
            objective: \(Self.javascriptLiteral(request.objective)),
            updateStatus: function(message) {
              __botwireReport.events.push({ kind: 'status', message: String(message) });
            },
            complete: function(payload) {
              __botwireReport.completed = true;
              __botwireReport.result = payload === undefined ? null : payload;
              __botwireReport.events.push({ kind: 'completed', message: 'AgentBlock completed.' });
            }
          },
          fetch: function(url, options) {
            return new Promise(function(resolve, reject) {
                var reqId = Math.random().toString(36);
                __botwirePendingRequests[reqId] = { resolve: resolve, reject: reject };
                var fetchArgs = { url: url, method: options ? options.method : 'GET', headers: options ? options.headers : null, body: options ? options.body : null };
                __botwireRequests.push({ id: reqId, command: 'fetch', args: JSON.stringify(fetchArgs) });
            });
          },
          http: {
            status: function(code) {
               if (!__botwireReport.httpResponse) __botwireReport.httpResponse = { status: 200, headers: {}, body: "" };
               __botwireReport.httpResponse.status = code;
            },
            send: function(body) {
               if (!__botwireReport.httpResponse) __botwireReport.httpResponse = { status: 200, headers: {}, body: "" };
               __botwireReport.httpResponse.body = typeof body === 'string' ? body : JSON.stringify(body);
               __botwireReport.completed = true;
            }
          },
          db: {
            __execute: function(queryObj) {
              return new Promise(function(resolve, reject) {
                  var reqId = Math.random().toString(36);
                  __botwirePendingRequests[reqId] = { resolve: resolve, reject: reject };
                  __botwireRequests.push({ id: reqId, command: 'db', args: JSON.stringify(queryObj) });
              }).then(function(result) {
                  if (result && typeof result === "object" && "data" in result) {
                      return result.data;
                  }
                  return result;
              });
            },
            __normalizeArgs: function(database, collection, options) {
              if (database && typeof database === "object" && !Array.isArray(database)) {
                return {
                  database: String(database.database || ""),
                  collection: String(database.collection || ""),
                  options: {
                    scope: database.scope || "algorithm",
                    sort: database.sort,
                    skip: database.skip,
                    limit: database.limit
                  },
                  document: database.document,
                  documents: database.documents,
                  query: database.query,
                  update: database.update
                };
              }
              return {
                database: String(database),
                collection: String(collection),
                options: options || {}
              };
            },
            createCollection: function(database, collection, options) {
              var norm = this.__normalizeArgs(database, collection, options);
              return this.__execute({cmd: "create_collection", database: norm.database, collection: norm.collection});
            },
            insertOne: function(database, collection, document, options) {
              var norm = this.__normalizeArgs(database, collection, options);
              return this.__execute({cmd: "insert", database: norm.database, collection: norm.collection, doc: norm.document || document || {}});
            },
            insertMany: function(database, collection, documents, options) {
              var norm = this.__normalizeArgs(database, collection, options);
              var payloadDocs = norm.documents || documents;
              return this.__execute({cmd: "insert_many", database: norm.database, collection: norm.collection, docs: Array.isArray(payloadDocs) ? payloadDocs : []});
            },
            find: function(database, collection, query, options) {
              var norm = this.__normalizeArgs(database, collection, options);
              var opts = norm.options || {};
              var cmd = {cmd: "find", database: norm.database, collection: norm.collection, query: norm.query || query || {}};
              if (opts.sort) cmd.sort = opts.sort;
              if (opts.skip !== undefined) cmd.skip = opts.skip;
              if (opts.limit !== undefined) cmd.limit = opts.limit;
              return this.__execute(cmd);
            },
            findOne: function(database, collection, query, options) {
              var norm = this.__normalizeArgs(database, collection, options);
              return this.__execute({cmd: "find_one", database: norm.database, collection: norm.collection, query: norm.query || query || {}});
            },
            updateOne: function(database, collection, query, update, options) {
              var norm = this.__normalizeArgs(database, collection, options);
              return this.__execute({cmd: "update_one", database: norm.database, collection: norm.collection, query: norm.query || query || {}, update: norm.update || update || {}});
            },
            deleteOne: function(database, collection, query, options) {
              var norm = this.__normalizeArgs(database, collection, options);
              return this.__execute({cmd: "delete_one", database: norm.database, collection: norm.collection, query: norm.query || query || {}});
            },
            count: function(database, collection, query, options) {
              var norm = this.__normalizeArgs(database, collection, options);
              return this.__execute({cmd: "count", database: norm.database, collection: norm.collection, query: norm.query || query || {}});
            }
          },
          config: {
            getLLMProfiles: function() {
              return new Promise(function(resolve, reject) {
                  var reqId = Math.random().toString(36);
                  __botwirePendingRequests[reqId] = { resolve: resolve, reject: reject };
                  __botwireRequests.push({ id: reqId, command: 'config.getLLMProfiles', args: "{}" });
              });
            },
            getAgentProfiles: function() {
              return new Promise(function(resolve, reject) {
                  var reqId = Math.random().toString(36);
                  __botwirePendingRequests[reqId] = { resolve: resolve, reject: reject };
                  __botwireRequests.push({ id: reqId, command: 'config.getAgentProfiles', args: "{}" });
              });
            },
            getAgents: function() {
              return new Promise(function(resolve, reject) {
                  var reqId = Math.random().toString(36);
                  __botwirePendingRequests[reqId] = { resolve: resolve, reject: reject };
                  __botwireRequests.push({ id: reqId, command: 'config.getAgents', args: "{}" });
              });
            },
            getSkills: function() {
              return new Promise(function(resolve, reject) {
                  var reqId = Math.random().toString(36);
                  __botwirePendingRequests[reqId] = { resolve: resolve, reject: reject };
                  __botwireRequests.push({ id: reqId, command: 'config.getSkills', args: "{}" });
              });
            },
            getContexts: function() {
              return new Promise(function(resolve, reject) {
                  var reqId = Math.random().toString(36);
                  __botwirePendingRequests[reqId] = { resolve: resolve, reject: reject };
                  __botwireRequests.push({ id: reqId, command: 'config.getContexts', args: "{}" });
              });
            },
            evalScriptedContext: function(key) {
              return new Promise(function(resolve, reject) {
                  var reqId = Math.random().toString(36);
                  __botwirePendingRequests[reqId] = { resolve: resolve, reject: reject };
                  __botwireRequests.push({ id: reqId, command: 'config.evalScriptedContext', args: JSON.stringify({ key: String(key || "") }) });
              });
            }
          },
          tools: {
            list: function() {
              return new Promise(function(resolve, reject) {
                  var reqId = Math.random().toString(36);
                  __botwirePendingRequests[reqId] = { resolve: resolve, reject: reject };
                  __botwireRequests.push({ id: reqId, command: 'tools.list', args: "{}" });
              });
            },
            run: function(name, args) {
              return new Promise(function(resolve, reject) {
                  var reqId = Math.random().toString(36);
                  __botwirePendingRequests[reqId] = { resolve: resolve, reject: reject };
                  var argsStr = (typeof args === 'string') ? args : JSON.stringify(args || {});
                  __botwireRequests.push({ id: reqId, command: 'tools.run', args: JSON.stringify({name: name, args: argsStr}) });
              });
            }
          },
          files: {
            read: function(path, options) {
              return new Promise(function(resolve, reject) {
                var reqId = Math.random().toString(36);
                __botwirePendingRequests[reqId] = { resolve: resolve, reject: reject };
                var args = typeof options === 'object' ? Object.assign({ relativePath: path, operation: 'read' }, options) : { relativePath: path, operation: 'read' };
                __botwireRequests.push({ id: reqId, command: 'files', args: JSON.stringify(args) });
              });
            },
            list: function(options) {
              return new Promise(function(resolve, reject) {
                var reqId = Math.random().toString(36);
                __botwirePendingRequests[reqId] = { resolve: resolve, reject: reject };
                var args = Object.assign({ operation: 'list' }, options || {});
                __botwireRequests.push({ id: reqId, command: 'files', args: JSON.stringify(args) });
              });
            }
          },
          stream: function(url, options, onChunk, onDone) {
            return Botwire.fetch(url, options || {}).then(function(response) {
              var body = '';
              if (response && typeof response.text === 'function') {
                return response.text();
              }
              if (response && typeof response.body === 'string') {
                body = response.body;
              }
              return body;
            }).then(function(text) {
              __botwireParseSSEText(text, onChunk);
              if (typeof onDone === 'function') onDone();
            });
          },
          media: {
            capabilities: function() {
              return Promise.resolve({
                runtime: 'linux-javascriptcoregtk',
                files: { read: true, write: false, dataURL: true },
                audio: { input: false, output: true, capture: false, playback: false },
                video: { input: false, output: true, capture: false, playback: false },
                streaming: {
                  sse: true,
                  incremental: false,
                  binary: false,
                  notes: 'Linux parses SSE from fetch responses after download; media helpers are project-file backed.'
                }
              });
            },
            read: function(pathOrOptions, options) {
              var payload = (pathOrOptions && typeof pathOrOptions === 'object' && !Array.isArray(pathOrOptions))
                ? Object.assign({}, pathOrOptions)
                : Object.assign({}, options || {}, { path: String(pathOrOptions || '') });
              payload.encoding = payload.encoding || 'base64';
              var path = payload.path || payload.relativePath || '';
              return Botwire.files.read(path, payload).then(function(result) {
                var file = result && result.file ? result.file : {};
                var mimeType = payload.mimeType || file.mimeType || result.mimeType || 'application/octet-stream';
                var mediaPath = file.path || file.relativePath || path;
                return {
                  success: true,
                  kind: __botwireMediaKind(mimeType, mediaPath),
                  mimeType: mimeType,
                  encoding: result.encoding || payload.encoding,
                  content: result.content,
                  file: file
                };
              });
            },
            describe: function(pathOrOptions, options) {
              return Botwire.media.read(pathOrOptions, options).then(function(media) {
                delete media.content;
                return media;
              });
            },
            toDataURL: function(pathOrOptions, options) {
              return Botwire.media.read(pathOrOptions, Object.assign({}, options || {}, { encoding: 'base64' })).then(function(media) {
                return 'data:' + media.mimeType + ';base64,' + (media.content || '');
              });
            },
            captureAudio: function() { return __botwireUnsupportedMedia('media.captureAudio', 'Microphone capture is not available on the Linux runner host bridge.'); },
            captureVideo: function() { return __botwireUnsupportedMedia('media.captureVideo', 'Camera capture is not available on the Linux runner host bridge.'); },
            playAudio: function() { return __botwireUnsupportedMedia('media.playAudio', 'Audio playback is not available in the headless Linux runner.'); },
            playVideo: function() { return __botwireUnsupportedMedia('media.playVideo', 'Video playback is not available in the headless Linux runner.'); }
          }
        };
        """


        _ = evaluate(bootstrap, context: context)
        if let error = exceptionString(context: context) {
            return failure(runID: runID, message: error, started: started)
        }

        // Browser automation bootstrap — adds `browser` global with Playwright-compatible API
        let browserBootstrap = """
        var browser = (function() {
          function browserCall(method, params) {
            return new Promise(function(resolve, reject) {
              var reqId = Math.random().toString(36);
              __botwirePendingRequests[reqId] = { resolve: resolve, reject: reject };
              __botwireRequests.push({
                id: reqId,
                command: 'browser',
                args: JSON.stringify({ method: method, params: params || {} })
              });
            });
          }

          function createPage(pageId) {
            return {
              _pageId: pageId,
              goto: function(url, options) { return browserCall('page.goto', { pageId: pageId, url: url, options: options }); },
              click: function(selector, options) { return browserCall('page.click', { pageId: pageId, selector: selector, options: options }); },
              fill: function(selector, value) { return browserCall('page.fill', { pageId: pageId, selector: selector, value: value }); },
              type: function(selector, text, options) { return browserCall('page.type', { pageId: pageId, selector: selector, text: text, options: options }); },
              press: function(selector, key) { return browserCall('page.press', { pageId: pageId, selector: selector, key: key }); },
              textContent: function(selector) { return browserCall('page.textContent', { pageId: pageId, selector: selector }); },
              innerHTML: function(selector) { return browserCall('page.innerHTML', { pageId: pageId, selector: selector }); },
              getAttribute: function(selector, name) { return browserCall('page.getAttribute', { pageId: pageId, selector: selector, name: name }); },
              evaluate: function(expression) {
                var expr = (typeof expression === 'function') ? '(' + expression.toString() + ')()' : expression;
                return browserCall('page.evaluate', { pageId: pageId, expression: expr });
              },
              querySelector: function(selector) { return browserCall('page.querySelector', { pageId: pageId, selector: selector }); },
              querySelectorAll: function(selector, maxResults) { return browserCall('page.querySelectorAll', { pageId: pageId, selector: selector, maxResults: maxResults }); },
              waitForSelector: function(selector, options) { return browserCall('page.waitForSelector', { pageId: pageId, selector: selector, options: options }); },
              waitForNavigation: function(options) { return browserCall('page.waitForNavigation', { pageId: pageId, options: options }); },
              waitForURL: function(url, options) { return browserCall('page.waitForURL', { pageId: pageId, url: url, options: options }); },
              waitForTimeout: function(timeout) { return browserCall('page.waitForTimeout', { pageId: pageId, timeout: timeout }); },
              screenshot: function(options) { return browserCall('page.screenshot', { pageId: pageId, options: options }); },
              title: function() { return browserCall('page.title', { pageId: pageId }); },
              url: function() { return browserCall('page.url', { pageId: pageId }); },
              content: function() { return browserCall('page.content', { pageId: pageId }); },
              select: function(selector) { var values = Array.prototype.slice.call(arguments, 1); return browserCall('page.select', { pageId: pageId, selector: selector, values: values }); },
              check: function(selector) { return browserCall('page.check', { pageId: pageId, selector: selector }); },
              uncheck: function(selector) { return browserCall('page.uncheck', { pageId: pageId, selector: selector }); },
              hover: function(selector) { return browserCall('page.hover', { pageId: pageId, selector: selector }); },
              focus: function(selector) { return browserCall('page.focus', { pageId: pageId, selector: selector }); },
              dblclick: function(selector) { return browserCall('page.dblclick', { pageId: pageId, selector: selector }); },
              selectText: function(selector) { return browserCall('page.selectText', { pageId: pageId, selector: selector }); },
              setViewportSize: function(size) { return browserCall('page.setViewportSize', { pageId: pageId, width: size.width, height: size.height }); },
              bringToFront: function() { return browserCall('page.bringToFront', { pageId: pageId }); },
              goBack: function(options) { return browserCall('page.goBack', { pageId: pageId, options: options }); },
              goForward: function(options) { return browserCall('page.goForward', { pageId: pageId, options: options }); },
              reload: function(options) { return browserCall('page.reload', { pageId: pageId, options: options }); },
              close: function() { return browserCall('page.close', { pageId: pageId }); }
            };
          }

          return {
            newPage: function(options) {
              return browserCall('browser.newPage', options || {}).then(function(result) {
                return createPage(result.pageId);
              });
            },
            pages: function() { return browserCall('browser.pages', {}); },
            closeAll: function() { return browserCall('browser.closeAll', {}); }
          };
        })();
        """

        _ = evaluate(browserBootstrap, context: context)
        if let error = exceptionString(context: context) {
            return failure(runID: runID, message: "Browser bootstrap error: \(error)", started: started)
        }

        _ = evaluate(request.source, context: context)
        if let error = exceptionString(context: context) {
            return failure(runID: runID, message: error, started: started)
        }

        if isCancelled {
            return failure(runID: runID, message: "Execution cancelled.", started: started)
        }

        let wrapper = """
        (function() {
          try {
            if (typeof main === 'function') {
              var result = main();
              if (result && typeof result.then === 'function') {
                result.then(function(val) {
                  if (val !== undefined && !__botwireReport.completed) Botwire.agent.complete(val);
                }).catch(function(err) {
                  __botwireReport.error = String(err && err.stack ? err.stack : err);
                  __botwireReport.events.push({ kind: 'failed', message: __botwireReport.error });
                  __botwireReport.completed = true;
                });
              } else if (result !== undefined && !__botwireReport.completed) {
                Botwire.agent.complete(result);
              }
            } else {
              __botwireReport.error = 'AgentBlock did not define a main() function.';
              __botwireReport.events.push({ kind: 'failed', message: __botwireReport.error });
              __botwireReport.completed = true;
            }
          } catch (error) {
            __botwireReport.error = String(error && error.stack ? error.stack : error);
            __botwireReport.events.push({ kind: 'failed', message: __botwireReport.error });
            __botwireReport.completed = true;
          }
        })();
        """

        _ = evaluate(wrapper, context: context)

        let bridge = LinuxJSHostBridge(
            projectId: request.projectId ?? "default",
            algorithmId: request.algorithmId,
            codeBlockId: request.codeBlockId,
            workspacePath: request.workspacePath,
            databaseMutationHandler: request.databaseMutationHandler
        )

        // Wait for completion (allows async JS to drain in GLib MainContext)
        let deadline = Date().addingTimeInterval(request.timeout)
        while !isCancelled && Date() < deadline {
            let responses = bridge.popResponses()
            for res in responses {
                let methodName = res.success ? "resolve" : "reject"
                let jsCallback = "__botwirePendingRequests['\(res.id)'].\(methodName)(\(res.payload)); delete __botwirePendingRequests['\(res.id)'];"
                print("Evaluating: \(jsCallback)")
                _ = evaluate(jsCallback, context: context)
            }
            
            if let reqsJSON = evaluate("JSON.stringify(__botwireRequests.splice(0, __botwireRequests.length))", context: context),
               reqsJSON != "[]", reqsJSON != "undefined" {
                print("Handling JS Reqs: \(reqsJSON)")
                bridge.handleRequests(reqsJSON)
            }

            let isCompleted = evaluate("__botwireReport.completed", context: context)
            if isCompleted == "true" {
                break
            }
            g_main_context_iteration(nil, 0)
            usleep(10_000) // 10ms
        }

        if !isCancelled && Date() >= deadline {
             let error = "AgentBlock did not complete within \(Int(request.timeout))s."
             bridge.shutdownBrowser()
             return failure(runID: runID, message: error, started: started)
        }

        guard let reportJSON = evaluate("JSON.stringify(__botwireReport)", context: context) else {
            let error = exceptionString(context: context) ?? "JavaScriptCoreGTK returned no report."
            return failure(runID: runID, message: error, started: started)
        }

        guard let data = reportJSON.data(using: .utf8),
              let payload = try? JSONDecoder().decode(LinuxJSCReportPayload.self, from: data) else {
            return failure(runID: runID, message: "Failed to decode JavaScriptCoreGTK report: \(reportJSON)", started: started)
        }

        let events = payload.events.map {
            BotwireRunEvent(
                runID: runID,
                kind: BotwireRunEvent.Kind(rawValue: $0.kind) ?? .status,
                message: $0.message
            )
        }

        // Clean up any headless browser processes
        bridge.shutdownBrowser()

        return BotwireJSExecutionReport(
            success: payload.completed && payload.error == nil,
            result: payload.result,
            httpResponseJSON: payload.httpResponse,
            logs: payload.logs,
            events: events,
            errorMessage: payload.error,
            durationMs: durationMs(since: started)
        )
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private func evaluate(_ script: String, context: UnsafeMutablePointer<JSCContext>) -> String? {
        guard let value = script.withCString({ jsc_context_evaluate(context, $0, -1) }) else {
            return nil
        }
        defer { g_object_unref(value) }

        guard let cString = jsc_value_to_string(value) else {
            return nil
        }
        defer { g_free(cString) }
        return String(cString: cString)
    }

    private func exceptionString(context: UnsafeMutablePointer<JSCContext>) -> String? {
        guard let exception = jsc_context_get_exception(context) else {
            return nil
        }
        defer { jsc_context_clear_exception(context) }

        guard let cString = jsc_exception_to_string(exception) else {
            return "Unknown JavaScriptCoreGTK exception."
        }
        defer { g_free(cString) }
        return String(cString: cString)
    }

    private func failure(runID: String, message: String, started: Date) -> BotwireJSExecutionReport {
        BotwireJSExecutionReport(
            success: false,
            events: [
                BotwireRunEvent(runID: runID, kind: .started, message: "AgentBlock execution started."),
                BotwireRunEvent(runID: runID, kind: .failed, message: message)
            ],
            errorMessage: message,
            durationMs: durationMs(since: started)
        )
    }

    private func durationMs(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }

    private static func javascriptLiteral(_ string: String) -> String {
        guard let data = try? JSONEncoder().encode(string),
              let literal = String(data: data, encoding: .utf8) else {
            return "''"
        }
        return literal
    }
}

private struct LinuxJSCReportPayload: Codable {
    var completed: Bool
    var result: JSONValue?
    var httpResponse: JSONValue?
    var logs: [String]
    var events: [LinuxJSCEventPayload]
    var error: String?
}

private struct LinuxJSCEventPayload: Codable {
    var kind: String
    var message: String
}
#endif
