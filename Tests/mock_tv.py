#!/usr/bin/env python3
"""Simulierte Philips-TVs für den Protokolltest.

mock_tv.py <port_v6> <port_v1>
  v6: Android-artig (API 6, PIN-Kopplung, Digest-Anmeldung, PIN ist 1234) – hier über HTTP statt HTTPS
  v1: alter JointSPACE-TV (API 1, ohne Anmeldung)
"""
import base64, hashlib, hmac, json, re, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SHARED = base64.b64decode("ZmVay1EQVFOaZhwQ4Kv81ypLAZNczV9sG4KkseXWn1NEk6cXmPKO/MCa9sryslvLCFMnNe4Z4CPXzToowvhHvA==")
PIN, TS, NONCE, REALM = "1234", 1700000000, "5f2a9c0d1e", "XTV"

SYSTEM_V6 = {"name": "55PUS8505/12", "country": "Germany", "api_version": {"Major": 6, "Minor": 4, "Patch": 0},
             "os_type": "MSAF_2020",
             "featuring": {"systemfeatures": {"pairing_type": "digest_auth_pairing", "secured_transport": "false"}},
             "serialnumber_encrypted": "abc=\n"}
SYSTEM_V1 = {"menulanguage": "German", "name": "Philips TV", "country": "Germany",
             "serialnumber": "1234567890", "softwareversion": "abcd", "model": "42PFL7606K/02"}


def md5(s): return hashlib.md5(s.encode()).hexdigest()


def make_handler(version):
    state = {"volume": 12, "muted": False, "power": "On", "keys": [], "users": {}, "pending": {}, "ncs": set()}

    class H(BaseHTTPRequestHandler):
        def log_message(self, *a): pass

        def reply(self, code, obj=None, headers=None):
            b = b"" if obj is None else json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(b)))
            for k, v in (headers or {}).items(): self.send_header(k, v)
            self.end_headers()
            self.wfile.write(b)

        def challenge(self):
            self.reply(401, None, {"WWW-Authenticate": f'Digest realm="{REALM}", qop="auth,auth-int", nonce="{NONCE}", opaque="op4que"'})

        def digest_ok(self, users):
            h = self.headers.get("Authorization", "")
            if not h.startswith("Digest "): return False
            p = dict((m[0], m[1] or m[2]) for m in re.findall(r'(\w+)=(?:"([^"]*)"|([^,\s]*))', h[7:]))
            pw = users.get(p.get("username"))
            if pw is None or p.get("nonce") != NONCE or p.get("realm") != REALM or p.get("uri") != self.path: return False
            if p.get("qop") != "auth" or p.get("opaque") != "op4que": return False
            if (p["username"], p.get("nc"), p.get("cnonce")) in state["ncs"]: return False  # Replay
            ha1, ha2 = md5(f'{p["username"]}:{REALM}:{pw}'), md5(f"{self.command}:{self.path}")
            ok = p.get("response") == md5(f'{ha1}:{NONCE}:{p["nc"]}:{p["cnonce"]}:auth:{ha2}')
            if ok: state["ncs"].add((p["username"], p.get("nc"), p.get("cnonce")))
            return ok

        def body(self):
            n = int(self.headers.get("Content-Length", 0))
            return json.loads(self.rfile.read(n) or b"{}")

        def route(self):
            path = self.path
            if path == "/log": return self.reply(200, state["keys"])
            prefix = f"/{version}/"
            if not path.startswith(prefix): return self.reply(404)
            ep = path[len(prefix):]
            if ep == "system" and self.command == "GET":
                return self.reply(200, SYSTEM_V6 if version == 6 else SYSTEM_V1)

            if version == 6 and ep == "pair/request":
                b = self.body()
                dev = b.get("device", {})
                if b.get("access", {}).get("scope") != ["read", "write", "control"] or not dev.get("id"):
                    return self.reply(200, {"error_id": "INVALID_REQUEST"})
                state["pending"][dev["id"]] = "key-" + dev["id"]
                return self.reply(200, {"error_id": "SUCCESS", "auth_key": "key-" + dev["id"], "timestamp": TS, "timeout": 60})

            if version == 6 and ep == "pair/grant":
                if not self.digest_ok(state["pending"]): return self.challenge()
                b = self.body()
                a, dev = b.get("auth", {}), b.get("device", {})
                sig = base64.b64encode(hmac.new(SHARED, f"{a.get('auth_timestamp')}{a.get('pin')}".encode(), hashlib.sha1).digest()).decode()
                if a.get("auth_appId") != "1" or a.get("auth_timestamp") != TS or a.get("auth_signature") != sig:
                    return self.reply(200, {"error_id": "INVALID_SIGNATURE"})
                if a.get("pin") != PIN: return self.reply(200, {"error_id": "INVALID_PIN"})
                state["users"][dev["id"]] = state["pending"].pop(dev["id"])
                return self.reply(200, {"error_id": "SUCCESS"})

            if version == 6 and not self.digest_ok(state["users"]): return self.challenge()

            if ep == "input/key" and self.command == "POST":
                k = self.body().get("key", "")
                if not re.fullmatch(r"[A-Za-z0-9]+", k): return self.reply(400)
                state["keys"].append(k)
                return self.reply(200)
            if ep == "audio/volume":
                if self.command == "POST":
                    b = self.body()
                    state["volume"] = max(0, min(60, int(b.get("current", state["volume"]))))
                    state["muted"] = bool(b.get("muted", False))
                    return self.reply(200)
                return self.reply(200, {"muted": state["muted"], "current": state["volume"], "min": 0, "max": 60})
            if version == 6 and ep == "powerstate":
                if self.command == "POST":
                    state["power"] = self.body()["powerstate"]
                    return self.reply(200)
                return self.reply(200, {"powerstate": state["power"]})
            if version == 6 and ep == "network/devices":
                return self.reply(200, [{"type": "Ethernet", "mac": "00:00:00:00:00:00", "ip-address": ""},
                                        {"type": "Wifi", "mac": "70:af:24:1c:5e:a2", "ip-address": "127.0.0.1"}])
            self.reply(404)

        do_GET = route
        do_POST = route

    return H


servers = [ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), make_handler(6)),
           ThreadingHTTPServer(("127.0.0.1", int(sys.argv[2])), make_handler(1))]
for s in servers[1:]: threading.Thread(target=s.serve_forever, daemon=True).start()
servers[0].serve_forever()
