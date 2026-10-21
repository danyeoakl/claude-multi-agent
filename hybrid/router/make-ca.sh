#!/bin/bash
# The hybrid router's CA and leaf: a CA that can vouch only for api.anthropic.com (critical X.509 name
# constraint) and a leaf for api.anthropic.com signed by it. Idempotent: it creates what is missing, renews the
# leaf (and the CA) within 30 days of expiry, and otherwise changes nothing. Keys are 0600 in a 0700 folder.
# The running router picks up a renewed leaf by itself; a renewed CA needs Claude Code sessions restarted.
# Usage: make-ca.sh [dir]   (default ~/.config/tj-hybrid/router)
set -eu
D=${1:-$HOME/.config/tj-hybrid/router}
umask 077
mkdir -p "$D"; chmod 700 "$D"; cd "$D"
fresh() { [ -s "$1" ] && openssl x509 -in "$1" -noout -checkend 2592000 >/dev/null 2>&1; }

if ! fresh ca-cert.pem || [ ! -s ca-key.pem ]; then
  cat > ca.cnf <<'EOF'
[req]
distinguished_name = dn
prompt = no
x509_extensions = v3_ca
[dn]
CN = Hybrid router CA (api.anthropic.com only)
[v3_ca]
basicConstraints = critical, CA:true, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
nameConstraints = critical, permitted;DNS:api.anthropic.com
subjectKeyIdentifier = hash
EOF
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout ca-key.pem.new -out ca-cert.pem.new \
    -days 825 -config ca.cnf 2>/dev/null
  mv ca-key.pem.new ca-key.pem; mv ca-cert.pem.new ca-cert.pem
  rm -f leaf-cert.pem ca-cert.srl
  echo "CA written to $D"
fi

if ! fresh leaf-cert.pem || [ ! -s leaf-key.pem ] || ! openssl verify -CAfile ca-cert.pem leaf-cert.pem >/dev/null 2>&1; then
  cat > leaf.cnf <<'EOF'
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:api.anthropic.com
authorityKeyIdentifier = keyid
subjectKeyIdentifier = hash
EOF
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout leaf-key.pem.new -subj "/CN=api.anthropic.com" \
    -out leaf.csr 2>/dev/null
  openssl x509 -req -in leaf.csr -CA ca-cert.pem -CAkey ca-key.pem -CAcreateserial -days 397 -extfile leaf.cnf -extensions ext \
    -out leaf-cert.pem.new 2>/dev/null
  mv leaf-key.pem.new leaf-key.pem; mv leaf-cert.pem.new leaf-cert.pem; rm -f leaf.csr
  echo "leaf written to $D"
fi

chmod 644 ca-cert.pem; chmod 600 ca-key.pem leaf-key.pem leaf-cert.pem
openssl x509 -in ca-cert.pem -noout -subject -enddate -ext nameConstraints
