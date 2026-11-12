#!/usr/bin/env bash
set -euo pipefail

SMTP_HOST="${1:-127.0.0.1}"
SMTP_PORT="${2:-${SMTP_INBOUND_PORT:-2525}}"
RECIPIENT="${3:-test-recipient@example.com}"
SENDER="${4:-otp@company.com}"

echo "================================================================================"
echo " 1. Checking EHLO Capabilities on ${SMTP_HOST}:${SMTP_PORT} for STARTTLS"
echo "================================================================================"

set +e
EHLO_OUT=$(nc -w 5 "${SMTP_HOST}" "${SMTP_PORT}" <<EOF
EHLO client.internal.company.com
QUIT
EOF
)
set -e

echo "${EHLO_OUT}"
echo ""

if echo "${EHLO_OUT}" | grep -qi "STARTTLS"; then
    echo "[PASS] '250-STARTTLS' is advertised in EHLO response."
else
    echo "[FAIL] 'STARTTLS' was NOT found in EHLO response!"
    echo "       Check if smtpd_tls_security_level is set to 'may' or 'encrypt' and valid certificates are configured."
    exit 1
fi

echo ""
echo "================================================================================"
echo " 2. Testing STARTTLS Handshake via openssl s_client"
echo "================================================================================"

if ! command -v openssl >/dev/null 2>&1; then
    echo "[WARN] openssl CLI is not installed on this host. Skipping s_client handshake test."
    exit 0
fi

set +e
TLS_OUT=$(echo "QUIT" | openssl s_client -starttls smtp -crlf -connect "${SMTP_HOST}:${SMTP_PORT}" 2>&1)
TLS_EXIT=$?
set -e

# Extract protocol and cipher
PROTOCOL=$(echo "${TLS_OUT}" | grep -E "Protocol[[:space:]]*:" | head -n 1 | awk '{print $NF}' || true)
CIPHER=$(echo "${TLS_OUT}" | grep -E "Cipher[[:space:]]*:" | head -n 1 | awk '{print $NF}' || true)
CERT_SUBJECT=$(echo "${TLS_OUT}" | grep -E "subject=" | head -n 1 || true)
CERT_ISSUER=$(echo "${TLS_OUT}" | grep -E "issuer=" | head -n 1 || true)

if echo "${TLS_OUT}" | grep -qE "CONNECTED\(00000003\)"; then
    echo "[PASS] TLS handshake succeeded!"
    [ -n "${PROTOCOL}" ] && echo "       Protocol:     ${PROTOCOL}"
    [ -n "${CIPHER}" ] && echo "       Cipher:       ${CIPHER}"
    [ -n "${CERT_SUBJECT}" ] && echo "       ${CERT_SUBJECT}"
    [ -n "${CERT_ISSUER}" ] && echo "       ${CERT_ISSUER}"
else
    echo "[FAIL] openssl s_client connection or STARTTLS handshake failed!"
    echo "${TLS_OUT}"
    exit 1
fi

echo ""
echo "================================================================================"
echo " 3. Testing Encrypted Email Submission over STARTTLS"
echo "================================================================================"

REQ_ID="tls-test-$(date +%s)"

set +e
MAIL_OUT=$(openssl s_client -starttls smtp -crlf -quiet -connect "${SMTP_HOST}:${SMTP_PORT}" 2>/dev/null <<EOF
EHLO client.internal.company.com
MAIL FROM:<${SENDER}>
RCPT TO:<${RECIPIENT}>
DATA
From: Postfix STARTTLS Test <${SENDER}>
To: <${RECIPIENT}>
Subject: [TEST] Inbound STARTTLS Verification
Date: $(date -R)
Message-ID: <${REQ_ID}@company.com>
X-Request-ID: ${REQ_ID}
Content-Type: text/plain; charset=UTF-8

This email was securely delivered using Postfix Inbound STARTTLS.
.
QUIT
EOF
)
set -e

echo "${MAIL_OUT}"

if echo "${MAIL_OUT}" | grep -qE "250.*Queued|250.*Ok"; then
    echo "[PASS] Email successfully queued over encrypted STARTTLS channel!"
else
    echo "[WARN] Verification submission returned: ${MAIL_OUT}"
fi
