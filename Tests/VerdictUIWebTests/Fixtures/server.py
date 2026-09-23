"""Loopback-only cross-origin and delayed-response fixture; no outside network."""

import http.server
import pathlib
import socketserver
import sys
import time

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
        elif self.path in ("/clean.html", "/login.html"):
            body = (fixture_root / self.path[1:]).read_bytes()
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
