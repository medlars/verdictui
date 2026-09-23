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
        if self.path in ("/same", "/cross"):
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
