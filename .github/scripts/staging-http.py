import http.server
import sys
from functools import partial

class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith(('/apt/pool/', '/rpm/pool/')):
            _, fmt, pool, repo, tag, asset = self.path.split('/')
            self.send_response(307)
            self.send_header('Location', f'https://github.com/scotttrinh/{repo}/releases/download/{tag}/{asset}')
            self.end_headers()
        else:
            super().do_GET()

http.server.ThreadingHTTPServer(('127.0.0.1', 8765), partial(Handler, directory=sys.argv[1])).serve_forever()
