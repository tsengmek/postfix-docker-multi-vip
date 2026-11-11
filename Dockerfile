FROM registry.access.redhat.com/ubi9/ubi:latest

LABEL maintainer="Infrastructure Team"
LABEL description="Production HA Postfix Multi-VIP Relay + OpenDKIM + JSON Log Consolidator for RHEL 9"

# Enable EPEL & CRB for opendkim and opendkim-tools on RHEL / UBI 9
RUN dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm && \
    (dnf config-manager --set-enabled ubi-9-codeready-builder || dnf config-manager --set-enabled crb || true) && \
    dnf install -y \
        postfix \
        postfix-pcre \
        opendkim \
        opendkim-tools \
        cyrus-sasl \
        cyrus-sasl-plain \
        ca-certificates \
        python3 \
        logrotate \
        cronie \
        iproute \
        nmap-ncat \
        procps-ng \
        tzdata \
        bind-utils && \
    dnf clean all && \
    rm -rf /var/cache/dnf

# Prepare runtime directories
RUN mkdir -p /var/log/mailserver \
             /etc/opendkim/keys \
             /etc/postfix/custom \
             /var/spool/postfix \
             /usr/local/bin

# Copy scripts and entrypoint
COPY scripts/postfix-log-consolidator.py /usr/local/bin/postfix-log-consolidator.py
COPY scripts/generate-dkim.sh /usr/local/bin/generate-dkim.sh
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh \
             /usr/local/bin/postfix-log-consolidator.py \
             /usr/local/bin/generate-dkim.sh

EXPOSE 25 587

ENTRYPOINT ["/entrypoint.sh"]
