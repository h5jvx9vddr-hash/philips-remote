#!/usr/bin/env python3
"""Kreuztest Android-TV-Protokoll gegen die Referenz-Protos (polo.proto/remotemessage.proto aus androidtvremote2).

vectors.py gen <out.json>      – TV-seitige Nachrichten + Kopplungs-Prüfsumme nach Referenz-Algorithmus erzeugen
vectors.py verify <swift.json> – von Swift erzeugte Client-Nachrichten mit den Referenz-Klassen dekodieren und prüfen
(pb2-Module vorher mit grpc_tools.protoc in dieses Verzeichnis erzeugen)
"""
import hashlib, json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives import serialization
import polo_pb2, remotemessage_pb2 as rm

def outer():
    m = polo_pb2.OuterMessage(); m.protocol_version = 2; m.status = polo_pb2.OuterMessage.Status.STATUS_OK; return m

def hexmsg(m): return m.SerializeToString().hex()

def gen(path):
    v = {}
    m = outer(); m.pairing_request_ack.server_name = "MagentaTV One"; v["pairing_request_ack"] = hexmsg(m)
    m = outer(); e = m.options.input_encodings.add(); e.type = 3; e.symbol_length = 6; m.options.preferred_role = 1; v["options"] = hexmsg(m)
    m = outer(); m.configuration_ack.SetInParent(); v["configuration_ack"] = hexmsg(m)
    m = outer(); m.secret_ack.secret = b"\x01\x02"; v["secret_ack"] = hexmsg(m)
    m = polo_pb2.OuterMessage(); m.protocol_version = 2; m.status = polo_pb2.OuterMessage.Status.STATUS_BAD_SECRET; v["bad_secret"] = hexmsg(m)

    r = rm.RemoteMessage(); r.remote_configure.code1 = 622; r.remote_configure.device_info.model = "MagentaTV One"
    r.remote_configure.device_info.vendor = "Telekom"; r.remote_configure.device_info.unknown1 = 1; v["remote_configure"] = hexmsg(r)
    r = rm.RemoteMessage(); r.remote_set_active.SetInParent(); v["remote_set_active"] = hexmsg(r)
    r = rm.RemoteMessage(); r.remote_ping_request.val1 = 300; r.remote_ping_request.val2 = 1; v["remote_ping"] = hexmsg(r)
    r = rm.RemoteMessage(); r.remote_start.started = True; v["remote_start"] = hexmsg(r)
    r = rm.RemoteMessage(); r.remote_set_volume_level.volume_level = 12; r.remote_set_volume_level.volume_max = 100
    r.remote_set_volume_level.volume_muted = True; r.remote_set_volume_level.player_model = "tv"; v["remote_volume"] = hexmsg(r)

    # Prüfsumme exakt wie androidtvremote2.pairing.async_finish_pairing
    keys = [rsa.generate_private_key(public_exponent=65537, key_size=2048) for _ in range(2)]
    (cn, ce), (sn, se) = [(k.public_key().public_numbers().n, k.public_key().public_numbers().e) for k in keys]
    tail = "3F9A"
    h = hashlib.sha256()
    h.update(bytes.fromhex(f"{cn:X}")); h.update(bytes.fromhex(f"0{ce:X}"))
    h.update(bytes.fromhex(f"{sn:X}")); h.update(bytes.fromhex(f"0{se:X}"))
    h.update(bytes.fromhex(tail))
    d = h.digest()
    pk = lambda k: k.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.PKCS1).hex()
    v["secret"] = {"client": pk(keys[0]), "server": pk(keys[1]), "code": f"{d[0]:02X}{tail}", "expected": d.hex(),
                   "wrong_code": f"{(d[0] + 1) % 256:02X}{tail}"}
    json.dump(v, open(path, "w"), indent=1)

def verify(path):
    s = json.load(open(path)); fails = 0
    def check(ok, what):
        nonlocal fails
        print(("OK    " if ok else "FEHLER ") + what); fails += 0 if ok else 1
    def outer_of(h): m = polo_pb2.OuterMessage(); m.ParseFromString(bytes.fromhex(h)); return m
    def remote_of(h): m = rm.RemoteMessage(); m.ParseFromString(bytes.fromhex(h)); return m

    m = outer_of(s["pairing_request"])
    check(m.protocol_version == 2 and m.status == 200 and m.pairing_request.service_name == "atvremote"
          and m.pairing_request.client_name == "Philips Remote (CI)", "pairing_request")
    m = outer_of(s["options"])
    check(m.options.preferred_role == 1 and len(m.options.input_encodings) == 1
          and m.options.input_encodings[0].type == 3 and m.options.input_encodings[0].symbol_length == 6, "options")
    m = outer_of(s["configuration"])
    check(m.configuration.client_role == 1 and m.configuration.encoding.type == 3 and m.configuration.encoding.symbol_length == 6, "configuration")
    m = outer_of(s["secret"])
    check(m.secret.secret == bytes.fromhex(s["secret_value"]), "secret")
    r = remote_of(s["configure_reply"])
    check(r.remote_configure.code1 == 622 & 611 and r.remote_configure.device_info.package_name == "atvremote"
          and r.remote_configure.device_info.unknown2 == "1" and r.remote_configure.device_info.app_version == "1.0.0", f"configure reply ({r.remote_configure.code1})")
    r = remote_of(s["set_active_reply"]); check(r.remote_set_active.active == 622 & 611, "set_active reply")
    r = remote_of(s["ping_reply"]); check(r.remote_ping_response.val1 == 300, "ping reply")
    r = remote_of(s["key"]); check(r.remote_key_inject.key_code == rm.KEYCODE_VOLUME_UP and r.remote_key_inject.direction == rm.SHORT, "key inject")
    r = remote_of(s["app_link"]); check(r.remote_app_link_launch_request.app_link == "https://www.netflix.com/title", "app link")
    print("\nAlles grün." if fails == 0 else f"\n{fails} Fehler."); sys.exit(1 if fails else 0)

{"gen": gen, "verify": verify}[sys.argv[1]](sys.argv[2])
