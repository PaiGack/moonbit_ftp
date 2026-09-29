#!/usr/bin/env bash
# Generate the self-signed CA and server certificate the FTPS smoke test uses.
#
#   scripts/ftps/gen-cert.sh OUT_DIR
#
# Writes, into OUT_DIR:
#
#   ca.pem      the CA certificate, PEM. Handed to the client as
#               `trust=@tls.TrustedRoot::CustomPemFile(...)`, so the test also
#               exercises certificate verification instead of turning it off.
#   server.pem  the server certificate + key in one file, which is what the
#               vsftpd image wants: it points `rsa_cert_file` and
#               `rsa_private_key_file` at the *same* path, i.e. a single PEM
#               that carries both halves.
#
# The leaf carries `subjectAltName = IP:127.0.0.1, DNS:localhost`. SANs are not
# decoration: every modern TLS stack, MoonBit's included, ignores the legacy
# `commonName` when checking identity, so a leaf without a SAN fails
# verification no matter how the client is pointed at it. The name has to
# include `127.0.0.1` specifically, because that is the address the smoke test
# dials and therefore the name the client checks the certificate against.
#
# The files are regenerated on every run and are gitignored: a test that mints
# its own trust anchor cannot rot, and there is no key material to rotate.
set -euo pipefail

OUT_DIR="${1:?usage: gen-cert.sh OUT_DIR}"

mkdir -p "$OUT_DIR"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The CA. `-subj` avoids the interactive prompt; `basicConstraints=critical,CA:TRUE`
# is what makes the leaf below verifiable against it.
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP/ca.key" \
  -out "$TMP/ca.pem" \
  -days 36500 \
  -subj "/CN=PaiGack ftp test CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  2>/dev/null

# The leaf, signed by the CA, with the SANs the client dials.
openssl req -newkey rsa:2048 -nodes \
  -keyout "$TMP/server.key" \
  -out "$TMP/server.csr" \
  -subj "/CN=localhost" \
  2>/dev/null

cat > "$TMP/server.ext" <<'EXT'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=IP:127.0.0.1,DNS:localhost
EXT

openssl x509 -req \
  -in "$TMP/server.csr" \
  -CA "$TMP/ca.pem" \
  -CAkey "$TMP/ca.key" \
  -CAcreateserial \
  -out "$TMP/server.crt" \
  -days 36500 \
  -extfile "$TMP/server.ext" \
  2>/dev/null

cp "$TMP/ca.pem" "$OUT_DIR/ca.pem"
cat "$TMP/server.crt" "$TMP/server.key" > "$OUT_DIR/server.pem"

echo "gen-cert.sh: wrote $OUT_DIR/ca.pem and $OUT_DIR/server.pem"
