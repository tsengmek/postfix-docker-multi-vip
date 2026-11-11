# Production Postfix Multi-VIP HA Mail Relay & OpenDKIM (RHEL 9)

High-availability **Postfix + OpenDKIM** outbound mail server designed for **Red Hat Enterprise Linux 9 (RHEL 9)** behind a hardware firewall with **5 1-to-1 NAT Public IPs** and **1 Inbound VIP** managed by **Keepalived**.

Built for high-deliverability **OTP** and transactional emails to **Google (Gmail), Yahoo, Microsoft Outlook / Office 365**, and custom partner MX relays.

---

## Key Features

1. **6 Keepalived VIPs (Active/Backup HA on RHEL 9)**:
   - **1 Inbound VIP (`INBOUND_VIP`)**: Internal application servers connect here to submit mail.
   - **5 Outbound VIPs (`OUTBOUND_VIP_1`..`5`)**: Mapped 1-to-1 on the hardware firewall to 5 Public IPs. Postfix distributes outbound mail across all 5 VIPs via `randmap` round-robin by default, with optional sender-to-VIP pinning (`SENDER_VIP_MAPPINGS`).
2. **Strict Access Control**:
   - **Network Whitelist (`ALLOWED_NETWORKS`)**: Only permitted internal subnets (`mynetworks`) can connect.
   - **Sender Email Whitelist (`ALLOWED_SENDERS`)**: Only explicitly listed sender addresses (e.g., `otp@company.com`, `notification@company.com`) are allowed in `MAIL FROM`. Unauthorized senders are immediately rejected with `554 5.7.1`.
3. **Destination Domain Transport Maps (`TRANSPORT_MAPS`)**:
   - Forward specific destination domains (e.g., `partner.com`, `internal.company.com`) to specific MX/SMTP servers via `.env` (`TRANSPORT_MAPS`) or `config/transport`.
4. **Automated 2048-bit OpenDKIM Signing**:
   - Automatically generates and signs outgoing mail for `company.com` (`rsa-sha256`).
5. **Persistent Raw & Single-Line JSON Consolidated Logs + Daily Rotation**:
   - `/var/log/maillog` (persisted on host at `./logs/maillog`): Raw Postfix & OpenDKIM log.
   - `/var/log/postfix-consolidate.log` (persisted on host at `./logs/postfix-consolidate.log`): Consolidates all log events and **email headers** (`Subject`, `From`, `To`, `Date`, `Message-ID`, `X-*`) for each `queue-id` into a **single-line JSON record**.
   - **Daily Rotation**: Rotated daily via `logrotate` with configurable retention (`LOG_RETENTION_DAYS=30`).

---

## Step-by-Step Deployment on RHEL 9

### Step 1: Prepare Both RHEL 9 Nodes (Master & Backup)

1. **Disable the default RHEL 9 host Postfix service** (since our Docker container uses `network_mode: host` and binds directly to port 25):
   ```bash
   sudo systemctl stop postfix || true
   sudo systemctl disable postfix || true
   ```

2. **Enable `ip_nonlocal_bind` in the RHEL 9 kernel** (allows Postfix to bind to all 6 VIPs even when Keepalived is in `BACKUP` state):
   ```bash
   sudo cp keepalived/99-mailserver-sysctl.conf /etc/sysctl.d/99-mailserver-sysctl.conf
   sudo sysctl --system
   ```

3. **Configure RHEL 9 `firewalld`** (allow SMTP port 25 and VRRP heartbeat between the two nodes):
   ```bash
   sudo firewall-cmd --permanent --add-service=smtp
   sudo firewall-cmd --permanent --add-rich-rule='rule protocol value="vrrp" accept'
   sudo firewall-cmd --reload
   ```

---

### Step 2: Install & Configure Keepalived on RHEL 9

1. **Install Keepalived**:
   ```bash
   sudo dnf install -y keepalived nmap-ncat iproute
   ```

2. **Copy Configuration & Scripts**:
   - On **Node 1 (MASTER)**:
     ```bash
     sudo cp keepalived/keepalived-master.conf /etc/keepalived/keepalived.conf
     ```
   - On **Node 2 (BACKUP)**:
     ```bash
     sudo cp keepalived/keepalived-backup.conf /etc/keepalived/keepalived.conf
     ```
   - Edit `/etc/keepalived/keepalived.conf` on both nodes to set your interface name (e.g., `ens192`), node IPs (`unicast_src_ip` / `unicast_peer`), and the 6 VIPs.

3. **Install Health Check & Notify Scripts (with SELinux context)**:
   ```bash
   sudo cp keepalived/check_postfix.sh /etc/keepalived/check_postfix.sh
   sudo cp keepalived/notify.sh /etc/keepalived/notify.sh
   sudo chmod 0755 /etc/keepalived/check_postfix.sh /etc/keepalived/notify.sh
   sudo chown root:root /etc/keepalived/check_postfix.sh /etc/keepalived/notify.sh
   # Restore SELinux labels on RHEL 9 so keepalived_t can execute the scripts:
   sudo restorecon -Rv /etc/keepalived
   ```

4. **Enable & Start Keepalived**:
   ```bash
   sudo systemctl enable --now keepalived
   ip addr show
   ```

---

### Step 3: Configure `.env` & Start the Mail Server Container

1. **Edit `.env`**:
   ```bash
   vi .env
   ```
   Adjust:
   - `MAIL_DOMAIN=company.com` and `MYHOSTNAME=mail.company.com`
   - `INBOUND_VIP` and `OUTBOUND_VIP_1`..`5` + `OUTBOUND_VIP_1_HELO`..`5_HELO`
   - `ALLOWED_NETWORKS` and `ALLOWED_SENDERS`
   - `TRANSPORT_MAPS` (or create `config/transport` from `config/transport.example`)
   - Timeouts and queue lifetimes (`SMTP_CONNECT_TIMEOUT`, `MAXIMAL_QUEUE_LIFETIME`, etc.)

2. **Build and Start with Docker Compose**:
   ```bash
   mkdir -p logs dkim spool
   docker compose up -d --build
   ```

3. **Retrieve the Auto-Generated 2048-bit DKIM Public Key**:
   ```bash
   docker compose logs postfix-relay | grep -A 10 "DKIM DNS TXT Record"
   # Or view directly on the host:
   cat dkim/company.com/mail.txt
   ```
   Copy the generated key from `./dkim/company.com/` to the Backup RHEL 9 node so both nodes sign with the identical DKIM private key.

---

## Destination Domain Transport Maps (`transport_maps`)

You can route specific destination domains to custom SMTP/MX servers in two ways (both are merged automatically on startup):

1. **Via `.env` (`TRANSPORT_MAPS`)**:
   ```ini
   TRANSPORT_MAPS=partner.com=smtp:[203.0.113.55]:25,internal.company.com=smtp:[10.20.30.10]:2525
   ```
2. **Via `config/transport` file**:
   ```bash
   cp config/transport.example config/transport
   vi config/transport
   docker compose restart postfix-relay
   ```

---

## Persistent Logs & Consolidated JSON Format

Both log files are available inside the container at `/var/log/maillog` and `/var/log/postfix-consolidate.log`, and persisted on the RHEL 9 host inside `./logs/`:

| Log File (Container) | Host Path | Description |
| :--- | :--- | :--- |
| `/var/log/maillog` | `./logs/maillog` | Raw Postfix (`smtpd`, `cleanup`, `qmgr`, `smtp/vip1..5`) & OpenDKIM log |
| `/var/log/postfix-consolidate.log` | `./logs/postfix-consolidate.log` | One consolidated JSON line per `queue_id` (including email headers) |

### Example Consolidated JSON Line (`/var/log/postfix-consolidate.log`)
```json
{
  "timestamp": "2026-11-11T12:00:05.412091+07:00",
  "first_seen": "2026-11-11T12:00:04+07:00",
  "last_seen": "2026-11-11T12:00:05+07:00",
  "queue_id": "4X9z1B2c3d4e",
  "hostname": "mail.company.com",
  "client_ip": "10.10.10.50",
  "client_hostname": "app01.internal.company.com",
  "helo": "app01.internal.company.com",
  "from": "otp@company.com",
  "to": ["user@gmail.com"],
  "message_id": "<otp-1731301204@company.com>",
  "size": 1420,
  "nrcpt": 1,
  "headers": {
    "From": "Company OTP Service <otp@company.com>",
    "To": "<user@gmail.com>",
    "Subject": "[OTP] Your verification code is 849201",
    "Date": "Wed, 11 Nov 2026 12:00:04 +0700",
    "Message-ID": "<otp-1731301204@company.com>",
    "X-Request-ID": "otp-1731301204",
    "X-Application": "auth-service",
    "DKIM-Signature": "v=1; a=rsa-sha256; c=relaxed/simple; d=company.com; s=mail; ..."
  },
  "dkim_signed": true,
  "dkim_domain": "company.com",
  "dkim_selector": "mail",
  "transport": "postfix/vip2/smtp",
  "relay": "gmail-smtp-in.l.google.com[142.250.4.26]:25",
  "dsn": "2.0.0",
  "status": "sent",
  "smtp_response": "250 2.0.0 OK 1731301205-g2",
  "delay_total": 0.68,
  "delays": "0.02/0.01/0.24/0.41",
  "deliveries": [
    {
      "to": "user@gmail.com",
      "transport": "postfix/vip2/smtp",
      "relay": "gmail-smtp-in.l.google.com[142.250.4.26]:25",
      "dsn": "2.0.0",
      "status": "sent",
      "delay": 0.68,
      "delays": "0.02/0.01/0.24/0.41",
      "smtp_response": "250 2.0.0 OK 1731301205-g2"
    }
  ],
  "raw_messages": [
    "postfix/smtpd: client=app01.internal.company.com[10.10.10.50]",
    "postfix/cleanup: message-id=<otp-1731301204@company.com>",
    "postfix/cleanup: info: header Subject: [OTP] Your verification code is 849201 from app01.internal.company.com[10.10.10.50]; from=<otp@company.com> to=<user@gmail.com> proto=ESMTP helo=<app01.internal.company.com>",
    "postfix/cleanup: info: header DKIM-Signature: v=1; a=rsa-sha256; c=relaxed/simple; d=company.com; s=mail; ...",
    "postfix/qmgr: from=<otp@company.com>, size=1420, nrcpt=1 (queue active)",
    "postfix/vip2/smtp: to=<user@gmail.com>, relay=gmail-smtp-in.l.google.com[142.250.4.26]:25, delay=0.68, delays=0.02/0.01/0.24/0.41, dsn=2.0.0, status=sent (250 2.0.0 OK 1731301205-g2)",
    "postfix/qmgr: removed"
  ]
}
```

---

## Production Best Practices for Gmail, Yahoo & Outlook Deliverability

1. **Forward-Confirmed Reverse DNS (FCrDNS) for All 5 NAT Public IPs**:
   Every outbound VIP (`OUTBOUND_VIP_1`..`5`) is NATed 1-to-1 by your hardware firewall to a Public IP (`Public_IP_1`..`5`). Ensure your ISP / DNS provider configures matching `A` and `PTR` records for all 5 Public IPs:
   - `Public_IP_1` $\leftrightarrow$ `mail1.company.com` (`OUTBOUND_VIP_1_HELO=mail1.company.com`)
   - `Public_IP_2` $\leftrightarrow$ `mail2.company.com` (`OUTBOUND_VIP_2_HELO=mail2.company.com`)
   - `Public_IP_3` $\leftrightarrow$ `mail3.company.com` (`OUTBOUND_VIP_3_HELO=mail3.company.com`)
   - `Public_IP_4` $\leftrightarrow$ `mail4.company.com` (`OUTBOUND_VIP_4_HELO=mail4.company.com`)
   - `Public_IP_5` $\leftrightarrow$ `mail5.company.com` (`OUTBOUND_VIP_5_HELO=mail5.company.com`)

2. **Required DNS Records on `company.com` (SPF, DKIM, DMARC)**:
   - **SPF TXT Record (`company.com`)**:
     ```text
     v=spf1 ip4:<Public_IP_1> ip4:<Public_IP_2> ip4:<Public_IP_3> ip4:<Public_IP_4> ip4:<Public_IP_5> -all
     ```
   - **DKIM TXT Record (`mail._domainkey.company.com`)**:
     Publish the 2048-bit key output in `./dkim/company.com/mail.txt`.
   - **DMARC TXT Record (`_dmarc.company.com`)**:
     ```text
     v=DMARC1; p=quarantine; adkim=s; aspf=s; rua=mailto:dmarc-reports@company.com; pct=100
     ```

3. **Separate OTP VIP Pool from Bulk Notification VIP Pool**:
   To ensure a burst of marketing/system notifications never slows down or affects the IP reputation of time-critical **OTP** emails, set `SENDER_VIP_MAPPINGS` in `.env`:
   ```ini
   SENDER_VIP_MAPPINGS=otp@company.com:randmap:{smtp_vip1,smtp_vip2},notification@company.com:randmap:{smtp_vip3,smtp_vip4,smtp_vip5}
   ```
   This dedicates VIPs 1 & 2 exclusively to `otp@company.com` and VIPs 3, 4 & 5 to `notification@company.com`.

4. **External Postmaster Registration**:
   Register your domain and all 5 public NAT IPs with:
   - **Google Postmaster Tools** (`postmaster.google.com`)
   - **Microsoft SNDS & JMRP** (`sendersupport.olc.protection.outlook.com/snds/`)
   - **Yahoo Sender Hub** (`senders.yahooinc.com`)
