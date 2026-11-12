#!/usr/bin/env bash
set -euo pipefail

log_info() {
    echo "[$(date -Iseconds)] [INFO] $*"
}

log_warn() {
    echo "[$(date -Iseconds)] [WARN] $*" >&2
}

# ==============================================================================
# 1. ENVIRONMENT DEFAULTS & DYNAMIC OUTBOUND VIP RESOLUTION
# ==============================================================================
: "${TZ:=Asia/Bangkok}"
: "${MAIL_DOMAIN:=company.com}"
: "${MYHOSTNAME:=mail.${MAIL_DOMAIN}}"

: "${INBOUND_VIP:=10.10.10.100}"
: "${INBOUND_INET_INTERFACES:=all}"

# Dynamic Outbound VIP Resolution:
# Supports Option 1 (Numbered variables): OUTBOUND_VIP_1..N and OUTBOUND_VIP_1..N_HELO
# Also supports Option 2 (List variable): OUTBOUND_VIPS=ip1:helo1,ip2:helo2,...
declare -a RESOLVED_VIP_KEYS=()
declare -a RESOLVED_VIP_IPS=()
declare -a RESOLVED_VIP_HELOS=()

if [ -n "${OUTBOUND_VIPS:-}" ]; then
    IFS=',' read -ra VIP_ENTRIES <<< "${OUTBOUND_VIPS}"
    idx=1
    for raw_entry in "${VIP_ENTRIES[@]}"; do
        entry="$(echo "${raw_entry}" | xargs)"
        if [ -n "${entry}" ]; then
            if [[ "${entry}" == *":"* ]]; then
                ip="${entry%%:*}"
                helo="${entry#*:}"
            else
                ip="${entry}"
                helo="mail${idx}.${MAIL_DOMAIN}"
            fi
            RESOLVED_VIP_KEYS+=("${idx}")
            RESOLVED_VIP_IPS+=("${ip}")
            RESOLVED_VIP_HELOS+=("${helo}")
            idx=$((idx + 1))
        fi
    done
else
    # Scan for numbered variables: OUTBOUND_VIP_1, OUTBOUND_VIP_2, ...
    found_vip=0
    for i in $(seq 1 100); do
        var_name="OUTBOUND_VIP_${i}"
        if [ -n "${!var_name:-}" ]; then
            found_vip=1
            break
        fi
    done

    # If no outbound VIP variables were provided, fall back to 5 default VIPs for backward compatibility
    if [ "${found_vip}" -eq 0 ]; then
        for i in $(seq 1 5); do
            vip_var="OUTBOUND_VIP_${i}"
            helo_var="OUTBOUND_VIP_${i}_HELO"
            eval "${vip_var}=\"10.10.10.10${i}\""
            eval "${helo_var}=\"mail${i}.${MAIL_DOMAIN}\""
        done
    fi

    for i in $(seq 1 100); do
        vip_var="OUTBOUND_VIP_${i}"
        helo_var="OUTBOUND_VIP_${i}_HELO"
        if [ -n "${!vip_var:-}" ]; then
            RESOLVED_VIP_KEYS+=("${i}")
            RESOLVED_VIP_IPS+=("${!vip_var}")
            RESOLVED_VIP_HELOS+=("${!helo_var:-mail${i}.${MAIL_DOMAIN}}")
        fi
    done
fi

log_info "Resolved ${#RESOLVED_VIP_KEYS[@]} Outbound VIP(s):"
for idx in "${!RESOLVED_VIP_KEYS[@]}"; do
    log_info "  - vip${RESOLVED_VIP_KEYS[$idx]}: IP=${RESOLVED_VIP_IPS[$idx]} HELO=${RESOLVED_VIP_HELOS[$idx]}"
done

: "${ALLOWED_NETWORKS:=127.0.0.0/8, 10.10.10.0/24, 192.168.1.0/24}"
: "${ALLOWED_SENDERS:=otp@${MAIL_DOMAIN}, notification@${MAIL_DOMAIN}}"
: "${SENDER_VIP_MAPPINGS:=}"
: "${TRANSPORT_MAPS:=}"

: "${ENABLE_DKIM:=true}"
: "${DKIM_SELECTOR:=mail}"
: "${DKIM_KEY_BITS:=2048}"
: "${DKIM_CANONICALIZATION:=relaxed/simple}"

: "${MAILLOG_PATH:=/var/log/maillog}"
: "${CONSOLIDATED_LOG_PATH:=/var/log/postfix-consolidate.log}"
: "${LOG_HEADERS_REGEX:=^(Subject|From|To|Cc|Date|Message-ID|Reply-To|X-[A-Za-z0-9-]+):}"
: "${STRIP_INTERNAL_RECEIVED:=true}"
: "${CONSOLIDATE_QUEUE_TIMEOUT_SEC:=300}"
: "${LOG_RETENTION_DAYS:=30}"
: "${LOG_COMPRESS:=true}"

: "${SMTP_CONNECT_TIMEOUT:=20s}"
: "${SMTP_HELO_TIMEOUT:=30s}"
: "${SMTP_MAIL_TIMEOUT:=60s}"
: "${SMTP_RCPT_TIMEOUT:=60s}"
: "${SMTP_DATA_DONE_TIMEOUT:=120s}"
: "${SMTP_QUIT_TIMEOUT:=30s}"
: "${SMTPD_TIMEOUT:=60s}"

: "${MAXIMAL_QUEUE_LIFETIME:=4h}"
: "${BOUNCE_QUEUE_LIFETIME:=4h}"
: "${MINIMAL_BACKOFF_TIME:=120s}"
: "${MAXIMAL_BACKOFF_TIME:=900s}"
: "${QUEUE_RUN_DELAY:=120s}"

: "${DEFAULT_PROCESS_LIMIT:=100}"
: "${SMTP_DESTINATION_CONCURRENCY_LIMIT:=20}"
: "${SMTP_DESTINATION_RECIPIENT_LIMIT:=50}"
: "${SMTP_DESTINATION_RATE_DELAY:=0s}"
: "${INITIAL_DESTINATION_CONCURRENCY:=5}"
: "${MESSAGE_SIZE_LIMIT:=10485760}"

: "${SMTP_TLS_SECURITY_LEVEL:=may}"
: "${SMTP_TLS_LOGLEVEL:=1}"
: "${SMTPD_TLS_SECURITY_LEVEL:=none}"

# Set timezone if zoneinfo exists
if [ -f "/usr/share/zoneinfo/${TZ}" ]; then
    ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime
    echo "${TZ}" > /etc/timezone
fi

# ==============================================================================
# 2. PERSISTENT LOG FILES & DAILY LOGROTATE SETUP
# ==============================================================================
mkdir -p /var/log/mailserver
touch /var/log/mailserver/maillog /var/log/mailserver/postfix-consolidate.log
chmod 0644 /var/log/mailserver/maillog /var/log/mailserver/postfix-consolidate.log

if [ "${MAILLOG_PATH}" = "/var/log/maillog" ]; then
    ln -snf /var/log/mailserver/maillog /var/log/maillog
fi
if [ "${CONSOLIDATED_LOG_PATH}" = "/var/log/postfix-consolidate.log" ]; then
    ln -snf /var/log/mailserver/postfix-consolidate.log /var/log/postfix-consolidate.log
fi

COMPRESS_DIRECTIVE="compress"
if [ "${LOG_COMPRESS}" != "true" ]; then
    COMPRESS_DIRECTIVE="nocompress"
fi

cat > /etc/logrotate.d/postfix-mailserver <<EOF
/var/log/mailserver/maillog
/var/log/mailserver/postfix-consolidate.log
{
    daily
    rotate ${LOG_RETENTION_DAYS}
    missingok
    notifempty
    ${COMPRESS_DIRECTIVE}
    delaycompress
    dateext
    dateformat -%Y%m%d
    copytruncate
    sharedscripts
    postrotate
        /usr/sbin/postfix reload >/dev/null 2>&1 || true
    endscript
}
EOF
chmod 0644 /etc/logrotate.d/postfix-mailserver

# ==============================================================================
# 3. ALLOWED SENDERS MAP (/etc/postfix/allowed_senders)
# ==============================================================================
log_info "Generating /etc/postfix/allowed_senders..."
: > /etc/postfix/allowed_senders

IFS=',' read -ra SENDERS_ARR <<< "${ALLOWED_SENDERS}"
for raw_sender in "${SENDERS_ARR[@]}"; do
    sender="$(echo "${raw_sender}" | xargs)"
    if [ -n "${sender}" ]; then
        echo "${sender}    OK" >> /etc/postfix/allowed_senders
    fi
done

if [ -f /etc/postfix/custom/allowed_senders ]; then
    grep -vE '^\s*(#|$)' /etc/postfix/custom/allowed_senders >> /etc/postfix/allowed_senders || true
fi

postmap hash:/etc/postfix/allowed_senders

# ==============================================================================
# 4. DESTINATION DOMAIN TRANSPORT MAPS (/etc/postfix/transport)
# ==============================================================================
log_info "Generating /etc/postfix/transport..."
: > /etc/postfix/transport

if [ -n "${TRANSPORT_MAPS}" ]; then
    IFS=',' read -ra TMAPS_ARR <<< "${TRANSPORT_MAPS}"
    for raw_entry in "${TMAPS_ARR[@]}"; do
        entry="$(echo "${raw_entry}" | xargs)"
        if [ -n "${entry}" ]; then
            # Support both "domain.com=smtp:[mx]:25" and "domain.com smtp:[mx]:25"
            if [[ "${entry}" == *"="* ]]; then
                dom="${entry%%=*}"
                nexthop="${entry#*=}"
                echo "${dom}    ${nexthop}" >> /etc/postfix/transport
            else
                echo "${entry}" >> /etc/postfix/transport
            fi
        fi
    done
fi

if [ -f /etc/postfix/custom/transport ]; then
    grep -vE '^\s*(#|$)' /etc/postfix/custom/transport >> /etc/postfix/transport || true
fi

postmap hash:/etc/postfix/transport

# ==============================================================================
# 5. SENDER-DEPENDENT VIP ROUTING MAP (/etc/postfix/sender_transport)
# ==============================================================================
log_info "Generating /etc/postfix/sender_transport..."
: > /etc/postfix/sender_transport

if [ -n "${SENDER_VIP_MAPPINGS}" ]; then
    # Parse mappings while preserving commas inside randmap:{...}
    raw_item=""
    brace_depth=0
    for (( i=0; i<${#SENDER_VIP_MAPPINGS}; i++ )); do
        c="${SENDER_VIP_MAPPINGS:$i:1}"
        if [ "$c" = "{" ]; then
            brace_depth=$((brace_depth + 1))
            raw_item+="$c"
        elif [ "$c" = "}" ]; then
            brace_depth=$((brace_depth - 1))
            raw_item+="$c"
        elif [ "$c" = "," ] || [ "$c" = ";" ]; then
            if [ "$brace_depth" -eq 0 ]; then
                map_item="$(echo "${raw_item}" | xargs)"
                if [ -n "${map_item}" ]; then
                    sender_key="${map_item%%:*}"
                    vip_target="${map_item#*:}"
                    if [[ "${vip_target}" =~ ^vip[0-9]+$ ]]; then
                        vip_target="smtp_${vip_target}:"
                    elif [[ "${vip_target}" =~ ^smtp_vip[0-9]+$ ]]; then
                        vip_target="${vip_target}:"
                    fi
                    echo "${sender_key}    ${vip_target}" >> /etc/postfix/sender_transport
                fi
                raw_item=""
                continue
            else
                raw_item+="$c"
            fi
        else
            raw_item+="$c"
        fi
    done
    map_item="$(echo "${raw_item}" | xargs)"
    if [ -n "${map_item}" ]; then
        sender_key="${map_item%%:*}"
        vip_target="${map_item#*:}"
        if [[ "${vip_target}" =~ ^vip[0-9]+$ ]]; then
            vip_target="smtp_${vip_target}:"
        elif [[ "${vip_target}" =~ ^smtp_vip[0-9]+$ ]]; then
            vip_target="${vip_target}:"
        fi
        echo "${sender_key}    ${vip_target}" >> /etc/postfix/sender_transport
    fi
fi

if [ -f /etc/postfix/custom/sender_vip_map ]; then
    grep -vE '^\s*(#|$)' /etc/postfix/custom/sender_vip_map >> /etc/postfix/sender_transport || true
fi

postmap hash:/etc/postfix/sender_transport

# ==============================================================================
# 6. HEADER CHECKS (EMAIL HEADER LOGGING FOR JSON CONSOLIDATION + PRIVACY)
# ==============================================================================
log_info "Generating /etc/postfix/header_checks and /etc/postfix/milter_header_checks..."
cat > /etc/postfix/header_checks <<EOF
# Auto-generated by entrypoint.sh
EOF

if [ "${STRIP_INTERNAL_RECEIVED}" = "true" ]; then
    cat >> /etc/postfix/header_checks <<'EOF'
# Strip internal RFC1918 application server Received headers before outbound relay
/^Received:\s+from\s+.*\((?:.*?\s+)?\[(?:10\.\d+\.\d+\.\d+|127\.\d+\.\d+\.\d+|192\.168\.\d+\.\d+|172\.(?:1[6-9]|2\d|3[0-1])\.\d+\.\d+)\]\)/ IGNORE
EOF
fi

cat >> /etc/postfix/header_checks <<EOF
# Log selected email headers with Queue-ID via cleanup INFO action (does not alter message)
/${LOG_HEADERS_REGEX}/ INFO
EOF

if [ -f /etc/postfix/custom/header_checks.extra ]; then
    cat /etc/postfix/custom/header_checks.extra >> /etc/postfix/header_checks
fi

cat > /etc/postfix/milter_header_checks <<'EOF'
# Log OpenDKIM DKIM-Signature header with Queue-ID so postfix-consolidate.log captures DKIM details
/^DKIM-Signature:\s*(.*)$/ INFO
EOF

# ==============================================================================
# 7. CONFIGURE POSTFIX master.cf (INBOUND PORT & 5 OUTBOUND NAT VIP TRANSPORTS)
# ==============================================================================
SMTP_INBOUND_PORT="${SMTP_INBOUND_PORT:-25}"
log_info "Configuring Inbound SMTP port (${SMTP_INBOUND_PORT}) in /etc/postfix/master.cf..."

if [ "${SMTP_INBOUND_PORT}" != "25" ] && [ "${SMTP_INBOUND_PORT}" != "smtp" ]; then
    # Replace active 'smtp inet ... smtpd' or existing custom port '<port> inet ... smtpd'
    if grep -q -E "^(smtp|[0-9]+)[[:space:]]+inet.*smtpd" /etc/postfix/master.cf; then
        sed -i -E "s/^(smtp|[0-9]+)([[:space:]]+inet[[:space:]]+.*smtpd)/${SMTP_INBOUND_PORT}\2/" /etc/postfix/master.cf
    else
        echo "${SMTP_INBOUND_PORT} inet n - n - - smtpd" >> /etc/postfix/master.cf
    fi
else
    sed -i -E "s/^[0-9]+([[:space:]]+inet[[:space:]]+.*smtpd)/smtp\1/" /etc/postfix/master.cf
fi

log_info "Configuring ${#RESOLVED_VIP_KEYS[@]} Outbound VIP transport(s) in /etc/postfix/master.cf..."

# Remove any previously appended block before adding fresh block
sed -i '/# === BEGIN MULTI-VIP TRANSPORTS ===/,/# === END MULTI-VIP TRANSPORTS ===/d' /etc/postfix/master.cf

{
    echo "# === BEGIN MULTI-VIP TRANSPORTS ==="
    for idx in "${!RESOLVED_VIP_KEYS[@]}"; do
        k="${RESOLVED_VIP_KEYS[$idx]}"
        ip="${RESOLVED_VIP_IPS[$idx]}"
        helo="${RESOLVED_VIP_HELOS[$idx]}"
        echo "smtp_vip${k} unix - - n - - smtp"
        echo "  -o syslog_name=postfix/vip${k}"
        echo "  -o smtp_bind_address=${ip}"
        echo "  -o smtp_helo_name=${helo}"
        echo ""
    done
    echo "# === END MULTI-VIP TRANSPORTS ==="
} >> /etc/postfix/master.cf

# ==============================================================================
# 8. CONFIGURE POSTFIX main.cf
# ==============================================================================
log_info "Configuring /etc/postfix/main.cf..."

postconf -e "myhostname = ${MYHOSTNAME}"
postconf -e "mydomain = ${MAIL_DOMAIN}"
postconf -e "myorigin = \$mydomain"
postconf -e "inet_interfaces = ${INBOUND_INET_INTERFACES}"
postconf -e "inet_protocols = ipv4"
postconf -e "mydestination = localhost.\$mydomain, localhost"
postconf -e "mynetworks = ${ALLOWED_NETWORKS}"

# Native file logging to /var/log/mailserver/maillog (symlinked to /var/log/maillog)
postconf -e "maillog_file = /var/log/mailserver/maillog"
postconf -e "maillog_file_prefixes = /var/log"

# Multi-VIP load-balancing default transport:
# - If 2 or more VIPs: use Postfix randmap for round-robin load balancing
# - If exactly 1 VIP: direct default transport
# - If 0 VIPs: standard postfix smtp default
if [ "${#RESOLVED_VIP_KEYS[@]}" -gt 1 ]; then
    randmap_targets=""
    for k in "${RESOLVED_VIP_KEYS[@]}"; do
        if [ -z "${randmap_targets}" ]; then
            randmap_targets="smtp_vip${k}"
        else
            randmap_targets="${randmap_targets},smtp_vip${k}"
        fi
    done
    log_info "Setting default_transport = randmap:{${randmap_targets}}"
    postconf -e "default_transport = randmap:{${randmap_targets}}"
elif [ "${#RESOLVED_VIP_KEYS[@]}" -eq 1 ]; then
    log_info "Setting default_transport = smtp_vip${RESOLVED_VIP_KEYS[0]}"
    postconf -e "default_transport = smtp_vip${RESOLVED_VIP_KEYS[0]}"
else
    log_info "No outbound VIPs configured, setting default_transport = smtp"
    postconf -e "default_transport = smtp"
fi
postconf -e "transport_maps = hash:/etc/postfix/transport"
if [ -s /etc/postfix/sender_transport ]; then
    postconf -e "sender_dependent_default_transport_maps = hash:/etc/postfix/sender_transport"
else
    postconf -X sender_dependent_default_transport_maps || true
fi

# Strict Access Controls:
# 1. Only clients in ALLOWED_NETWORKS (mynetworks) can connect/send
# 2. Only sender emails in ALLOWED_SENDERS (/etc/postfix/allowed_senders) are accepted
postconf -e "smtpd_delay_reject = yes"
postconf -e "smtpd_helo_required = yes"
postconf -e "smtpd_client_restrictions = permit_mynetworks, reject"
postconf -e "smtpd_sender_restrictions = check_sender_access hash:/etc/postfix/allowed_senders, reject"
postconf -e "smtpd_relay_restrictions = permit_mynetworks, reject_unauth_destination"
postconf -e "smtpd_recipient_restrictions = permit_mynetworks, reject_unauth_destination"

# Header logging & privacy cleanup
postconf -e "header_checks = pcre:/etc/postfix/header_checks"
postconf -e "milter_header_checks = pcre:/etc/postfix/milter_header_checks"

# Timeouts & OTP queue lifetime tuning
postconf -e "smtp_connect_timeout = ${SMTP_CONNECT_TIMEOUT}"
postconf -e "smtp_helo_timeout = ${SMTP_HELO_TIMEOUT}"
postconf -e "smtp_mail_timeout = ${SMTP_MAIL_TIMEOUT}"
postconf -e "smtp_rcpt_timeout = ${SMTP_RCPT_TIMEOUT}"
postconf -e "smtp_data_done_timeout = ${SMTP_DATA_DONE_TIMEOUT}"
postconf -e "smtp_quit_timeout = ${SMTP_QUIT_TIMEOUT}"
postconf -e "smtpd_timeout = ${SMTPD_TIMEOUT}"

postconf -e "maximal_queue_lifetime = ${MAXIMAL_QUEUE_LIFETIME}"
postconf -e "bounce_queue_lifetime = ${BOUNCE_QUEUE_LIFETIME}"
postconf -e "minimal_backoff_time = ${MINIMAL_BACKOFF_TIME}"
postconf -e "maximal_backoff_time = ${MAXIMAL_BACKOFF_TIME}"
postconf -e "queue_run_delay = ${QUEUE_RUN_DELAY}"

# Concurrency, rate limits & message size
postconf -e "default_process_limit = ${DEFAULT_PROCESS_LIMIT}"
postconf -e "smtp_destination_concurrency_limit = ${SMTP_DESTINATION_CONCURRENCY_LIMIT}"
postconf -e "smtp_destination_recipient_limit = ${SMTP_DESTINATION_RECIPIENT_LIMIT}"
postconf -e "smtp_destination_rate_delay = ${SMTP_DESTINATION_RATE_DELAY}"
postconf -e "initial_destination_concurrency = ${INITIAL_DESTINATION_CONCURRENCY}"
postconf -e "message_size_limit = ${MESSAGE_SIZE_LIMIT}"

# Outbound & Inbound TLS configuration
postconf -e "smtp_tls_security_level = ${SMTP_TLS_SECURITY_LEVEL}"
postconf -e "smtp_tls_loglevel = ${SMTP_TLS_LOGLEVEL}"
postconf -e "smtp_tls_CAfile = /etc/pki/tls/certs/ca-bundle.crt"
postconf -e "smtp_tls_session_cache_database = lmdb:\${data_directory}/smtp_scache"
postconf -e "smtp_tls_mandatory_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1"
postconf -e "smtp_tls_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1"
postconf -e "smtpd_tls_security_level = ${SMTPD_TLS_SECURITY_LEVEL}"

# Hardening
postconf -e "disable_vrfy_command = yes"
postconf -e "smtpd_banner = \$myhostname ESMTP"
postconf -e "biff = no"
postconf -e "append_dot_mydomain = no"

# ==============================================================================
# 9. CONFIGURE OPENDKIM SIGNING FOR MAIL_DOMAIN
# ==============================================================================
if [ "${ENABLE_DKIM}" = "true" ]; then
    log_info "Configuring OpenDKIM for domain ${MAIL_DOMAIN} (selector: ${DKIM_SELECTOR})..."
    /usr/local/bin/generate-dkim.sh "${MAIL_DOMAIN}" "${DKIM_SELECTOR}" "${DKIM_KEY_BITS}"

    cat > /etc/opendkim.conf <<EOF
PidFile                 /run/opendkim/opendkim.pid
Mode                    sv
Syslog                  yes
SyslogSuccess           yes
LogWhy                  yes
UserID                  opendkim:opendkim
Socket                  inet:8891@127.0.0.1
Umask                   002
SendReports             no
SoftwareHeader          no
Canonicalization        ${DKIM_CANONICALIZATION}
Selector                ${DKIM_SELECTOR}
MinimumKeyBits          1024
KeyTable                refile:/etc/opendkim/KeyTable
SigningTable            refile:/etc/opendkim/SigningTable
ExternalIgnoreList      refile:/etc/opendkim/TrustedHosts
InternalHosts           refile:/etc/opendkim/TrustedHosts
SignatureAlgorithm      rsa-sha256
AutoRestart             yes
AutoRestartRate         10/1h
EOF

    cat > /etc/opendkim/KeyTable <<EOF
${DKIM_SELECTOR}._domainkey.${MAIL_DOMAIN} ${MAIL_DOMAIN}:${DKIM_SELECTOR}:/etc/opendkim/keys/${MAIL_DOMAIN}/${DKIM_SELECTOR}.private
EOF

    cat > /etc/opendkim/SigningTable <<EOF
*@${MAIL_DOMAIN} ${DKIM_SELECTOR}._domainkey.${MAIL_DOMAIN}
*@*.${MAIL_DOMAIN} ${DKIM_SELECTOR}._domainkey.${MAIL_DOMAIN}
EOF

    cat > /etc/opendkim/TrustedHosts <<EOF
127.0.0.1
::1
localhost
${MYHOSTNAME}
*.${MAIL_DOMAIN}
${INBOUND_VIP}
EOF

    for ip in "${RESOLVED_VIP_IPS[@]}"; do
        echo "${ip}" >> /etc/opendkim/TrustedHosts
    done

    IFS=',' read -ra NET_ARR <<< "${ALLOWED_NETWORKS}"
    for raw_net in "${NET_ARR[@]}"; do
        net="$(echo "${raw_net}" | xargs)"
        if [ -n "${net}" ]; then
            echo "${net}" >> /etc/opendkim/TrustedHosts
        fi
    done

    chown -R opendkim:opendkim /etc/opendkim
    chmod 0640 /etc/opendkim/KeyTable /etc/opendkim/SigningTable /etc/opendkim/TrustedHosts
    mkdir -p /run/opendkim
    chown -R opendkim:opendkim /run/opendkim

    postconf -e "smtpd_milters = inet:127.0.0.1:8891"
    postconf -e "non_smtpd_milters = inet:127.0.0.1:8891"
    postconf -e "milter_default_action = accept"
    postconf -e "milter_protocol = 6"
else
    postconf -X smtpd_milters || true
    postconf -X non_smtpd_milters || true
fi

# ==============================================================================
# 10. CREATE HEALTHCHECK SCRIPT
# ==============================================================================
cat > /usr/local/bin/healthcheck.sh <<EOF
#!/usr/bin/env bash
set -e
# 1. Verify Postfix master process is running
/usr/sbin/postfix status >/dev/null 2>&1
# 2. Verify SMTP port (${SMTP_INBOUND_PORT}) is listening locally
nc -z -w 3 127.0.0.1 \${SMTP_INBOUND_PORT:-${SMTP_INBOUND_PORT}} >/dev/null 2>&1
# 3. Verify JSON log consolidator is running
pgrep -f "postfix-log-consolidator.py" >/dev/null 2>&1
EOF

if [ "${ENABLE_DKIM}" = "true" ]; then
    cat >> /usr/local/bin/healthcheck.sh <<'EOF'
# 4. Verify OpenDKIM milter port 8891 is listening
nc -z -w 3 127.0.0.1 8891 >/dev/null 2>&1
EOF
fi
chmod +x /usr/local/bin/healthcheck.sh

# ==============================================================================
# 11. INITIALIZE SPOOL PERMISSIONS & START SERVICES
# ==============================================================================
# Ensure Postfix spool directories exist inside mounted volume
postfix set-permissions >/dev/null 2>&1 || true
newaliases >/dev/null 2>&1 || true
postfix check

log_info "Starting crond for daily logrotate..."
crond

if [ "${ENABLE_DKIM}" = "true" ]; then
    log_info "Starting OpenDKIM milter on 127.0.0.1:8891..."
    /usr/sbin/opendkim -x /etc/opendkim.conf
fi

log_info "Starting Postfix Queue-ID JSON Log Consolidator (${MAILLOG_PATH} -> ${CONSOLIDATED_LOG_PATH})..."
/usr/local/bin/postfix-log-consolidator.py \
    --input "${MAILLOG_PATH}" \
    --output "${CONSOLIDATED_LOG_PATH}" \
    --timeout "${CONSOLIDATE_QUEUE_TIMEOUT_SEC}" &
CONSOLIDATOR_PID=$!

cleanup() {
    log_info "Shutting down Postfix, OpenDKIM, and JSON Log Consolidator..."
    /usr/sbin/postfix stop || true
    kill -TERM "${CONSOLIDATOR_PID}" 2>/dev/null || true
    pkill -TERM opendkim 2>/dev/null || true
    wait "${CONSOLIDATOR_PID}" 2>/dev/null || true
    exit 0
}
trap cleanup SIGTERM SIGINT

log_info "Starting Postfix in foreground mode..."
/usr/sbin/postfix start-fg &
POSTFIX_PID=$!

wait "${POSTFIX_PID}"
cleanup
