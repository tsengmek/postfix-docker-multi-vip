#!/usr/bin/env bash
# ==============================================================================
# Keepalived Health Check Script for Postfix HA Relay
# Install path: /etc/keepalived/check_postfix.sh (chmod 755, chown root:root)
# Returns 0 if Postfix is listening on TCP port 25 and container is healthy.
# ==============================================================================
set -e

# 1. Check that TCP port 25 is accepting connections on localhost
if command -v ss >/dev/null 2>&1; then
    ss -tln | grep -qE ':25\s'
else
    nc -z -w 2 127.0.0.1 25
fi

# 2. Verify postfix master process is running on the host (container runs in host pid/net or visible via pgrep)
pgrep -x master >/dev/null 2>&1 || docker inspect -f '{{.State.Running}}' postfix-relay 2>/dev/null | grep -q true
