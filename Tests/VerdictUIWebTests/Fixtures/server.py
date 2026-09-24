"""Loopback-only cross-origin and delayed-response fixture; no outside network."""

import http.server
import pathlib
import socketserver
import sys
import time
import urllib.parse

# Small real-browser payload; the witness preconsumes the cumulative budget.
INLINE_BUDGET_CANDIDATES = 3
# Long enough that the document scrolls far past any viewport.
LONG_TEXT_LINES = 10000
# Enough controls to exhaust the overlap lint's bounded work budget.
OVERLAP_BUDGET_CONTROLS = 1500

fixture_root = pathlib.Path(sys.argv[1])
port_file = pathlib.Path(sys.argv[2])


class Handler(http.server.BaseHTTPRequestHandler):
    server: http.server.HTTPServer

    def do_GET(self):
        if self.path in ("/long-same", "/long-cross"):
            host = "localhost" if self.path == "/long-cross" else "127.0.0.1"
            body = (
                '<html><body style="margin:24px;font:16px sans-serif"><p>Main frame</p>'
                '<iframe id="child" style="margin-top:1000px;border:3px solid;width:500px;height:300px" src="http://'
                + host
                + ":"
                + str(self.server.server_port)
                + '/long"></iframe></body></html>'
            ).encode()
        elif self.path in ("/long", "/nested", "/transformed", "/displaced", "/clipped", "/skip"):
            prefix = "<html><head><style>body{margin:24px;font:16px sans-serif}button{width:160px;height:44px}</style></head><body>"
            button = (
                '<button id="bottom" onclick="this.textContent=\'Completed\'">Run task</button>'
            )
            if self.path == "/long":
                content = '<p>Top content</p><div style="margin-top:1600px">' + button + "</div>"
            elif self.path == "/nested":
                content = (
                    '<p>Nested scroll</p><div id="panel" style="overflow:auto;width:500px;height:200px"><div style="padding-top:1400px">'
                    + button
                    + "</div></div>"
                )
            elif self.path == "/transformed":
                content = (
                    '<p>Top content</p><div style="transform:translateX(0);margin-top:1200px;width:500px;height:200px"><div style="position:fixed;top:20px;left:20px">'
                    + button
                    + "</div></div>"
                )
            elif self.path == "/displaced":
                content = '<p>Visible control</p><button id="negative" style="position:absolute;left:-300px;top:100px">Negative</button><button id="fixed" style="position:fixed;top:1200px">Fixed</button><p style="margin-top:1600px">Bottom content</p>'
            elif self.path == "/clipped":
                content = '<p>Visible control</p><div style="overflow:hidden;width:200px;height:100px"><button id="clipped" style="margin-left:300px">Clipped</button></div>'
            else:
                content = '<style>#skip{position:absolute;left:-1px;top:-1px;width:1px;height:1px;clip-path:inset(50%)}#skip:focus{position:fixed;left:16px;top:16px;width:160px;height:44px;clip-path:none}</style><a id="skip" href="#main">Skip to content</a><p id="main" style="margin-top:120px">Visible content</p>'
            body = (prefix + content + "</body></html>").encode()
        elif self.path in ("/containing-same", "/containing-cross"):
            host = "localhost" if self.path == "/containing-cross" else "127.0.0.1"
            body = (
                '<!doctype html><body style="margin:20px"><p>Main document</p>'
                '<iframe style="width:600px;height:400px;border:0" src="http://'
                + host
                + ":"
                + str(self.server.server_port)
                + '/absolute-hidden-static"></iframe></body>'
            ).encode()
        elif self.path in (
            "/absolute-hidden-static",
            "/absolute-auto-static",
            "/fixed-hidden-static",
            "/fixed-auto-static",
            "/absolute-hidden-relative",
            "/fixed-hidden-transform",
            "/absolute-hidden-translate",
            "/absolute-hidden-rotate",
            "/absolute-hidden-scale",
            "/absolute-hidden-will-translate",
        ):
            controls = {
                "/absolute-hidden-static": ("absolute", "hidden", "static", "position:relative"),
                "/absolute-auto-static": ("absolute", "auto", "static", "position:relative"),
                "/fixed-hidden-static": ("fixed", "hidden", "static", "transform:translateX(0)"),
                "/fixed-auto-static": ("fixed", "auto", "static", "transform:translateX(0)"),
                "/absolute-hidden-relative": (
                    "absolute",
                    "hidden",
                    "relative",
                    "position:relative",
                ),
                "/fixed-hidden-transform": (
                    "fixed",
                    "hidden",
                    "static;transform:translateX(0)",
                    "transform:translateX(0)",
                ),
                "/absolute-hidden-translate": (
                    "absolute",
                    "hidden",
                    "static;translate:0px",
                    "position:relative",
                ),
                "/absolute-hidden-rotate": (
                    "absolute",
                    "hidden",
                    "static;rotate:0deg",
                    "position:relative",
                ),
                "/absolute-hidden-scale": (
                    "absolute",
                    "hidden",
                    "static;scale:1",
                    "position:relative",
                ),
                "/absolute-hidden-will-translate": (
                    "absolute",
                    "hidden",
                    "static;will-change:translate",
                    "position:relative",
                ),
            }
            position, overflow, inner, outer = controls[self.path]
            body = (
                "<!doctype html><style>body{margin:20px;font:20px Arial}h1{font:700 20px Arial;margin:0 0 30px}"
                f"#outer{{{outer};width:400px;height:150px;border:1px solid #aaa}}"
                f"#intermediary{{position:{inner};width:100px;height:100px;overflow:{overflow};background:#ddd}}"
                "button{width:120px;height:40px;font:16px Arial}"
                f"#escaping{{position:{position};left:150px;top:20px;background:#b9a3f5}}"
                "#outside{position:absolute;left:160px;top:40px;background:#c1ffa8}</style>"
                '<h1>Containing block control</h1><div id="outer"><div id="intermediary">'
                '<button id="escaping">Escaping</button></div><button id="outside">Outside</button></div>'
            ).encode()
        elif self.path == "/late-frame":
            body = (
                '<!doctype html><button id="late-action" style="width:180px;height:44px" onclick="this.textContent=&quot;Frame task complete&quot;">Main frame task</button>'
                "<script>let frameCount=0;window.appendMeasuredFrame=()=>new Promise(resolve=>{"
                'const f=document.createElement("iframe");f.id="late-frame-"+(++frameCount);f.style.display="none";'
                'f.onload=()=>resolve(f.id);f.src="http://localhost:'
                + str(self.server.server_port)
                + '/late-frame-content";document.body.append(f)});</script>'
            ).encode()
        elif self.path == "/late-frame-content":
            body = b"<!doctype html><p>Remote frame evidence</p>"
        elif self.path == "/editable-inline":
            body = (
                "<!doctype html><style>body{margin:24px;font:16px Arial}.editor{width:320px;min-height:60px;margin:24px 0}"
                "button{display:block;width:180px;height:44px}</style><h1>Editable control</h1>"
                '<div class="editor" contenteditable="true" aria-label="Message"><span><em>private-editable-inline-sentinel</em></span></div>'
                '<div class="editor" role="textbox" aria-label="Draft"><em>private-role-textbox-sentinel</em></div>'
                '<button id="editable-action" onclick="this.textContent=&quot;Message saved&quot;">Save message</button>'
            ).encode()
        elif self.path == "/font-flow":
            body = (
                '<!doctype html><html><body style="margin:24px"><h1 style="font:700 96px/96px Arial;width:1000px;transform:translateY(0)">'
                'Software that<br><span id="font-normal">thinks ahead</span></h1>'
                '<h2 style="font:700 48px/48px Arial">First line<br><span id="font-gradient" style="background:linear-gradient(red,blue);background-clip:text;color:transparent">Gradient glyphs</span></h2>'
                '<p style="font:32px/32px Arial"><span id="font-border" style="border:2px solid;padding:2px">Border paint</span></p>'
                '<p style="font:32px/32px Arial"><span id="font-offset" style="position:relative;left:-10px">Offset text</span></p>'
                '<p style="font:32px/32px Arial"><span id="font-margin" style="margin-left:-10px">Negative margin</span></p>'
                "</body></html>"
            ).encode()
        elif self.path in ("/inline-same", "/inline-cross"):
            host = "localhost" if self.path == "/inline-cross" else "127.0.0.1"
            body = (
                '<!doctype html><html><body style="margin:24px;font:16px sans-serif"><p>Main document</p>'
                '<iframe style="margin-top:1000px;transform:scale(.8);transform-origin:top left;border:3px solid;width:500px;height:500px" src="http://'
                + host
                + ":"
                + str(self.server.server_port)
                + '/inline"></iframe></body></html>'
            ).encode()
        elif self.path in ("/inline", "/inline-overlap", "/inline-budget"):
            if self.path == "/inline-budget":
                content = "".join(
                    f"<div><span>Item {i}</span></div>" for i in range(INLINE_BUDGET_CANDIDATES)
                )
            else:
                content = (
                    '<p style="width:300px"><span id="label">Project templates:</span><span id="wrapped"> from beginner to advanced examples with source code and detailed instructions.</span></p>'
                    '<p style="width:300px"><span>Label </span><span id="bordered" style="padding:3px 7px;border:2px solid black">Bordered wrapped inline content keeps actual padding and border measurements.</span></p>'
                    '<p style="width:300px;transform:translate(25px,10px) scale(.9);transform-origin:top left"><span id="replaced" style="padding:3px 7px;border:2px solid black">Text before <img alt="fixture mark" style="width:30px;height:20px" src="data:image/svg+xml,%3Csvg xmlns=%22http://www.w3.org/2000/svg%22 width=%2230%22 height=%2220%22%3E%3Crect width=%2230%22 height=%2220%22 fill=%22blue%22/%3E%3C/svg%3E"> and text after the replaced content wraps naturally.</span></p>'
                    '<p><span id="empty" style="padding:3px 7px;border:2px solid black"></span></p>'
                    '<button id="inline-action" style="width:160px;height:44px;margin-top:700px" onclick="this.textContent=&quot;Inline complete&quot;">Run inline task</button>'
                    "<script>Element.prototype.getClientRects=function(){return []};</script>"
                )
                if self.path == "/inline-overlap":
                    content += '<p style="width:300px"><span id="before-collision">Measured label</span><span id="border-collision" style="margin-left:-20px;padding:4px 20px;border:2px solid black">Actual border collision with wrapped content.</span></p>'
            body = (
                '<!doctype html><html><body style="margin:24px;font:16px/44px sans-serif">'
                + content
                + "</body></html>"
            ).encode()
        elif self.path == "/long-text":
            body = (
                '<!doctype html><html><body><pre style="font:16px/20px monospace">'
                + "\n".join(f"Measured line {i}" for i in range(LONG_TEXT_LINES))
                + "</pre></body></html>"
            ).encode()
        elif self.path == "/overlap-budget":
            body = (
                "<!doctype html><html><body><main>"
                + "".join(
                    f'<button style="display:block;width:160px;height:44px;margin:4px">Control {i}</button>'
                    for i in range(OVERLAP_BUDGET_CONTROLS)
                )
                + "</main></body></html>"
            ).encode()
        elif self.path in ("/typography", "/typography-overlap"):
            if self.path == "/typography":
                content = '<h2 style="font-size:32px;line-height:36px">Typography complete</h2><p>First line<br>Second line</p><p style="width:300px;line-height:24px">Install through <code>Homebrew</code>, then run the command from any project folder to check the interface.</p>'
            else:
                content = '<p><span id="first" style="display:inline-block;width:160px">First text</span><span id="collision" style="display:inline-block;transform:translateX(-100px)">Colliding text</span></p>'
            body = (
                '<!doctype html><html><body style="margin:24px;font:16px sans-serif">'
                + content
                + "</body></html>"
            ).encode()
        elif self.path in ("/same", "/cross"):
            host = "localhost" if self.path == "/cross" else "127.0.0.1"
            body = (
                "<html><head><style>body{margin:24px;font:16px sans-serif}"
                "iframe{margin-top:50px;border:3px solid black;width:500px;height:350px}"
                '</style></head><body><p>Main frame</p><iframe id="child" src="http://'
                + host
                + ":"
                + str(self.server.server_port)
                + '/clean.html"></iframe></body></html>'
            ).encode()
        elif self.path in ("/hidden-same", "/hidden-cross"):
            host = "localhost" if self.path == "/hidden-cross" else "127.0.0.1"
            body = (
                "<html><head><style>body{margin:24px;font:16px sans-serif}"
                "button{width:160px;height:44px}iframe{border:3px solid black;"
                "width:500px;height:350px}</style></head><body><p>Main frame</p>"
                '<button id="show" onclick="document.getElementById(\'child\')'
                ".style.display='block'\">Show frame</button>"
                '<iframe id="child" style="display:none" src="http://'
                + host
                + ":"
                + str(self.server.server_port)
                + '/clean.html"></iframe></body></html>'
            ).encode()
        elif self.path == "/network":
            body = (
                '<html><body style="margin:24px"><p id="status">Waiting</p>'
                '<script>fetch("/slow").then(r=>r.text()).then(t=>'
                'document.getElementById("status").textContent=t)</script></body></html>'
            ).encode()
        elif self.path == "/slow":
            time.sleep(0.6)
            body = b"Network task complete"
        elif urllib.parse.urlsplit(self.path).path in ("/clean.html", "/login.html"):
            # login.html reads its credential digest from the query string.
            body = (fixture_root / urllib.parse.urlsplit(self.path).path[1:]).read_bytes()
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


class LoopbackHTTPServer(http.server.ThreadingHTTPServer):
    def server_bind(self):
        # HTTPServer's unused reverse-DNS metadata stalls before listen() on macOS CI.
        # https://github.com/actions/runner-images/issues/14409#issuecomment-5034633535
        socketserver.TCPServer.server_bind(self)
        self.server_name = "localhost"
        self.server_port = self.server_address[1]


server = LoopbackHTTPServer(("127.0.0.1", 0), Handler)
port_file.write_text(str(server.server_port))
server.serve_forever()
