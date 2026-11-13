#!/usr/bin/env bash
# ==============================================================================
# Automated Test Suite for Dynamic Outbound Mail VIP Scaling
# Verifies:
#   1. Default backward compatibility (5 default VIPs when no vars provided)
#   2. Scaling down to 2 VIPs (OUTBOUND_VIP_1, OUTBOUND_VIP_2)
#   3. Scaling up to 8 VIPs (OUTBOUND_VIP_1 .. OUTBOUND_VIP_8)
#   4. Single VIP mode (OUTBOUND_VIP_1 -> default_transport = smtp_vip1)
#   5. Comma-separated list syntax (OUTBOUND_VIPS)
#   6. Sender-to-VIP mapping with dynamic VIP indices (vip7, smtp_vip8)
# ==============================================================================
set -euo pipefail

TEST_DIR=$(mktemp -d -t test-dynamic-vips-XXXXXX)
trap 'rm -rf "${TEST_DIR}"' EXIT

PASS_COUNT=0
FAIL_COUNT=0

pass() {
    echo "  [PASS] $*"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo "  [FAIL] $*" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

# Helper runner that isolates entrypoint configuration steps 1, 5, 7, 8, 9
run_vip_resolution_harness() {
    local mock_root="${1}"
    mkdir -p "${mock_root}/etc/postfix" "${mock_root}/etc/opendkim" "${mock_root}/bin"

    # Seed mock master.cf
    cat > "${mock_root}/etc/postfix/master.cf" <<'EOF'
smtp inet n - n - - smtpd
# === BEGIN MULTI-VIP TRANSPORTS ===
old_dummy unix - - n - - smtp
# === END MULTI-VIP TRANSPORTS ===
EOF

    # Mock postconf to record key-value pairs
    cat > "${mock_root}/bin/postconf" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "-e" ]; then
    echo "$2" >> "${MOCK_POSTCONF_RECORD}"
fi
EOF
    chmod +x "${mock_root}/bin/postconf"

    # Mock postmap
    cat > "${mock_root}/bin/postmap" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "${mock_root}/bin/postmap"

    # Run the isolated resolution and config generation snippet from entrypoint.sh
    PATH="${mock_root}/bin:${PATH}" \
    MOCK_POSTCONF_RECORD="${mock_root}/postconf.record" \
    MOCK_ROOT="${mock_root}" \
    bash -c '
        set -euo pipefail
        log_info() { :; }
        MAIL_DOMAIN="${MAIL_DOMAIN:-company.com}"
        MYHOSTNAME="${MYHOSTNAME:-mail.${MAIL_DOMAIN}}"
        INBOUND_VIP="${INBOUND_VIP:-10.10.10.100}"
        INBOUND_INET_INTERFACES="${INBOUND_INET_INTERFACES:-all}"
        ALLOWED_NETWORKS="${ALLOWED_NETWORKS:-127.0.0.0/8}"
        SENDER_VIP_MAPPINGS="${SENDER_VIP_MAPPINGS:-}"

        # 1. VIP Resolution Logic
        declare -a RESOLVED_VIP_KEYS=()
        declare -a RESOLVED_VIP_IPS=()
        declare -a RESOLVED_VIP_HELOS=()

        if [ -n "${OUTBOUND_VIPS:-}" ]; then
            IFS="," read -ra VIP_ENTRIES <<< "${OUTBOUND_VIPS}"
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
            # Check for singular OUTBOUND_VIP alias for OUTBOUND_VIP_1
            if [ -n "${OUTBOUND_VIP:-}" ] && [ -z "${OUTBOUND_VIP_1:-}" ]; then
                OUTBOUND_VIP_1="${OUTBOUND_VIP}"
            fi
            if [ -n "${OUTBOUND_VIP_HELO:-}" ] && [ -z "${OUTBOUND_VIP_1_HELO:-}" ]; then
                OUTBOUND_VIP_1_HELO="${OUTBOUND_VIP_HELO}"
            fi

            found_vip=0
            for i in $(seq 1 100); do
                var_name="OUTBOUND_VIP_${i}"
                if [ -n "${!var_name:-}" ]; then
                    found_vip=1
                    break
                fi
            done

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

        # 5. SENDER_VIP_MAPPINGS
        : > "${MOCK_ROOT}/etc/postfix/sender_transport"
        if [ -n "${SENDER_VIP_MAPPINGS}" ]; then
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
                            sender_key="$(echo "${map_item%%:*}" | tr '[:upper:]' '[:lower:]')"
                            vip_target="${map_item#*:}"
                            if [[ "${vip_target}" =~ ^vip[0-9]+$ ]]; then
                                vip_target="smtp_${vip_target}:"
                            elif [[ "${vip_target}" =~ ^smtp_vip[0-9]+$ ]]; then
                                vip_target="${vip_target}:"
                            fi
                            echo "${sender_key}    ${vip_target}" >> "${MOCK_ROOT}/etc/postfix/sender_transport"
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
                sender_key="$(echo "${map_item%%:*}" | tr '[:upper:]' '[:lower:]')"
                vip_target="${map_item#*:}"
                if [[ "${vip_target}" =~ ^vip[0-9]+$ ]]; then
                    vip_target="smtp_${vip_target}:"
                elif [[ "${vip_target}" =~ ^smtp_vip[0-9]+$ ]]; then
                    vip_target="${vip_target}:"
                fi
                echo "${sender_key}    ${vip_target}" >> "${MOCK_ROOT}/etc/postfix/sender_transport"
            fi
        fi

        # 7. master.cf Generation
        sed -i "/# === BEGIN MULTI-VIP TRANSPORTS ===/,/# === END MULTI-VIP TRANSPORTS ===/d" "${MOCK_ROOT}/etc/postfix/master.cf"
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
        } >> "${MOCK_ROOT}/etc/postfix/master.cf"

        # 8. main.cf Default Transport & Proxy Protocol
        if [ "${#RESOLVED_VIP_KEYS[@]}" -gt 1 ]; then
            randmap_targets=""
            for k in "${RESOLVED_VIP_KEYS[@]}"; do
                if [ -z "${randmap_targets}" ]; then
                    randmap_targets="smtp_vip${k}:"
                else
                    randmap_targets="${randmap_targets},smtp_vip${k}:"
                fi
            done
            postconf -e "default_transport = smtp"
            if [ -s "${MOCK_ROOT}/etc/postfix/sender_transport" ]; then
                postconf -e "sender_dependent_default_transport_maps = hash:/etc/postfix/sender_transport, randmap:{${randmap_targets}}"
            else
                postconf -e "sender_dependent_default_transport_maps = randmap:{${randmap_targets}}"
            fi
            postconf -e "smtp_connection_cache_on_demand = no"
        elif [ "${#RESOLVED_VIP_KEYS[@]}" -eq 1 ]; then
            postconf -e "default_transport = smtp_vip${RESOLVED_VIP_KEYS[0]}"
            if [ -s "${MOCK_ROOT}/etc/postfix/sender_transport" ]; then
                postconf -e "sender_dependent_default_transport_maps = hash:/etc/postfix/sender_transport"
            fi
        else
            postconf -e "default_transport = smtp"
        fi

        if [ "${ENABLE_HAPROXY_PROXY_PROTOCOL:-false}" = "true" ]; then
            postconf -e "smtpd_upstream_proxy_protocol = haproxy"
            postconf -e "smtpd_upstream_proxy_timeout = 5s"
        fi

        # 9. OpenDKIM TrustedHosts
        cat > "${MOCK_ROOT}/etc/opendkim/TrustedHosts" <<EOF
127.0.0.1
::1
localhost
${MYHOSTNAME}
*.${MAIL_DOMAIN}
${INBOUND_VIP}
EOF
        for ip in "${RESOLVED_VIP_IPS[@]}"; do
            echo "${ip}" >> "${MOCK_ROOT}/etc/opendkim/TrustedHosts"
        done
    '
}

echo "================================================================================"
echo " Running Dynamic Outbound VIP Test Suite"
echo "================================================================================"

# ------------------------------------------------------------------------------
# Test 1: Backward Compatibility (No VIP variables -> 5 default VIPs)
# ------------------------------------------------------------------------------
echo "Test 1: Backward Compatibility (zero VIP env vars provided)..."
MOCK_T1="${TEST_DIR}/test1"
run_vip_resolution_harness "${MOCK_T1}"

if grep -q "default_transport = smtp" "${MOCK_T1}/postconf.record" && \
   grep -q "sender_dependent_default_transport_maps = randmap:{smtp_vip1:,smtp_vip2:,smtp_vip3:,smtp_vip4:,smtp_vip5:}" "${MOCK_T1}/postconf.record"; then
    pass "main.cf configured with 5-VIP randmap in sender_dependent_default_transport_maps"
else
    fail "main.cf missing expected 5-VIP randmap in sender_dependent_default_transport_maps"
fi

if [ "$(grep -c '^smtp_vip[0-9]\+ unix' "${MOCK_T1}/etc/postfix/master.cf")" -eq 5 ]; then
    pass "master.cf contains exactly 5 VIP transport definitions"
else
    fail "master.cf transport count mismatch"
fi

if grep -q "10.10.10.105" "${MOCK_T1}/etc/opendkim/TrustedHosts"; then
    pass "OpenDKIM TrustedHosts contains VIP 5 (10.10.10.105)"
else
    fail "OpenDKIM TrustedHosts missing VIP 5"
fi

# ------------------------------------------------------------------------------
# Test 2: Scale Down to 2 VIPs (Option 1: OUTBOUND_VIP_1 and OUTBOUND_VIP_2)
# ------------------------------------------------------------------------------
echo ""
echo "Test 2: Scale down to 2 VIPs (OUTBOUND_VIP_1 & OUTBOUND_VIP_2)..."
MOCK_T2="${TEST_DIR}/test2"
OUTBOUND_VIP_1="10.10.10.101" \
OUTBOUND_VIP_1_HELO="mail1.company.com" \
OUTBOUND_VIP_2="10.10.10.102" \
OUTBOUND_VIP_2_HELO="mail2.company.com" \
run_vip_resolution_harness "${MOCK_T2}"

if grep -q "default_transport = smtp" "${MOCK_T2}/postconf.record" && \
   grep -q "sender_dependent_default_transport_maps = randmap:{smtp_vip1:,smtp_vip2:}" "${MOCK_T2}/postconf.record"; then
    pass "main.cf configured with exactly 2-VIP randmap: randmap:{smtp_vip1:,smtp_vip2:}"
else
    fail "main.cf randmap mismatch for 2 VIPs"
fi

TRANSPORT_COUNT_T2=$(grep -c '^smtp_vip[0-9]\+ unix' "${MOCK_T2}/etc/postfix/master.cf")
if [ "${TRANSPORT_COUNT_T2}" -eq 2 ]; then
    pass "master.cf contains exactly 2 VIP transport definitions"
else
    fail "master.cf expected 2 transports, got ${TRANSPORT_COUNT_T2}"
fi

if ! grep -q "10.10.10.103" "${MOCK_T2}/etc/opendkim/TrustedHosts"; then
    pass "OpenDKIM TrustedHosts does NOT contain omitted VIP 3"
else
    fail "OpenDKIM TrustedHosts erroneously contains VIP 3"
fi

# ------------------------------------------------------------------------------
# Test 3: Scale Up to 8 VIPs
# ------------------------------------------------------------------------------
echo ""
echo "Test 3: Scale up to 8 VIPs (OUTBOUND_VIP_1 .. OUTBOUND_VIP_8)..."
MOCK_T3="${TEST_DIR}/test3"
OUTBOUND_VIP_1="10.10.10.101" \
OUTBOUND_VIP_2="10.10.10.102" \
OUTBOUND_VIP_3="10.10.10.103" \
OUTBOUND_VIP_4="10.10.10.104" \
OUTBOUND_VIP_5="10.10.10.105" \
OUTBOUND_VIP_6="10.10.10.106" \
OUTBOUND_VIP_7="10.10.10.107" \
OUTBOUND_VIP_8="10.10.10.108" \
run_vip_resolution_harness "${MOCK_T3}"

if grep -q "default_transport = smtp" "${MOCK_T3}/postconf.record" && \
   grep -q "sender_dependent_default_transport_maps = randmap:{smtp_vip1:,smtp_vip2:,smtp_vip3:,smtp_vip4:,smtp_vip5:,smtp_vip6:,smtp_vip7:,smtp_vip8:}" "${MOCK_T3}/postconf.record"; then
    pass "main.cf configured with 8-VIP randmap"
else
    fail "main.cf randmap mismatch for 8 VIPs"
fi

TRANSPORT_COUNT_T3=$(grep -c '^smtp_vip[0-9]\+ unix' "${MOCK_T3}/etc/postfix/master.cf")
if [ "${TRANSPORT_COUNT_T3}" -eq 8 ]; then
    pass "master.cf contains exactly 8 VIP transport definitions"
else
    fail "master.cf expected 8 transports, got ${TRANSPORT_COUNT_T3}"
fi

if grep -q "10.10.10.108" "${MOCK_T3}/etc/opendkim/TrustedHosts"; then
    pass "OpenDKIM TrustedHosts contains VIP 8 (10.10.10.108)"
else
    fail "OpenDKIM TrustedHosts missing VIP 8"
fi

# ------------------------------------------------------------------------------
# Test 4: Single VIP Mode (1 VIP)
# ------------------------------------------------------------------------------
echo ""
echo "Test 4: Single VIP mode (OUTBOUND_VIP_1 only)..."
MOCK_T4="${TEST_DIR}/test4"
OUTBOUND_VIP_1="10.10.10.101" \
run_vip_resolution_harness "${MOCK_T4}"

if grep -q "default_transport = smtp_vip1" "${MOCK_T4}/postconf.record"; then
    pass "main.cf configured directly with default_transport = smtp_vip1 (no randmap wrapper)"
else
    fail "main.cf single VIP transport mismatch"
fi

TRANSPORT_COUNT_T4=$(grep -c '^smtp_vip[0-9]\+ unix' "${MOCK_T4}/etc/postfix/master.cf")
if [ "${TRANSPORT_COUNT_T4}" -eq 1 ]; then
    pass "master.cf contains exactly 1 VIP transport definition"
else
    fail "master.cf expected 1 transport, got ${TRANSPORT_COUNT_T4}"
fi

# ------------------------------------------------------------------------------
# Test 5: List Format (OUTBOUND_VIPS)
# ------------------------------------------------------------------------------
echo ""
echo "Test 5: List format with custom HELO (OUTBOUND_VIPS)..."
MOCK_T5="${TEST_DIR}/test5"
OUTBOUND_VIPS="192.168.1.101,192.168.1.102:custom.helo.com,192.168.1.103" \
run_vip_resolution_harness "${MOCK_T5}"

if grep -q "default_transport = smtp" "${MOCK_T5}/postconf.record" && \
   grep -q "sender_dependent_default_transport_maps = randmap:{smtp_vip1:,smtp_vip2:,smtp_vip3:}" "${MOCK_T5}/postconf.record"; then
    pass "main.cf configured with 3-VIP randmap from list syntax"
else
    fail "main.cf randmap mismatch from list syntax"
fi

if grep -q -- "-o smtp_helo_name=custom.helo.com" "${MOCK_T5}/etc/postfix/master.cf"; then
    pass "master.cf contains custom HELO name (custom.helo.com) for VIP 2"
else
    fail "master.cf missing custom HELO name"
fi

# ------------------------------------------------------------------------------
# Test 6: Dynamic SENDER_VIP_MAPPINGS (Indices beyond 5)
# ------------------------------------------------------------------------------
echo ""
echo "Test 6: SENDER_VIP_MAPPINGS with dynamic indices (vip7, smtp_vip8)..."
MOCK_T6="${TEST_DIR}/test6"
OUTBOUND_VIP_1="10.10.10.101" \
OUTBOUND_VIP_7="10.10.10.107" \
OUTBOUND_VIP_8="10.10.10.108" \
SENDER_VIP_MAPPINGS="otp@company.com:vip7, alerts@company.com:smtp_vip8, bulk@company.com:randmap:{smtp_vip1,smtp_vip7}" \
run_vip_resolution_harness "${MOCK_T6}"

if grep -q "otp@company.com    smtp_vip7:" "${MOCK_T6}/etc/postfix/sender_transport"; then
    pass "sender_transport mapped shorthand vip7 -> smtp_vip7:"
else
    fail "sender_transport failed to map vip7"
fi

if grep -q "alerts@company.com    smtp_vip8:" "${MOCK_T6}/etc/postfix/sender_transport"; then
    pass "sender_transport mapped smtp_vip8 -> smtp_vip8:"
else
    fail "sender_transport failed to map smtp_vip8"
fi

if grep -q "bulk@company.com    randmap:{smtp_vip1,smtp_vip7}" "${MOCK_T6}/etc/postfix/sender_transport"; then
    pass "sender_transport preserved multi-vip randmap subset"
else
    fail "sender_transport failed to preserve randmap subset"
fi

# ------------------------------------------------------------------------------
# Test 7: Singular OUTBOUND_VIP alias for single VIP mode
# ------------------------------------------------------------------------------
echo ""
echo "Test 7: Singular OUTBOUND_VIP alias for single VIP mode..."
MOCK_T7="${TEST_DIR}/test7"
OUTBOUND_VIP="10.10.10.101" \
OUTBOUND_VIP_HELO="single.company.com" \
run_vip_resolution_harness "${MOCK_T7}"

if grep -q "default_transport = smtp_vip1" "${MOCK_T7}/postconf.record"; then
    pass "OUTBOUND_VIP alias configured single VIP default_transport = smtp_vip1"
else
    fail "OUTBOUND_VIP alias failed to configure single VIP transport"
fi

if [ "$(grep -c '^smtp_vip[0-9]\+ unix' "${MOCK_T7}/etc/postfix/master.cf")" -eq 1 ]; then
    pass "OUTBOUND_VIP produced exactly 1 master.cf transport"
else
    fail "OUTBOUND_VIP produced incorrect transport count"
fi

# ------------------------------------------------------------------------------
# Test 8: HAProxy Inbound PROXY Protocol Configuration
# ------------------------------------------------------------------------------
echo ""
echo "Test 8: HAProxy Inbound PROXY Protocol Configuration..."
MOCK_T8="${TEST_DIR}/test8"
ENABLE_HAPROXY_PROXY_PROTOCOL="true" \
OUTBOUND_VIP_1="10.10.10.101" \
run_vip_resolution_harness "${MOCK_T8}"

if grep -q "smtpd_upstream_proxy_protocol = haproxy" "${MOCK_T8}/postconf.record" && \
   grep -q "smtpd_upstream_proxy_timeout = 5s" "${MOCK_T8}/postconf.record"; then
    pass "ENABLE_HAPROXY_PROXY_PROTOCOL=true properly sets smtpd_upstream_proxy_protocol = haproxy"
else
    fail "ENABLE_HAPROXY_PROXY_PROTOCOL=true failed to set proxy protocol parameter"
fi

echo "================================================================================"
echo " Test Summary: ${PASS_COUNT} Passed, ${FAIL_COUNT} Failed"
echo "================================================================================"

if [ "${FAIL_COUNT}" -eq 0 ]; then
    exit 0
else
    exit 1
fi
