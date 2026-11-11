#!/usr/bin/env bash
# ==============================================================================
# Keepalived State Transition Notify Script
# Install path: /etc/keepalived/notify.sh (chmod 755, chown root:root)
# ==============================================================================

TYPE="${1:-UNKNOWN}"
NAME="${2:-UNKNOWN}"
STATE="${3:-UNKNOWN}"

logger -t keepalived-mailserver "VRRP ${TYPE} ${NAME} transitioned to state: ${STATE}"

case "${STATE}" in
    MASTER)
        logger -t keepalived-mailserver "Node is now MASTER for all 6 VIPs. Flushing Postfix queue..."
        docker exec postfix-relay postfix flush >/dev/null 2>&1 || true
        ;;
    BACKUP|FAULT)
        logger -t keepalived-mailserver "Node is now ${STATE}."
        ;;
esac

exit 0
