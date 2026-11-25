import SwiftUI
import WebKit

struct WebView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(context.coordinator, name: "signhub")
        cfg.userContentController.addUserScript(WKUserScript(source: Self.bridgeJS(), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        cfg.userContentController.addUserScript(WKUserScript(source: Self.patchJS(), injectionTime: .atDocumentEnd, forMainFrameOnly: true))

        let web = WKWebView(frame: .zero, configuration: cfg)
        web.isOpaque = false
        web.backgroundColor = UIColor(red: 0.04, green: 0.043, blue: 0.063, alpha: 1)
        web.scrollView.contentInsetAdjustmentBehavior = .never
        context.coordinator.webView = web

        if let webDir = Bundle.main.resourceURL?.appendingPathComponent("web") {
            web.loadFileURL(webDir.appendingPathComponent("index.html"), allowingReadAccessTo: webDir)
        }
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
              var body = (typeof text === 'string') ? text : JSON.stringify(text);
              return new Response(body, { status: 200, headers: {'Content-Type':'application/json'} });
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

    final class Coordinator: NSObject, WKScriptMessageHandler {
        weak var webView: WKWebView?

        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "signhub", let dict = message.body as? [String: Any] else { return }

            if let id = dict["id"] as? String {
                let method = (dict["method"] as? String) ?? "GET"
                let path = (dict["path"] as? String) ?? ""
                let body = (dict["body"] as? String) ?? ""
                let (p, q) = LocalApi.splitQuery(path)
                if let result = LocalApi.handleSync(p, q, method: method, body: body) {
                    respond(id, result)
                } else {
                    Task {
                        let result = await LocalApi.handleAsync(p, q)
                        await MainActor.run { self.respond(id, result) }
                    }
                }
            } else if let cmd = dict["cmd"] as? String {
                if cmd == "resetCreds" {
                    LocalApi.resetCreds(["key": (dict["key"] as? String) ?? ""])
                }
            }
        }

        func respond(_ id: String, _ result: String) {
            let arg = Self.quoteJS(result)
            let js = "window.__signhubPending && window.__signhubPending['\(id)'] ? window.__signhubPending['\(id)'](\(arg)) : null;"
            webView?.evaluateJavaScript(js, completionHandler: nil)
        }

        static func quoteJS(_ s: String) -> String {
            if let d = try? JSONSerialization.data(withJSONObject: s),
               let str = String(data: d, encoding: .utf8) {
                return str
            }
            return "\"\""
        }
    }
}