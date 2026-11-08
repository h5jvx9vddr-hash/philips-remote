#!/usr/bin/env python3
"""Simulierte MagentaTV-Box (Android-TV-Fernbedienungsprotokoll v2) mit echtem TLS.

atv_mock.py <pairPort> <remotePort> <dir>
- Server-Zertifikat: <dir>/server.pem + server.key (openssl im Workflow)
- Client-Zertifikat wird nur akzeptiert, wenn es <dir>/client.pem ist (schreibt der Test vorher)
- Kopplung: Code landet in <dir>/code.txt; Steuerung nur mit gekoppeltem Zertifikat; Tasten/Ping-Antworten → <dir>/keys.txt
"""
import hashlib, os, socket, ssl, sys, threading
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cryptography import x509
from google.protobuf.internal.decoder import _DecodeVarint32
from google.protobuf.internal.encoder import _VarintBytes
import polo_pb2, remotemessage_pb2 as rm

PAIR, REMOTE, DIR = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
state = {"paired": None}

def ctx():
    c = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    c.load_cert_chain(f"{DIR}/server.pem", f"{DIR}/server.key")
    c.verify_mode = ssl.CERT_REQUIRED
    c.load_verify_locations(f"{DIR}/client.pem")
    return c

def nums(der):
    n = x509.load_der_x509_certificate(der).public_key().public_numbers(); return n.n, n.e

def read_msgs(conn):
    buf = b""
    while True:
        data = conn.recv(4096)
        if not data: return
        buf += data
        while buf:
            try: length, pos = _DecodeVarint32(buf, 0)
            except IndexError: break
            if len(buf) < pos + length: break
            yield buf[pos:pos + length]; buf = buf[pos + length:]

def send(conn, m):
    b = m.SerializeToString(); conn.sendall(_VarintBytes(len(b)) + b)

def outer(status=200):
    m = polo_pb2.OuterMessage(); m.protocol_version = 2; m.status = status; return m

def log(line):
    with open(f"{DIR}/keys.txt", "a") as f: f.write(line + "\n")

def pairing(conn):
    client = conn.getpeercert(binary_form=True)
    (cn, ce), (sn, se) = nums(client), nums(open(f"{DIR}/server.der", "rb").read())
    tail = os.urandom(2)
    h = hashlib.sha256()
    for part in (f"{cn:X}", f"0{ce:X}", f"{sn:X}", f"0{se:X}"): h.update(bytes.fromhex(part))
    h.update(tail); expected = h.digest()
    for raw in read_msgs(conn):
        m = polo_pb2.OuterMessage(); m.ParseFromString(raw)
        r = outer()
        if m.HasField("pairing_request"):
            assert m.pairing_request.service_name == "atvremote"; r.pairing_request_ack.server_name = "MagentaTV One"
        elif m.HasField("options"):
            e = r.options.input_encodings.add(); e.type = 3; e.symbol_length = 6; r.options.preferred_role = 1
        elif m.HasField("configuration"):
            assert m.configuration.encoding.type == 3 and m.configuration.client_role == 1
            r.configuration_ack.SetInParent()
            open(f"{DIR}/code.txt", "w").write(f"{expected[0]:02X}{tail.hex().upper()}")
        elif m.HasField("secret"):
            if m.secret.secret != expected: send(conn, outer(402)); return
            state["paired"] = client; r.secret_ack.secret = expected
        send(conn, r)

def remote(conn):
    if conn.getpeercert(binary_form=True) != state["paired"]: return  # unbekannt → trennen
    m = rm.RemoteMessage(); m.remote_configure.code1 = 622
    m.remote_configure.device_info.model = "MagentaTV One"; m.remote_configure.device_info.vendor = "Telekom"
    send(conn, m)
    for raw in read_msgs(conn):
        m = rm.RemoteMessage(); m.ParseFromString(raw)
        if m.HasField("remote_configure"):
            assert m.remote_configure.device_info.package_name == "atvremote"
            r = rm.RemoteMessage(); r.remote_set_active.SetInParent(); send(conn, r)
        elif m.HasField("remote_set_active"):
            assert m.remote_set_active.active == 622 & 611
            r = rm.RemoteMessage(); r.remote_start.started = True; send(conn, r)
            r = rm.RemoteMessage(); r.remote_set_volume_level.volume_level = 12; r.remote_set_volume_level.volume_max = 100; send(conn, r)
            r = rm.RemoteMessage(); r.remote_ping_request.val1 = 7; send(conn, r)
        elif m.HasField("remote_ping_response"):
            log(f"pong:{m.remote_ping_response.val1}")
        elif m.HasField("remote_key_inject"):
            assert m.remote_key_inject.direction == rm.SHORT; log(str(m.remote_key_inject.key_code))
        elif m.HasField("remote_app_link_launch_request"):
            log("link:" + m.remote_app_link_launch_request.app_link)

def serve(port, handler):
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", port)); s.listen()
    while True:
        raw, _ = s.accept()
        def run(raw=raw):
            try:
                with ctx().wrap_socket(raw, server_side=True) as conn: handler(conn)
            except Exception as e:
                print(f"[{port}] {type(e).__name__}: {e}", flush=True)
            finally:
                raw.close()
        threading.Thread(target=run, daemon=True).start()

threading.Thread(target=serve, args=(PAIR, pairing), daemon=True).start()
serve(REMOTE, remote)
