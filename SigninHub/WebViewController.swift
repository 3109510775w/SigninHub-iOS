import SwiftUI
import WebKit

struct WebView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(context.coordinator, forURLScheme: "signhub")
        cfg.userContentController.add(context.coordinator, name: "signhub")
        cfg.userContentController.addUserScript(WKUserScript(source: Self.bridgeJS(), injectionTime: .atDocumentStart, forMainFrameOnly: false))
        cfg.userContentController.addUserScript(WKUserScript(source: Self.patchJS(), injectionTime: .atDocumentEnd, forMainFrameOnly: false))

        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = context.coordinator
        web.isOpaque = false
        web.backgroundColor = UIColor(red: 0.04, green: 0.043, blue: 0.063, alpha: 1)
        web.scrollView.contentInsetAdjustmentBehavior = .never
        context.coordinator.webView = web
        web.load(URLRequest(url: URL(string: "signhub://app/index.html")!))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    // MARK: - JS 桥

    static func bridgeJS() -> String {
        """
        (function(){
          window.__signhubSeq = 0;
          window.__signhubPending = {};

          window.__signhubResp = function(text){
            try {
              var status = 200;
              var body = (typeof text === 'string') ? text : JSON.stringify(text);
              return new Response(body, { status: status, headers: {'Content-Type':'application/json'} });
            } catch(e) {
              return new Response(String(text), { status: 200, headers: {'Content-Type':'application/json'} });
            }
          };

          window.SignHubApi = {
            requestAsync: function(id, method, path, body){
              window.webkit.messageHandlers.signhub.postMessage({id:id, method:method, path:path, body:String(body||'')});
            },
            openLogin: function(p){ window.webkit.messageHandlers.signhub.postMessage({cmd:'openLogin', p:p}); },
            openAccounts: function(){ window.webkit.messageHandlers.signhub.postMessage({cmd:'openAccounts'}); },
            openMultiAccounts: function(p){ window.webkit.messageHandlers.signhub.postMessage({cmd:'openMultiAccounts', p:p}); },
            resetCreds: function(key){ window.webkit.messageHandlers.signhub.postMessage({cmd:'resetCreds', key:key}); },
            runAutoNow: function(){ window.webkit.messageHandlers.signhub.postMessage({cmd:'runAutoNow'}); },
            openBatterySettings: function(){},
            openExactAlarmSettings: function(){},
            openAutoStartSettings: function(){},
            setSystemBars: function(dark){},
            insets: function(){ return '{}'; },
            bgStatus: function(){ return '{}'; },
            sysDark: function(){ return 'false'; }
          };

          var origFetch = window.fetch ? window.fetch.bind(window) : null;
          window.fetch = function(input, init){
            var url = (typeof input === 'string') ? input : ((input && input.url) || '');
            var abs = null;
            try { abs = new URL(url, location.href); } catch(e) { abs = null; }
            if (abs && abs.pathname.indexOf('/api/') === 0) {
              var method = (init && init.method) || 'GET';
              var body = '';
              if (init && init.body) { body = String(init.body); }
              var path = abs.pathname + (abs.search || '');
              if (window.SignHubApi && window.SignHubApi.requestAsync) {
                return new Promise(function(resolve){
                  var id = 'r' + (++window.__signhubSeq);
                  var settled = false;
                  function done(text){ if (settled) return; settled = true; resolve(window.__signhubResp(text)); }
                  window.__signhubPending[id] = done;
                  setTimeout(function(){
                    if (settled) return;
                    delete window.__signhubPending[id];
                    done(JSON.stringify({error:'timeout: 本地接口 75 秒未返回'}));
                  }, 75000);
                  try { window.SignHubApi.requestAsync(id, method, path, body); }
                  catch(e) { delete window.__signhubPending[id]; done(JSON.stringify({error:String(e)})); }
                });
              }
              return Promise.resolve(window.__signhubResp('{"error":"no bridge"}'));
            }
            if (origFetch) { return origFetch(input, init); }
            return Promise.reject(new Error('no native fetch'));
          };
        })();
        """
    }

    static func patchJS() -> String {
        """
        (function(){
          function patch(){
            try {
              Array.prototype.forEach.call(document.querySelectorAll('.panel'), function(p){
                var h = p.querySelector('h2');
                var t = h ? (h.textContent || '').trim() : '';
                if (t === '连接电脑端' || t === '访问口令') { p.style.display = 'none'; }
              });
            } catch(e) {}
          }
          if (document.readyState === 'loading') { document.addEventListener('DOMContentLoaded', patch); }
          else { patch(); }
        })();
        """
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKScriptMessageHandler, WKURLSchemeHandler, WKNavigationDelegate {
        weak var webView: WKWebView?

        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "signhub", let dict = message.body as? [String: Any] else { return }

            if let id = dict["id"] as? String {
                let method = (dict["method"] as? String) ?? "GET"
                let path = (dict["path"] as? String) ?? ""
                let body = (dict["body"] as? String) ?? ""
                Task {
                    let result = await LocalApi.handle(method: method, path: path, body: body)
                    let arg = Self.quoteJS(result)
                    let js = "window.__signhubPending && window.__signhubPending['\(id)'] ? window.__signhubPending['\(id)'](\(arg)) : null;"
                    await MainActor.run {
                        self.webView?.evaluateJavaScript(js, completionHandler: nil)
                    }
                }
            } else if let cmd = dict["cmd"] as? String {
                if cmd == "resetCreds" {
                    LocalApi.resetCreds(["key": (dict["key"] as? String) ?? ""])
                }
                // openLogin / openAccounts / openMultiAccounts / runAutoNow 等在 iOS 端暂为 no-op
            }
        }

        static func quoteJS(_ s: String) -> String {
            if let d = try? JSONSerialization.data(withJSONObject: s),
               let str = String(data: d, encoding: .utf8) {
                return str
            }
            return "\"\""
        }

        // MARK: 静态资源

        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            guard let url = urlSchemeTask.request.url else {
                urlSchemeTask.didFailWithError(URLError(.badURL))
                return
            }
            var rel = url.path
            if rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
            if rel.isEmpty { rel = "index.html" }

            let webRoot = Bundle.main.resourceURL?.appendingPathComponent("web")
            let fileURL = webRoot?.appendingPathComponent(rel)

            guard let fileURL = fileURL, FileManager.default.fileExists(atPath: fileURL.path),
                  let data = try? Data(contentsOf: fileURL) else {
                let resp = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain"])
                urlSchemeTask.didReceive(resp ?? HTTPURLResponse())
                urlSchemeTask.didReceive(Data("not found".utf8))
                urlSchemeTask.didFinish()
                return
            }

            let mime = Self.mime(fileURL.pathExtension)
            let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": mime,
                "Content-Length": "\(data.count)",
                "Cache-Control": "no-store",
            ])
            urlSchemeTask.didReceive(resp ?? HTTPURLResponse())
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        }

        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

        static func mime(_ ext: String) -> String {
            switch ext.lowercased() {
            case "html": return "text/html; charset=utf-8"
            case "js": return "application/javascript; charset=utf-8"
            case "css": return "text/css; charset=utf-8"
            case "png": return "image/png"
            case "json", "webmanifest": return "application/json"
            case "svg": return "image/svg+xml"
            default: return "application/octet-stream"
            }
        }
    }
}