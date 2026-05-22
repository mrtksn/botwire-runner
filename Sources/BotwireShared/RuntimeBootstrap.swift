// BotwireShared — RuntimeBootstrap
// The canonical JavaScript bootstrap script that defines the Botwire.* API surface.
// This is the SINGLE SOURCE OF TRUTH for all platforms (iOS, macOS, Linux, Android).
//
// Each platform must inject the following native bridge functions BEFORE evaluating
// this bootstrap:
//   __bw_log(message)
//   __bw_fetch(url, optionsJSON, resolve, reject)
//   __bw_db(operation, payloadJSON, resolve, reject)
//   __bw_files(operation, payloadJSON, resolve, reject)
//   __bw_config_llm_profiles(resolve, reject)
//   __bw_stream(url, optionsJSON, onChunk, onDone, onError)    [optional]
//   __bw_agent_config(resolve, reject)                          [optional]
//   __bw_agent_objective                                        [optional]
//   __bw_agent_message(text)                                    [optional]
//   __bw_agent_status(step)                                     [optional]
//   __bw_agent_complete(resultJSON)                             [optional]
//   __bw_workspace_agents(resolve, reject)                      [optional]
//   __bw_tools_list(resolve, reject)                            [optional]
//   __bw_tools_run(name, argsJSON, resolve, reject)             [optional]
//   __bw_setTimeout(callback, delayMs) -> Int                   [optional, WebView has native]
//   __bw_clearTimeout(id)                                       [optional]
//   __bw_setInterval(callback, delayMs) -> Int                  [optional]
//   __bw_clearInterval(id)                                      [optional]
//   __bw_done(payloadJSON)                                      [required for JSContext runtimes]

#if canImport(Foundation)
import Foundation
#elseif canImport(FoundationEssentials)
import FoundationEssentials
#endif

/// Provides the canonical JavaScript bootstrap script shared across all Botwire runtimes.
public enum RuntimeBootstrap {

    /// The full Botwire.* API bootstrap script.
    /// Inject platform-specific `__bw_*` bridge functions before evaluating this.
    public static let script: String = """
    // ═══════════════════════════════════════════════════════════════════════════
    // Botwire Runtime Bootstrap — Shared across iOS, macOS, Linux, Android
    // ═══════════════════════════════════════════════════════════════════════════

    function __bw_safeStringify(value) {
      try {
        return JSON.stringify(value === undefined ? null : value);
      } catch (error) {
        return JSON.stringify(String(value));
      }
    }

    function __bw_toErrorPayload(type, error) {
      return JSON.stringify({
        success: false,
        error: {
          type: type,
          message: error && error.message ? String(error.message) : String(error),
          stack: error && error.stack ? String(error.stack) : null
        }
      });
    }

    // ── DB helpers ────────────────────────────────────────────────────────────

    function __bw_dbCall(operation, payload) {
      return new Promise(function(resolve, reject) {
        __bw_db(String(operation), JSON.stringify(payload || {}), function(rawResponse) {
          try {
            resolve(JSON.parse(rawResponse));
          } catch (error) {
            reject(error);
          }
        }, function(errorMessage) {
          reject(new Error(String(errorMessage)));
        });
      });
    }

    function __bw_dbData(operation, payload) {
      return __bw_dbCall(operation, payload).then(function(result) {
        if (result && Object.prototype.hasOwnProperty.call(result, "data")) {
          return result.data;
        }
        return result;
      });
    }

    // ── File helpers ─────────────────────────────────────────────────────────

    function __bw_fileCall(operation, payload) {
      return new Promise(function(resolve, reject) {
        if (typeof __bw_files !== 'function') {
          reject(new Error('File runtime is unavailable for this execution context.'));
          return;
        }
        __bw_files(String(operation), JSON.stringify(payload || {}), function(rawResponse) {
          try {
            resolve(JSON.parse(rawResponse));
          } catch (error) {
            reject(error);
          }
        }, function(errorMessage) {
          reject(new Error(String(errorMessage)));
        });
      });
    }

    // ── SSE parser ───────────────────────────────────────────────────────────

    function __bw_parseSSEText(text, onChunk) {
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
        if (line === '') {
          flush();
        } else if (line.indexOf('data:') === 0) {
          dataLines.push(line.slice(5).trimStart());
        } else if (line.indexOf('event:') === 0) {
          eventType = line.slice(6).trim();
        } else if (line.indexOf('id:') === 0) {
          eventID = line.slice(3).trim();
        }
      }
      flush();
    }

    // ── Media helpers ────────────────────────────────────────────────────────

    function __bw_unsupportedMediaPromise(feature, reason) {
      var error = new Error(reason || (feature + ' is not supported in this Botwire runtime.'));
      error.code = 'BOTWIRE_MEDIA_UNSUPPORTED';
      error.feature = feature;
      error.supported = false;
      return Promise.reject(error);
    }

    function __bw_mediaKind(mimeType, path) {
      var mime = String(mimeType || '').toLowerCase();
      var filePath = String(path || '').toLowerCase();
      if (mime.indexOf('audio/') === 0 || /\\.(mp3|wav|m4a|aac|flac|ogg|opus)$/i.test(filePath)) return 'audio';
      if (mime.indexOf('video/') === 0 || /\\.(mp4|mov|m4v|webm|avi|mkv)$/i.test(filePath)) return 'video';
      if (mime.indexOf('image/') === 0 || /\\.(png|jpg|jpeg|gif|webp|heic|heif)$/i.test(filePath)) return 'image';
      return 'file';
    }

    function __bw_makeMediaAPI(runtimeName, fileBacked) {
      var caps = {
        runtime: runtimeName,
        files: { read: !!fileBacked, write: !!fileBacked, dataURL: !!fileBacked },
        audio: { input: false, output: !!fileBacked, capture: false, playback: false },
        video: { input: false, output: !!fileBacked, capture: false, playback: false }
      };
      function readMedia(pathOrOptions, options) {
        if (!fileBacked || !Botwire.files || typeof Botwire.files.read !== 'function') {
          return __bw_unsupportedMediaPromise('media.read', 'Project file-backed media is not available in this runtime.');
        }
        var payload = (pathOrOptions && typeof pathOrOptions === 'object' && !Array.isArray(pathOrOptions))
          ? Object.assign({}, pathOrOptions)
          : Object.assign({}, options || {}, { path: String(pathOrOptions || '') });
        payload.encoding = payload.encoding || 'base64';
        return __bw_fileCall('read', payload).then(function(result) {
          var file = result && result.file ? result.file : {};
          var mimeType = payload.mimeType || file.mimeType || 'application/octet-stream';
          var path = file.path || file.relativePath || payload.path || '';
          return {
            success: true,
            kind: __bw_mediaKind(mimeType, path),
            mimeType: mimeType,
            encoding: result.encoding || payload.encoding,
            content: result.content,
            file: file
          };
        });
      }
      return {
        capabilities: function() { return Promise.resolve(JSON.parse(JSON.stringify(caps))); },
        describe: function(pathOrOptions, options) {
          return readMedia(pathOrOptions, options).then(function(media) {
            var copy = Object.assign({}, media);
            delete copy.content;
            return copy;
          });
        },
        read: readMedia,
        toDataURL: function(pathOrOptions, options) {
          return readMedia(pathOrOptions, Object.assign({}, options || {}, { encoding: 'base64' })).then(function(media) {
            return 'data:' + media.mimeType + ';base64,' + (media.content || '');
          });
        },
        captureAudio: function() { return __bw_unsupportedMediaPromise('media.captureAudio', 'Microphone capture not available.'); },
        captureVideo: function() { return __bw_unsupportedMediaPromise('media.captureVideo', 'Camera capture not available.'); },
        playAudio: function() { return __bw_unsupportedMediaPromise('media.playAudio', 'Audio playback not available.'); },
        playVideo: function() { return __bw_unsupportedMediaPromise('media.playVideo', 'Video playback not available.'); }
      };
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Botwire API Object
    // ═══════════════════════════════════════════════════════════════════════════

    var Botwire = {
      log: function() {
        var parts = [];
        for (var i = 0; i < arguments.length; i++) {
          var item = arguments[i];
          if (typeof item === 'string') { parts.push(item); }
          else { parts.push(__bw_safeStringify(item)); }
        }
        __bw_log(parts.join(' '));
      },

      fetch: function(url, options) {
        return new Promise(function(resolve, reject) {
          __bw_fetch(String(url), JSON.stringify(options || {}), function(rawResponse) {
            try {
              var parsed = JSON.parse(rawResponse);
              var status = Number(parsed && parsed.status ? parsed.status : 0);
              var body = parsed && typeof parsed.body === 'string' ? parsed.body : '';
              var headersObject = parsed && parsed.headers ? parsed.headers : {};
              resolve({
                status: status,
                ok: status >= 200 && status < 300,
                headers: headersObject,
                text: function() { return Promise.resolve(body); },
                json: function() {
                  try { return Promise.resolve(JSON.parse(body)); }
                  catch (error) { return Promise.reject(error); }
                }
              });
            } catch (error) { reject(error); }
          }, function(errorMessage) {
            reject(new Error(String(errorMessage)));
          });
        });
      },

      db: {
        __normalizeArgs: function(database, collection, options) {
          if (database && typeof database === "object" && !Array.isArray(database)) {
            return {
              database: String(database.database || ""),
              collection: String(database.collection || ""),
              options: {
                scope: database.scope || "algorithm",
                sort: database.sort, skip: database.skip, limit: database.limit
              },
              document: database.document, documents: database.documents,
              query: database.query, update: database.update
            };
          }
          return { database: String(database), collection: String(collection), options: options || {} };
        },
        createCollection: function(database, collection, options) {
          var n = this.__normalizeArgs(database, collection, options);
          return __bw_dbData("createCollection", { database: n.database, scope: (n.options||{}).scope, collection: n.collection });
        },
        insertOne: function(database, collection, document, options) {
          var n = this.__normalizeArgs(database, collection, options);
          return __bw_dbData("insertOne", { database: n.database, scope: (n.options||{}).scope, collection: n.collection, document: n.document || document || {} });
        },
        insertMany: function(database, collection, documents, options) {
          var n = this.__normalizeArgs(database, collection, options);
          return __bw_dbData("insertMany", { database: n.database, scope: (n.options||{}).scope, collection: n.collection, documents: n.documents || documents || [] });
        },
        find: function(database, collection, query, options) {
          var n = this.__normalizeArgs(database, collection, options);
          var o = n.options || {};
          return __bw_dbData("find", { database: n.database, scope: o.scope, collection: n.collection, query: n.query || query || {}, sort: o.sort, skip: o.skip, limit: o.limit });
        },
        findOne: function(database, collection, query, options) {
          var n = this.__normalizeArgs(database, collection, options);
          return __bw_dbData("findOne", { database: n.database, scope: (n.options||{}).scope, collection: n.collection, query: n.query || query || {} });
        },
        updateOne: function(database, collection, query, update, options) {
          var n = this.__normalizeArgs(database, collection, options);
          return __bw_dbData("updateOne", { database: n.database, scope: (n.options||{}).scope, collection: n.collection, query: n.query || query || {}, update: n.update || update || {} });
        },
        deleteOne: function(database, collection, query, options) {
          var n = this.__normalizeArgs(database, collection, options);
          return __bw_dbData("deleteOne", { database: n.database, scope: (n.options||{}).scope, collection: n.collection, query: n.query || query || {} });
        },
        count: function(database, collection, query, options) {
          var n = this.__normalizeArgs(database, collection, options);
          return __bw_dbData("count", { database: n.database, scope: (n.options||{}).scope, collection: n.collection, query: n.query || query || {} });
        }
      },

      files: {
        list: function(folder) { return __bw_fileCall("list", { folder: folder || "" }); },
        folders: function() { return __bw_fileCall("folders", {}); },
        read: function(pathOrOptions, options) {
          var payload = (pathOrOptions && typeof pathOrOptions === "object" && !Array.isArray(pathOrOptions))
            ? pathOrOptions : Object.assign({}, options || {}, { path: String(pathOrOptions || "") });
          return __bw_fileCall("read", payload).then(function(result) {
            return result && Object.prototype.hasOwnProperty.call(result, "content") ? result.content : result;
          });
        },
        write: function(pathOrOptions, content, options) {
          var payload = (pathOrOptions && typeof pathOrOptions === "object" && !Array.isArray(pathOrOptions))
            ? pathOrOptions : Object.assign({}, options || {}, { path: String(pathOrOptions || ""), content: String(content || "") });
          return __bw_fileCall("write", payload);
        },
        delete: function(pathOrOptions) {
          var payload = (pathOrOptions && typeof pathOrOptions === "object" && !Array.isArray(pathOrOptions))
            ? pathOrOptions : { path: String(pathOrOptions || "") };
          return __bw_fileCall("delete", payload);
        },
        createFolder: function(name) { return __bw_fileCall("createFolder", { name: String(name || "") }); }
      },

      config: {
        getLLMProfiles: function() {
          return new Promise(function(resolve, reject) {
            if (typeof __bw_config_llm_profiles !== 'function') {
              reject(new Error('LLM config access is not available in this runtime.'));
              return;
            }
            __bw_config_llm_profiles(
              function(result) { try { resolve(JSON.parse(result)); } catch(e) { reject(e); } },
              function(error) { reject(new Error(String(error))); }
            );
          });
        }
      },

      stream: function(url, options, onChunk, onDone) {
        return new Promise(function(resolve, reject) {
          if (typeof __bw_stream !== 'function') {
            Botwire.fetch(url, options || {}).then(function(response) {
              return response.text();
            }).then(function(text) {
              __bw_parseSSEText(text, onChunk);
              if (typeof onDone === 'function') onDone();
              resolve();
            }).catch(reject);
            return;
          }
          __bw_stream(
            String(url), JSON.stringify(options || {}),
            function(eventJSON) {
              if (typeof onChunk === 'function') {
                try { onChunk(JSON.parse(eventJSON)); } catch(_) { onChunk(eventJSON); }
              }
            },
            function() {
              if (typeof onDone === 'function') onDone();
              resolve();
            },
            function(errorMsg) { reject(new Error(String(errorMsg))); }
          );
        });
      },

      media: __bw_makeMediaAPI('botwire-shared', true)
    };

    // ── Shorthand `db` global (mirrors iOS) ──────────────────────────────────
    var db = {
      createCollection: function(d,c,o) { return Botwire.db.createCollection(d,c,o); },
      insertOne:        function(d,c,doc,o) { return Botwire.db.insertOne(d,c,doc,o); },
      insertMany:       function(d,c,docs,o) { return Botwire.db.insertMany(d,c,docs,o); },
      find:             function(d,c,q,o) { return Botwire.db.find(d,c,q,o); },
      findOne:          function(d,c,q,o) { return Botwire.db.findOne(d,c,q,o); },
      updateOne:        function(d,c,q,u,o) { return Botwire.db.updateOne(d,c,q,u,o); },
      deleteOne:        function(d,c,q,o) { return Botwire.db.deleteOne(d,c,q,o); },
      count:            function(d,c,q,o) { return Botwire.db.count(d,c,q,o); }
    };

    // ── Console ──────────────────────────────────────────────────────────────
    var console = {
      log:   function() { Botwire.log.apply(null, arguments); },
      warn:  function() { Botwire.log.apply(null, arguments); },
      error: function() { Botwire.log.apply(null, arguments); },
      info:  function() { Botwire.log.apply(null, arguments); },
      debug: function() { Botwire.log.apply(null, arguments); }
    };

    // ── Timer polyfills (for JSContext runtimes; WebView has native) ─────────
    if (typeof setTimeout === 'undefined' && typeof __bw_setTimeout === 'function') {
      function setTimeout(fn, delay) { return __bw_setTimeout(fn, delay || 0); }
      function clearTimeout(id) { __bw_clearTimeout(id); }
      function setInterval(fn, delay) { return __bw_setInterval(fn, delay || 0); }
      function clearInterval(id) { __bw_clearInterval(id); }
    }

    // ── globalThis exposure ──────────────────────────────────────────────────
    if (typeof globalThis !== 'undefined') {
      globalThis.Botwire = Botwire;
      globalThis.db = db;
      globalThis.console = console;
      globalThis.fetch = Botwire.fetch;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Agent & Tools Bootstrap (installed when agent bridges are available)
    // ═══════════════════════════════════════════════════════════════════════════

    if (typeof Botwire !== 'undefined') {
      Botwire.agent = {
        objective: (typeof __bw_agent_objective !== 'undefined') ? __bw_agent_objective : '',
        getConfig: function() {
          return new Promise(function(resolve, reject) {
            if (typeof __bw_agent_config !== 'function') {
              reject(new Error('Agent config not available.'));
              return;
            }
            __bw_agent_config(
              function(result) { try { resolve(JSON.parse(result)); } catch(e) { reject(e); } },
              function(error) { reject(new Error(String(error))); }
            );
          });
        },
        sendMessage: function(text) {
          if (typeof __bw_agent_message === 'function') __bw_agent_message(String(text));
        },
        updateStatus: function(step) {
          if (typeof __bw_agent_status === 'function') __bw_agent_status(String(step));
        },
        complete: function(result) {
          if (typeof __bw_agent_complete === 'function') {
            __bw_agent_complete(typeof result === 'string' ? result : JSON.stringify(result));
          }
        }
      };

      if (!Botwire.config) Botwire.config = {};
      Botwire.config.getAgents = function() {
        return new Promise(function(resolve, reject) {
          if (typeof __bw_workspace_agents !== 'function') {
            reject(new Error('Workspace agents not available.'));
            return;
          }
          __bw_workspace_agents(
            function(result) { try { resolve(JSON.parse(result)); } catch(e) { reject(e); } },
            function(error) { reject(new Error(String(error))); }
          );
        });
      };

      Botwire.tools = {
        list: function() {
          return new Promise(function(resolve, reject) {
            if (typeof __bw_tools_list !== 'function') { resolve([]); return; }
            __bw_tools_list(
              function(result) { try { resolve(JSON.parse(result)); } catch(e) { reject(e); } },
              function(error) { reject(new Error(String(error))); }
            );
          });
        },
        run: function(name, args) {
          return new Promise(function(resolve, reject) {
            if (typeof __bw_tools_run !== 'function') {
              reject(new Error('Tool execution not available.'));
              return;
            }
            var argsStr = (typeof args === 'string') ? args : JSON.stringify(args || {});
            __bw_tools_run(String(name), argsStr,
              function(result) { try { resolve(JSON.parse(result)); } catch(_) { resolve(result); } },
              function(error) { try { reject(JSON.parse(error)); } catch(_) { reject(new Error(String(error))); } }
            );
          });
        }
      };
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // User Code Runner (the entry point called by native runtimes)
    // ═══════════════════════════════════════════════════════════════════════════

    function __bw_runUserCode(source, inputJSON) {
      var runtimeGlobal = (typeof globalThis !== 'undefined') ? globalThis : null;
      var input = null;
      try { input = JSON.parse(inputJSON || 'null'); } catch (_) { input = null; }

      // HTTP req/res bridge
      var __httpRes = { statusCode: 200, headers: { 'Content-Type': 'application/json' }, body: '', sent: false };
      var req = null;
      var res = null;

      if (input && typeof input === 'object' && input.method && input.url) {
        req = {
          method: input.method,
          url: input.url,
          headers: input.headers || {},
          body: input.body || '',
          query: input.query || {},
          get: function(name) {
            var lower = String(name).toLowerCase();
            for (var k in this.headers) {
              if (k.toLowerCase() === lower) return this.headers[k];
            }
            return undefined;
          }
        };
        if (typeof req.body === 'string' && req.body.length > 0) {
          try { req.bodyJSON = JSON.parse(req.body); } catch(_) { req.bodyJSON = null; }
        }
        res = {
          __state: __httpRes,
          status: function(code) { this.__state.statusCode = code; return this; },
          setHeader: function(name, value) { this.__state.headers[name] = value; return this; },
          json: function(data) {
            this.__state.headers['Content-Type'] = 'application/json';
            this.__state.body = JSON.stringify(data);
            this.__state.sent = true;
            return this;
          },
          send: function(body) {
            if (typeof body === 'object') return this.json(body);
            this.__state.body = String(body);
            this.__state.sent = true;
            return this;
          },
          end: function() { this.__state.sent = true; return this; }
        };
        if (runtimeGlobal) {
          runtimeGlobal.req = req;
          runtimeGlobal.res = res;
        }
      }

      var runtimeModule = { exports: {} };
      var runtimeExports = runtimeModule.exports;
      var previousModule = runtimeGlobal ? runtimeGlobal.module : undefined;
      var previousExports = runtimeGlobal ? runtimeGlobal.exports : undefined;
      if (runtimeGlobal) {
        runtimeGlobal.module = runtimeModule;
        runtimeGlobal.exports = runtimeExports;
      }

      try {
        function __bw_applyReturnedHttpResponse(output) {
          if (!req || __httpRes.sent || !output || typeof output !== 'object') return;
          var hasStatus = Object.prototype.hasOwnProperty.call(output, 'status') || Object.prototype.hasOwnProperty.call(output, 'statusCode');
          var hasBody = Object.prototype.hasOwnProperty.call(output, 'body');
          var hasHeaders = output.headers && typeof output.headers === 'object';
          if (!hasStatus && !hasBody && !hasHeaders) return;

          if (hasStatus) {
            var rawStatus = Object.prototype.hasOwnProperty.call(output, 'status') ? output.status : output.statusCode;
            var parsedStatus = Number(rawStatus);
            if (isFinite(parsedStatus) && parsedStatus >= 100 && parsedStatus <= 999) {
              __httpRes.statusCode = Math.floor(parsedStatus);
            }
          }

          if (hasHeaders) {
            for (var headerName in output.headers) {
              if (Object.prototype.hasOwnProperty.call(output.headers, headerName)) {
                __httpRes.headers[headerName] = String(output.headers[headerName]);
              }
            }
          }

          if (hasBody) {
            var body = output.body;
            if (body === null || typeof body === 'undefined') {
              __httpRes.body = '';
            } else if (typeof body === 'string') {
              __httpRes.body = body;
            } else {
              __httpRes.body = JSON.stringify(body);
            }
          }
          __httpRes.sent = true;
        }

        function finalizeSuccess(value) {
          if (runtimeGlobal) {
            runtimeGlobal.module = previousModule;
            runtimeGlobal.exports = previousExports;
          }
          var output = value;
          if (output === null || typeof output === "undefined") {
            if (runtimeModule.exports !== runtimeExports) {
              output = runtimeModule.exports;
            } else if (runtimeExports && typeof runtimeExports === "object" && Object.keys(runtimeExports).length > 0) {
              output = runtimeExports;
            }
          }
          __bw_applyReturnedHttpResponse(output);
          var payload = { success: true, result: output === undefined ? null : output };
          if (__httpRes.sent || (req !== null)) {
            payload.__httpResponse = __httpRes;
          }
          __bw_done(JSON.stringify(payload));
        }
        function finalizeError(error) {
          if (runtimeGlobal) {
            runtimeGlobal.module = previousModule;
            runtimeGlobal.exports = previousExports;
          }
          __bw_done(__bw_toErrorPayload('runtime', error));
        }

        var AsyncFunction = Object.getPrototypeOf(async function(){}).constructor;
        var userFn = new AsyncFunction('input', 'req', 'res', 'Botwire', 'require', 'module', 'exports', source + '\\n; if (typeof result !== "undefined") { return result; } return null;');
        userFn(input, req, res, Botwire, undefined, runtimeModule, runtimeExports)
          .then(finalizeSuccess)
          .catch(finalizeError);
      } catch (error) {
        if (runtimeGlobal) {
          runtimeGlobal.module = previousModule;
          runtimeGlobal.exports = previousExports;
        }
        __bw_done(__bw_toErrorPayload('syntax', error));
      }
    }
    """
}
