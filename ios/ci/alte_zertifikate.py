#!/usr/bin/env python3
"""Widerruft alte, vom Bau-Ablauf automatisch angelegte Entwickler-Zertifikate.

Jeder signierte Bau legt bei Apple ein neues Entwickler-Zertifikat an ("Created via API").
Apple erlaubt davon nur wenige; ist die Grenze erreicht, scheitert der Bau. Dieses Skript
löscht ausschliesslich Entwickler-Zertifikate mit genau diesem Namen. Vertriebs-Zertifikate
und von Hand angelegte Zertifikate bleiben unberührt.

Aufruf: alte_zertifikate.py <Schlüsseldatei.p8> <Key-ID> <Issuer-ID>
Braucht nur Python-Standardbibliothek und openssl.
"""
import base64, json, subprocess, sys, time, urllib.request, urllib.error

def b64(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()

def token(p8, kid, iss):
    head = b64(json.dumps({"alg": "ES256", "kid": kid, "typ": "JWT"}).encode())
    body = b64(json.dumps({"iss": iss, "iat": int(time.time()), "exp": int(time.time()) + 600, "aud": "appstoreconnect-v1"}).encode())
    msg = (head + "." + body).encode()
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", p8], input=msg, capture_output=True, check=True).stdout
    # DER (SEQUENCE { INTEGER r, INTEGER s }) -> r||s mit je 32 Byte
    i = 2 + (der[1] & 0x7F if der[1] & 0x80 else 0)
    out = b""
    for _ in range(2):
        assert der[i] == 2
        n = der[i + 1]; v = der[i + 2:i + 2 + n]; i += 2 + n
        out += v.lstrip(b"\x00").rjust(32, b"\x00")
    return head + "." + body + "." + b64(out)

def call(tok, method, url):
    req = urllib.request.Request(url, method=method, headers={"Authorization": "Bearer " + tok})
    with urllib.request.urlopen(req, timeout=30) as r:
        data = r.read()
        return json.loads(data) if data else {}

def main():
    p8, kid, iss = sys.argv[1:4]
    tok = token(p8, kid, iss)
    url = "https://api.appstoreconnect.apple.com/v1/certificates?limit=200&fields[certificates]=displayName,certificateType,name"
    certs = call(tok, "GET", url).get("data", [])
    old = [c for c in certs if c["attributes"].get("certificateType") in ("DEVELOPMENT", "IOS_DEVELOPMENT") and c["attributes"].get("displayName") == "Created via API"]
    print("Zertifikate insgesamt: %d, davon automatisch angelegte Entwickler-Zertifikate: %d" % (len(certs), len(old)))
    weg = 0
    for c in old:
        try:
            call(tok, "DELETE", "https://api.appstoreconnect.apple.com/v1/certificates/" + c["id"]); weg += 1
        except urllib.error.HTTPError as e:
            print("Konnte ein Zertifikat nicht widerrufen (HTTP %d)" % e.code)
    print("Widerrufen: %d" % weg)

if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # Der Bau soll daran nicht scheitern
        print("Aufräumen übersprungen: %s" % type(e).__name__)
