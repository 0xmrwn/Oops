"""Create a temporary certificate chain for this loopback run only."""

import hashlib
import ssl
from pathlib import Path
from tempfile import TemporaryDirectory

OPENSSL = "/usr/bin/openssl"
EXTENSIONS = """\
[req]
distinguished_name = names
[names]
[ca]
basicConstraints = critical,CA:true
keyUsage = critical,keyCertSign,cRLSign
[server]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = IP:127.0.0.1
"""


def fixture_tls(out, run):
    with TemporaryDirectory(prefix=".fixture-tls-", dir=out) as directory:
        scratch = Path(directory)
        config = str(scratch / "extensions.cnf")
        Path(config).write_text(EXTENSIONS, encoding="utf-8")
        ca, ca_key = str(scratch / "ca.pem"), str(scratch / "ca.key")
        leaf, leaf_key, csr = (str(scratch / name) for name in ("server.pem", "server.key", "server.csr"))
        request = [OPENSSL, "req", "-config", config, "-newkey", "rsa:2048", "-nodes", "-batch", "-sha256"]
        commands = [
            [
                *request,
                "-x509",
                "-days",
                "1",
                "-extensions",
                "ca",
                "-subj",
                "/CN=Oops Loopback Fixture CA",
                "-keyout",
                ca_key,
                "-out",
                ca,
            ],
            [*request, "-new", "-subj", "/CN=127.0.0.1", "-keyout", leaf_key, "-out", csr],
            [
                OPENSSL,
                "x509",
                "-req",
                "-sha256",
                "-days",
                "1",
                "-in",
                csr,
                "-CA",
                ca,
                "-CAkey",
                ca_key,
                "-set_serial",
                "1",
                "-extfile",
                config,
                "-extensions",
                "server",
                "-out",
                leaf,
            ],
        ]
        for index, command in enumerate(commands, 1):
            run(command, out / f"tls-{index}.log")
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.set_alpn_protocols(["http/1.1"])
        context.load_cert_chain(leaf, leaf_key)
        anchor = ssl.PEM_cert_to_DER_cert(Path(ca).read_text(encoding="ascii"))
        certificate = ssl.PEM_cert_to_DER_cert(Path(leaf).read_text(encoding="ascii"))
        (out / "probe-anchor.der").write_bytes(anchor)
        provenance = {
            "anchorSha256": hashlib.sha256(anchor).hexdigest(),
            "leafSha256": hashlib.sha256(certificate).hexdigest(),
            "minimumVersion": "TLSv1.2",
            "alpn": ["http/1.1"],
        }
    return context, provenance
