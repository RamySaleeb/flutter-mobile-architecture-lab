"""Loopback-only, fictional HTTP fixtures; no dependencies or credentials.
Run from the repository root. /smoke.html runs the compiled Dart browser probe.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs
import json
import time

ROOT = Path(__file__).resolve().parents[1]

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        if path == '/smoke.html':
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.end_headers()
            self.wfile.write(b'<title>Pocket Catalog HTTP smoke</title><h1>HTTP adapter smoke test</h1><p>Results appear below and in the browser console.</p><pre id="results"></pre><script>const original=console.log;console.log=(...args)=>{original(...args);document.getElementById("results").textContent+=args.join(" ")+"\\n";};</script><script src="http_smoke.js"></script>')
            return
        if path in ('/http_smoke.js', '/http_smoke.js.map'):
            file = ROOT / 'build' / path.lstrip('/')
            if not file.exists():
                self.send_error(404, 'Compile the smoke probe first')
                return
            self.send_response(200)
            self.send_header('Content-Type', 'application/javascript')
            self.end_headers()
            self.wfile.write(file.read_bytes())
            return
        if path == '/slow-headers':
            time.sleep(1)
        status = 503 if path == '/status' else 302 if path == '/redirect' else 200
        self.send_response(status)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        # Public fictional fixture only. Allows a separately served local web example.
        self.send_header('Access-Control-Allow-Origin', '*')
        if path == '/redirect':
            self.send_header('Location', '/catalog')
        self.end_headers()
        try:
            if path == '/slow-body':
                self.wfile.write(b'{"items":[')
                self.wfile.flush()
                time.sleep(1)
                self.wfile.write(b']}')
            elif path == '/malformed':
                self.wfile.write(b'{invalid')
            else:
                data = json.loads((ROOT / 'test/fixtures/catalog/success.json').read_text())
                query = parse_qs(parsed.query, keep_blank_values=True).get('q', [''])[0].strip().lower()
                data['items'] = [item for item in data['items'] if query in (item['title'] + ' ' + item['category']).lower()]
                self.wfile.write(json.dumps(data).encode())
        except (BrokenPipeError, ConnectionResetError):
            pass  # Expected when the real client aborts a delayed response.

if __name__ == '__main__':
    print('Fictional fixtures: http://127.0.0.1:8767/catalog', flush=True)
    ThreadingHTTPServer(('127.0.0.1', 8767), Handler).serve_forever()
