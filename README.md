# Production Postfix Multi-VIP HA Mail Relay & OpenDKIM (RHEL 9)

High-availability **Postfix + OpenDKIM** outbound mail server designed for **Red Hat Enterprise Linux 9 (RHEL 9)** behind a hardware firewall with **dynamic 1-to-1 NAT Outbound VIPs** and **1 Inbound VIP** managed by **Keepalived**.

Built for high-deliverability **OTP** and transactional emails to **Google (Gmail), Yahoo, Microsoft Outlook / Office 365**, and custom partner MX relays.

---

## Key Features

1. **Keepalived HA VIPs (Active/Backup HA on RHEL 9)**:
   - **1 Inbound VIP (`INBOUND_VIP`)**: Internal application servers connect here to submit mail.
   - **Dynamic Outbound VIPs (`OUTBOUND_VIP_1`..`N`)**: Mapped 1-to-1 on the hardware firewall to Public IPs. Postfix distributes outbound mail across all active VIPs via `randmap` round-robin by default (or directly if 1 VIP is configured), with optional sender-to-VIP pinning (`SENDER_VIP_MAPPINGS`).
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
6. **Full Inbound & Outbound TLS / STARTTLS**:
   - **Inbound (`smtpd_tls_security_level=may`)**: Full STARTTLS support for client mail submissions. Automatic self-signed SAN certificate generation fallback (`AUTO_GENERATE_TLS_CERT=true`) or custom SSL certificates mounted from `./certs/` (`tls.crt`, `tls.key`).
   - **Outbound (`smtp_tls_security_level=may`)**: Opportunistic STARTTLS to external providers (Google, Yahoo, Outlook).

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
   - `INBOUND_VIP` and `OUTBOUND_VIP_1`..`N` + `OUTBOUND_VIP_1_HELO`..`N_HELO` (scale up or down freely)
   - `ALLOWED_NETWORKS` and `ALLOWED_SENDERS`
   - `TRANSPORT_MAPS` (or create `config/transport` from `config/transport.example`)
   - Timeouts and queue lifetimes (`SMTP_CONNECT_TIMEOUT`, `MAXIMAL_QUEUE_LIFETIME`, etc.)

2. **Build and Start with Docker Compose**:
   ```bash
   mkdir -p logs dkim spool certs
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

## Inbound TLS & STARTTLS Support

Postfix supports inbound opportunistic encryption via **STARTTLS** on port 25, 587, or custom ports (e.g., 2525).

### 1. Zero-Touch Automatic Certificate Generation
If no certificates are found in `./certs/`, the container automatically generates a 2048-bit RSA self-signed TLS certificate with Subject Alternative Names (SAN) for:
- `MYHOSTNAME` (e.g., `mail.company.com`)
- `MAIL_DOMAIN` (e.g., `company.com`)
- `*.MAIL_DOMAIN` (wildcard)
- `localhost` and `127.0.0.1`
- `INBOUND_VIP` (if defined)

The generated certificate and key persist in `./certs/tls.crt` and `./certs/tls.key` across container restarts.

### 2. Using Custom or Production SSL Certificates (Let's Encrypt / Corporate CA)
Simply copy your PEM certificate and private key into `./certs/`:
```bash
cp /path/to/fullchain.pem certs/tls.crt
cp /path/to/privkey.pem certs/tls.key
chmod 0644 certs/tls.crt
chmod 0640 certs/tls.key
docker compose restart postfix-relay
```

### 3. Testing STARTTLS Verification
You can verify STARTTLS advertisement, handshake, and encrypted mail delivery using the included test script:
```bash
# Syntax: ./scripts/test-starttls.sh <HOST> <PORT> [RECIPIENT] [SENDER]
./scripts/test-starttls.sh 127.0.0.1 2525 test@example.com otp@company.com
```

Or manually with OpenSSL:
```bash
openssl s_client -starttls smtp -crlf -connect 127.0.0.1:2525
```

---

## Dynamic Outbound VIP Scaling (Scale Up or Down)

The number of outbound VIPs is **completely dynamic**. You do not need to modify any code or scripts to change the number of outbound VIPs.

### 1. Scaling Down (e.g. 2 VIPs)
In `.env`, simply configure `OUTBOUND_VIP_1` and `OUTBOUND_VIP_2`, and omit or comment out 3+:
```ini
OUTBOUND_VIP_1=10.10.10.101
OUTBOUND_VIP_1_HELO=mail1.company.com
OUTBOUND_VIP_2=10.10.10.102
OUTBOUND_VIP_2_HELO=mail2.company.com
```
Postfix will automatically:
- Create transports `smtp_vip1` and `smtp_vip2` in `master.cf`.
- Set `default_transport = smtp` and `sender_dependent_default_transport_maps = randmap:{smtp_vip1:,smtp_vip2:}` in `main.cf`.
- Authorize only `10.10.10.101` and `10.10.10.102` in OpenDKIM `TrustedHosts`.

### 2. Scaling Up (e.g. 8 VIPs)
Simply append additional numbered variables in `.env`:
```ini
OUTBOUND_VIP_6=10.10.10.106
OUTBOUND_VIP_6_HELO=mail6.company.com
OUTBOUND_VIP_7=10.10.10.107
OUTBOUND_VIP_7_HELO=mail7.company.com
OUTBOUND_VIP_8=10.10.10.108
OUTBOUND_VIP_8_HELO=mail8.company.com
```
Postfix will automatically generate `smtp_vip1` through `smtp_vip8` and balance across all 8 VIPs:
`sender_dependent_default_transport_maps = randmap:{smtp_vip1:,smtp_vip2:,smtp_vip3:,smtp_vip4:,smtp_vip5:,smtp_vip6:,smtp_vip7:,smtp_vip8:}`.

### 3. Single VIP Mode (1 VIP)
If only `OUTBOUND_VIP_1` (or `OUTBOUND_VIP`) is defined, Postfix sets `default_transport = smtp_vip1` directly without `randmap`.

### 4. Keepalived Host Configuration Note
When scaling VIPs up or down, update `/etc/keepalived/keepalived.conf` on both RHEL 9 nodes so Keepalived assigns the matching VIP addresses to the network interface:
```text
    virtual_ipaddress {
        10.10.10.100/24 dev ens192 label ens192:in_vip
        10.10.10.101/24 dev ens192 label ens192:nat_vip1
        10.10.10.102/24 dev ens192 label ens192:nat_vip2
        # Add nat_vip3..nat_vipN as appropriate
    }
```
Reload Keepalived on both nodes:
```bash
sudo systemctl reload keepalived
```

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
  "timestamp": "2026-11-12T15:00:05.412091+07:00",
  "first_seen": "Nov 12 15:00:04",
  "last_seen": "Nov 12 15:00:05",
  "queue_id": "4X9z1B2c3d4e",
  "client_ip": "10.10.10.50",
  "client_hostname": "app01.internal.company.com",
  "from": "otp@company.com",
  "to": "user@gmail.com",
  "cc": "audit@company.com",
  "message_id": "<otp-1731301204@company.com>",
  "size": 1420,
  "subject": "[OTP] Your verification code is 849201",
  "status": "sent",
  "dsn": "2.0.0",
  "smtp_response": "250 2.0.0 OK 1731301205-g2",
  "vip": "vip2",
  "vip_ip": "10.10.10.102"
}
```

---

## Production Best Practices for Gmail, Yahoo & Outlook Deliverability

1. **Forward-Confirmed Reverse DNS (FCrDNS) for All Outbound NAT Public IPs**:
   Every outbound VIP (`OUTBOUND_VIP_1`..`N`) is NATed 1-to-1 by your hardware firewall to a Public IP (`Public_IP_1`..`N`). Ensure your ISP / DNS provider configures matching `A` and `PTR` records for all configured Public IPs:
   - `Public_IP_1` $\leftrightarrow$ `mail1.company.com` (`OUTBOUND_VIP_1_HELO=mail1.company.com`)
   - `Public_IP_2` $\leftrightarrow$ `mail2.company.com` (`OUTBOUND_VIP_2_HELO=mail2.company.com`)
   - `Public_IP_3` $\leftrightarrow$ `mail3.company.com` (`OUTBOUND_VIP_3_HELO=mail3.company.com`)
   - ... (and so on for all active VIPs)

2. **Required DNS Records on `company.com` (SPF, DKIM, DMARC)**:
   - **SPF TXT Record (`company.com`)**: Include all active outbound public IPs:
     ```text
     v=spf1 ip4:<Public_IP_1> ip4:<Public_IP_2> ... ip4:<Public_IP_N> -all
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
   Register your domain and all active public NAT IPs with:
   - **Google Postmaster Tools** (`postmaster.google.com`)
   - **Microsoft SNDS & JMRP** (`sendersupport.olc.protection.outlook.com/snds/`)
   - **Yahoo Sender Hub** (`senders.yahooinc.com`)

---

## HAProxy Deployment & PROXY Protocol

When placing Postfix behind HAProxy with `send-proxy` (or `send-proxy-v2`) to preserve the original client IP address, enable the proxy protocol in `.env`:
```ini
ENABLE_HAPROXY_PROXY_PROTOCOL=true
```

This sets `smtpd_upstream_proxy_protocol = haproxy` and `smtpd_upstream_proxy_timeout = 5s` in Postfix `main.cf`. This ensures Postfix waits for the PROXY header before sending the `220` SMTP banner, eliminating `improper command pipelining` errors and allowing access control checks (`mynetworks`) and loggers to see the actual client IP.

See [config/haproxy.cfg.example](file:///home/mbattle/mailserver/config/haproxy.cfg.example) for a complete HAProxy configuration example.

---

## Consolidated Log Lowercase Email Normalization

The Queue-ID log consolidator daemon (`postfix-log-consolidator.py`) automatically normalizes all email addresses (`from`, `to`, `cc`) to lowercase when writing JSON records to `/var/log/postfix-consolidate.log`. Multiple recipients are deduplicated case-insensitively, ensuring consistent and predictable queries for analytics and SIEM indexing.
