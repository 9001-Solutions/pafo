"""Local stand-in for the PSXI pafo endpoints.

Usage: python tools/mock_server.py [port]

Point the addon at it by setting DEFAULT_BASE_URL in ashita/store.lua to
http://127.0.0.1:<port> (locally only), then /addon reload pafo.

Control endpoints (GET):
  /mock/approve            approve the pending device code
  /mock/deny               deny it (next poll answers 403)
  /mock/expire             expire it (polls keep answering authorization_pending)
  /mock/ingest?mode=ok     ingest responses: ok | 500 | 429 | 401 | 403 | 400 | reject | protocol | timeout
  /mock/disable            mark the horizon server disabled in config
  /mock/enable             re-enable it
  /mock/state              dump the mock state
"""
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

STATE = {
    "device": None,
    "ingest_mode": "ok",
    "enabled": True,
    "seen_ids": set(),
    "batches": [],
}

TOKEN = "pafo_mock_token"


def config_body(base):
    return {
        "protocol": 1,
        "ingest_url": base,
        "batch": {"flush_seconds": 10, "max_events": 5},
        "servers": [
            {
                "slug": "horizonxi",
                "name": "HorizonXI",
                "enabled": STATE["enabled"],
                "max_th": 4,
                "th_plus_item_ids": [14914, 15107, 23040],
                "hosts": ["play.horizonxi.com"],
            },
            {
                "slug": "phoenixxi",
                "name": "PhoenixXI",
                "enabled": False,
                "max_th": 4,
                "th_plus_item_ids": [],
                "hosts": ["play.phoenix-xi.com"],
            },
        ],
    }


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (time.strftime("%H:%M:%S"), fmt % args))

    def _send(self, status, body, headers=None):
        payload = json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(payload)

    def _read_json(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            return json.loads(raw.decode("utf-8")) if raw else None
        except ValueError:
            return None

    def _base(self):
        host = self.headers.get("Host") or "127.0.0.1"
        return "http://%s" % host

    def do_GET(self):
        url = urlparse(self.path)
        q = parse_qs(url.query)
        if url.path == "/api/pafo/config":
            return self._send(200, config_body(self._base()))
        if url.path == "/mock/approve":
            if STATE["device"]:
                STATE["device"]["status"] = "ok"
            return self._send(200, {"ok": True})
        if url.path in ("/mock/deny", "/mock/expire"):
            if STATE["device"]:
                STATE["device"]["status"] = {"/mock/deny": "denied", "/mock/expire": "expired"}[url.path]
            return self._send(200, {"ok": True})
        if url.path == "/mock/ingest":
            STATE["ingest_mode"] = (q.get("mode") or ["ok"])[0]
            return self._send(200, {"mode": STATE["ingest_mode"]})
        if url.path == "/mock/disable":
            STATE["enabled"] = False
            return self._send(200, {"enabled": False})
        if url.path == "/mock/enable":
            STATE["enabled"] = True
            return self._send(200, {"enabled": True})
        if url.path == "/mock/state":
            return self._send(200, {
                "device": STATE["device"],
                "ingest_mode": STATE["ingest_mode"],
                "enabled": STATE["enabled"],
                "seen": len(STATE["seen_ids"]),
                "batches": STATE["batches"][-5:],
            })
        return self._send(404, {"error": "not_found"})

    def do_POST(self):
        url = urlparse(self.path)
        body = self._read_json()
        if url.path == "/auth/device":
            if not isinstance(body, dict) or body.get("kind") != "pafo":
                return self._send(400, {"error": "bad_kind"})
            STATE["device"] = {"user_code": "ABCD-EFGH", "device_code": "dev-%d" % int(time.time()), "status": "pending"}
            return self._send(200, {
                "device_code": STATE["device"]["device_code"],
                "user_code": STATE["device"]["user_code"],
                "verify_url": self._base() + "/link",
                "interval": 2,
                "expires_in": 300,
            })
        if url.path == "/auth/token":
            d = STATE["device"]
            if not d or not body or body.get("device_code") != d["device_code"]:
                return self._send(200, {"error": "authorization_pending"})
            if d["status"] == "ok":
                d["status"] = "consumed"
                return self._send(200, {"token": TOKEN})
            if d["status"] == "denied":
                return self._send(403, {"error": "access_denied"})
            return self._send(200, {"error": "authorization_pending"})
        if url.path == "/ingest":
            return self._ingest(body)
        return self._send(404, {"error": "not_found"})

    def _ingest(self, body):
        mode = STATE["ingest_mode"]
        auth = self.headers.get("Authorization") or ""
        if mode == "timeout":
            time.sleep(30)
        if mode == "401" or auth != "Bearer " + TOKEN:
            return self._send(401, {"error": "invalid_token"})
        if mode == "500":
            return self._send(500, {"error": "boom"})
        if mode == "429":
            return self._send(429, {"error": "rate_limited"}, {"Retry-After": "45"})
        if mode == "403":
            return self._send(403, {"error": "server_disabled"})
        if mode == "400":
            return self._send(400, {"error": "bad_json"})
        if mode == "protocol":
            return self._send(400, {"error": "unsupported_protocol"})
        if not isinstance(body, dict) or body.get("protocol") != 1:
            return self._send(400, {"error": "unsupported_protocol"})
        events = body.get("events") or []
        STATE["batches"].append(body)
        print(json.dumps(body, indent=2))
        accepted = 0
        duplicates = 0
        rejected = []
        for i, ev in enumerate(events):
            if mode == "reject" and i == 0:
                rejected.append({"index": i, "reason": "mock rejection"})
                continue
            eid = ev.get("id")
            if eid in STATE["seen_ids"]:
                duplicates += 1
            else:
                STATE["seen_ids"].add(eid)
                accepted += 1
        return self._send(200, {"accepted": accepted, "duplicates": duplicates, "rejected": rejected})


class Server(HTTPServer):
    daemon_threads = True


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8787
    server = Server(("127.0.0.1", port), Handler)
    print("pafo mock listening on http://127.0.0.1:%d" % port)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
