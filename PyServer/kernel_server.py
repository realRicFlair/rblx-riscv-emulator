#!/usr/bin/env python3
"""
kernel_server.py  --  HTTP server that serves Image.bin to Roblox.

Place Image.bin in the same directory as this script, then run:
    python kernel_server.py

Endpoints:
    GET /size                        -> file size in bytes (plain text)
    GET /chunk?offset=N&size=N       -> raw binary chunk
    GET /Image.bin                   -> full file (for testing)
"""

import os
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

KERNEL_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "Image.bin")
HOST = "0.0.0.0"
PORT = 8080


class KernelHandler(BaseHTTPRequestHandler):

    def do_GET(self):
        parsed = urlparse(self.path)
        path   = parsed.path
        query  = parse_qs(parsed.query)

        if path == "/size":
            self._serve_size()
        elif path == "/chunk":
            offset = int(query.get("offset", ["0"])[0])
            size   = int(query.get("size",   ["262144"])[0])
            self._serve_chunk(offset, size)
        elif path in ("/Image.bin", "/kernel"):
            self._serve_full()
        else:
            self.send_error(404, "Not found")

    # ------------------------------------------------------------------ helpers

    def _serve_size(self):
        if not os.path.exists(KERNEL_FILE):
            self.send_error(404, f"{KERNEL_FILE} not found")
            return
        size = os.path.getsize(KERNEL_FILE)
        body = str(size).encode()
        self.send_response(200)
        self._cors()
        self.send_header("Content-Type",   "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _serve_chunk(self, offset, size):
        if not os.path.exists(KERNEL_FILE):
            self.send_error(404, f"{KERNEL_FILE} not found")
            return
        file_size = os.path.getsize(KERNEL_FILE)
        offset = max(0, min(offset, file_size))
        size   = max(0, min(size,   file_size - offset))
        with open(KERNEL_FILE, "rb") as f:
            f.seek(offset)
            data = f.read(size)
        self.send_response(200)
        self._cors()
        self.send_header("Content-Type",   "application/octet-stream")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _serve_full(self):
        if not os.path.exists(KERNEL_FILE):
            self.send_error(404, f"{KERNEL_FILE} not found")
            return
        file_size = os.path.getsize(KERNEL_FILE)
        self.send_response(200)
        self._cors()
        self.send_header("Content-Type",    "application/octet-stream")
        self.send_header("Content-Length",  str(file_size))
        self.send_header("Accept-Ranges",   "bytes")
        self.end_headers()
        with open(KERNEL_FILE, "rb") as f:
            while True:
                chunk = f.read(65536)
                if not chunk:
                    break
                self.wfile.write(chunk)

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")

    def log_message(self, fmt, *args):
        print(f"  [{self.address_string()}] {fmt % args}")


# ------------------------------------------------------------------ entry point

if __name__ == "__main__":
    if not os.path.exists(KERNEL_FILE):
        print(f"[WARN] Image.bin not found at: {KERNEL_FILE}")
        print("       Place Image.bin next to this script before starting Roblox.")
    else:
        mb = os.path.getsize(KERNEL_FILE) / (1024 * 1024)
        print(f"[OK]   Serving Image.bin  ({mb:.1f} MB)")

    print(f"[OK]   Listening on  http://localhost:{PORT}")
    print(f"       Size endpoint: http://localhost:{PORT}/size")
    print(f"       Chunk example: http://localhost:{PORT}/chunk?offset=0&size=262144")
    print()

    server = HTTPServer((HOST, PORT), KernelHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[STOP] Server shut down.")
