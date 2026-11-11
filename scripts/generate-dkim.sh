#!/usr/bin/env bash
set -euo pipefail

DOMAIN="${1:-${MAIL_DOMAIN:-company.com}}"
SELECTOR="${2:-${DKIM_SELECTOR:-mail}}"
BITS="${3:-${DKIM_KEY_BITS:-2048}}"
KEY_BASE_DIR="${4:-/etc/opendkim/keys}"

DOMAIN_DIR="${KEY_BASE_DIR}/${DOMAIN}"
PRIV_KEY="${DOMAIN_DIR}/${SELECTOR}.private"
TXT_FILE="${DOMAIN_DIR}/${SELECTOR}.txt"

mkdir -p "${DOMAIN_DIR}"

if [ -f "${PRIV_KEY}" ]; then
    echo "[DKIM] Existing DKIM private key found at ${PRIV_KEY}"
else
    echo "[DKIM] Generating ${BITS}-bit RSA DKIM key for ${SELECTOR}._domainkey.${DOMAIN}..."
    if command -v opendkim-genkey >/dev/null 2>&1; then
        opendkim-genkey -b "${BITS}" -d "${DOMAIN}" -D "${DOMAIN_DIR}" -s "${SELECTOR}" -v
    else
        # Fallback using openssl if run on host without opendkim-tools installed
        openssl genrsa -out "${PRIV_KEY}" "${BITS}" 2>/dev/null
        PUB_B64="$(openssl rsa -in "${PRIV_KEY}" -pubout -outform PEM 2>/dev/null | grep -v '^--' | tr -d '\n')"
        cat > "${TXT_FILE}" <<EOF
${SELECTOR}._domainkey	IN	TXT	( "v=DKIM1; h=sha256; k=rsa; "
	  "p=${PUB_B64:0:250}"
	  "${PUB_B64:250}" )  ; ----- DKIM key ${SELECTOR} for ${DOMAIN}
EOF
    fi
fi

if id opendkim >/dev/null 2>&1; then
    chown -R opendkim:opendkim "${DOMAIN_DIR}"
fi
chmod 0600 "${PRIV_KEY}"
chmod 0644 "${TXT_FILE}" 2>/dev/null || true

if [ -f "${TXT_FILE}" ]; then
    echo "================================================================================"
    echo " DKIM DNS TXT Record for ${DOMAIN} (Selector: ${SELECTOR})"
    echo " File: ${TXT_FILE}"
    echo "--------------------------------------------------------------------------------"
    cat "${TXT_FILE}"
    echo "================================================================================"
fi
