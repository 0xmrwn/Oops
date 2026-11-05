#!/usr/bin/env python3
"""Create oops's local development identity, once, in the login Keychain.

Requires explicit owner authorization. Does not change certificate trust settings.
Only the public certificate fingerprint persists outside Keychain.
"""

import hashlib
import os
import secrets
import shutil
import subprocess
import tempfile
from pathlib import Path


def run(*args, input=None):
    return subprocess.run(args, input=input, check=True, capture_output=True).stdout


def main():
    os.umask(0o077)
    destination = Path.home() / "Library/Application Support/oops/Development/signing-identity.txt"
    if destination.exists():
        raise SystemExit("Signing identity is already configured; refusing to create a duplicate.")
    openssl = shutil.which("openssl")
    if not openssl:
        raise SystemExit("OpenSSL is required.")
    keychain = Path.home() / "Library/Keychains/login.keychain-db"
    with tempfile.TemporaryDirectory(prefix="oops-signing-", dir="/private/tmp") as folder:
        temporary = Path(folder)
        key, cert, archive = (temporary / name for name in ("key.pem", "cert.pem", "identity.p12"))
        run(
            openssl,
            "req",
            "-x509",
            "-newkey",
            "rsa:3072",
            "-noenc",
            "-sha256",
            "-days",
            "3650",
            "-subj",
            "/CN=oops Local Development/O=oops Local",
            "-addext",
            "basicConstraints=critical,CA:FALSE",
            "-addext",
            "keyUsage=critical,digitalSignature",
            "-addext",
            "extendedKeyUsage=critical,codeSigning",
            "-keyout",
            str(key),
            "-out",
            str(cert),
        )
        der = run(openssl, "x509", "-in", str(cert), "-outform", "DER")
        fingerprint = hashlib.sha1(der).hexdigest().upper()
        password = secrets.token_urlsafe(40)
        run(
            openssl,
            "pkcs12",
            "-export",
            "-inkey",
            str(key),
            "-in",
            str(cert),
            "-name",
            "oops Local Development",
            "-macalg",
            "sha256",
            "-out",
            str(archive),
            "-passout",
            "stdin",
            input=(password + "\n").encode(),
        )
        # The random transfer password is never emitted or saved. Restrict key
        # access to codesign; do not use -A or broaden global partition ACLs.
        run(
            "/usr/bin/security",
            "import",
            str(archive),
            "-k",
            str(keychain),
            "-f",
            "pkcs12",
            "-P",
            password,
            "-T",
            "/usr/bin/codesign",
        )
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(fingerprint + "\n")
        print("Imported oops Local Development into the login Keychain.")
        print("Configured public certificate fingerprint:", fingerprint)
        print("Temporary private-key files removed on exit; trust settings unchanged.")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        # Do not render argv: the Keychain import includes a throwaway password.
        raise SystemExit(
            f"Signing setup failed (exit {error.returncode}): " + error.stderr.decode(errors="replace")
        ) from None
