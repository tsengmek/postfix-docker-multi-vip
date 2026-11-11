#!/usr/bin/env bash
set -euo pipefail

SMTP_HOST="${1:-127.0.0.1}"
SMTP_PORT="${2:-${SMTP_INBOUND_PORT:-25}}"
RECIPIENT="${3:-test-recipient@example.com}"
ALLOWED_SENDER="${4:-otp@company.com}"
BLOCKED_SENDER="unauthorized@company.com"

echo "================================================================================"
echo " 1. Testing Unauthorized Sender Rejection (${BLOCKED_SENDER} -> ${SMTP_HOST}:${SMTP_PORT})"
echo "================================================================================"
set +e
REJECT_OUT=$(nc -w 5 "${SMTP_HOST}" "${SMTP_PORT}" <<EOF
EHLO app01.internal.company.com
MAIL FROM:<${BLOCKED_SENDER}>
RCPT TO:<${RECIPIENT}>
QUIT
EOF
)
set -e
echo "${REJECT_OUT}"
if echo "${REJECT_OUT}" | grep -qE "554|550|reject"; then
    echo "[PASS] Unauthorized sender ${BLOCKED_SENDER} was properly rejected."
else
    echo "[WARN] Did not observe expected 554 rejection response above."
fi

echo ""
echo "================================================================================"
echo " 2. Testing Authorized OTP Sender (${ALLOWED_SENDER} -> ${RECIPIENT})"
echo "================================================================================"
REQ_ID="otp-$(date +%s)"
SEND_OUT=$(nc -w 5 "${SMTP_HOST}" "${SMTP_PORT}" <<EOF
EHLO app01.internal.company.com
MAIL FROM:<${ALLOWED_SENDER}>
RCPT TO:<${RECIPIENT}>
DATA
From: Company OTP Service <${ALLOWED_SENDER}>
To: <${RECIPIENT}>
Subject: [OTP] Your verification code is 849201
Date: $(date -R)
Message-ID: <${REQ_ID}@company.com>
X-Request-ID: ${REQ_ID}
X-Application: auth-service
MIME-Version: 1.0
Content-Type: text/plain; charset=UTF-8

Your one-time password (OTP) is 849201. It expires in 5 minutes.
.
QUIT
EOF
)
echo "${SEND_OUT}"
echo ""
echo "Waiting 2 seconds for log consolidation..."
sleep 2

if [ -f ./logs/postfix-consolidate.log ]; then
    echo "================================================================================"
    echo " Latest Consolidated JSON Log Entry (./logs/postfix-consolidate.log):"
    echo "================================================================================"
    tail -n 2 ./logs/postfix-consolidate.log
fi
