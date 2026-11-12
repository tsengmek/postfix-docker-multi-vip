#!/usr/bin/env bash
set -euo pipefail

HOSTNAME="${1:-${MYHOSTNAME:-mail.company.com}}"
DOMAIN="${2:-${MAIL_DOMAIN:-company.com}}"
CERT_FILE="${3:-/etc/postfix/certs/tls.crt}"
KEY_FILE="${4:-/etc/postfix/certs/tls.key}"
DAYS="${5:-3650}"
BITS="${6:-2048}"

CERT_DIR="$(dirname "${CERT_FILE}")"
KEY_DIR="$(dirname "${KEY_FILE}")"

mkdir -p "${CERT_DIR}" "${KEY_DIR}"

if [ -f "${CERT_FILE}" ] && [ -f "${KEY_FILE}" ]; then
    echo "[TLS] Existing TLS certificate and key found at:"
    echo "      Cert: ${CERT_FILE}"
    echo "      Key:  ${KEY_FILE}"
    exit 0
fi

echo "[TLS] Generating ${BITS}-bit RSA self-signed TLS certificate for ${HOSTNAME} (${DOMAIN})..."

TMP_CONF="$(mktemp /tmp/openssl-san.XXXXXX.cnf)"
cat > "${TMP_CONF}" <<EOF
[req]
default_bits        = ${BITS}
prompt              = no
default_md          = sha256
distinguished_name  = req_distinguished_name
x509_extensions     = v3_req

[req_distinguished_name]
C  = US
ST = State
L  = City
O  = Mail Server
OU = Infrastructure
CN = ${HOSTNAME}

[v3_req]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid,issuer
basicConstraints       = CA:FALSE
keyUsage               = nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage       = serverAuth, clientAuth
subjectAltName         = @alt_names

[alt_names]
DNS.1 = ${HOSTNAME}
DNS.2 = ${DOMAIN}
DNS.3 = *.${DOMAIN}
DNS.4 = localhost
IP.1  = 127.0.0.1
EOF

# Add INBOUND_VIP to SAN if defined
if [ -n "${INBOUND_VIP:-}" ]; then
    echo "IP.2  = ${INBOUND_VIP}" >> "${TMP_CONF}"
fi

openssl req -new -x509 -nodes \
    -newkey "rsa:${BITS}" \
    -keyout "${KEY_FILE}" \
    -out "${CERT_FILE}" \
    -days "${DAYS}" \
    -config "${TMP_CONF}" \
    -extensions v3_req 2>/dev/null

rm -f "${TMP_CONF}"

# Secure permissions - readable by Postfix daemon
if id postfix >/dev/null 2>&1; then
    chown root:postfix "${CERT_FILE}" "${KEY_FILE}" 2>/dev/null || true
fi
chmod 0644 "${CERT_FILE}"
chmod 0640 "${KEY_FILE}" 2>/dev/null || chmod 0644 "${KEY_FILE}"

echo "[TLS] Successfully generated self-signed certificate:"
echo "      Cert: ${CERT_FILE}"
echo "      Key:  ${KEY_FILE}"
echo "      Validity: ${DAYS} days"
openssl x509 -in "${CERT_FILE}" -noout -subject -issuer -dates
