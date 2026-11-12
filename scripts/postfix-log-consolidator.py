#!/usr/bin/env python3
"""
Postfix Queue-ID JSON Log Consolidator Daemon
Tails /var/log/maillog in real time, correlates all Postfix (smtpd, cleanup, qmgr,
smtp/vip1..5, bounce) and OpenDKIM log entries + logged email headers by Queue-ID,
and writes one consolidated single-line JSON record per Queue-ID to
/var/log/postfix-consolidate.log.

Handles daily logrotate seamlessly via inode & truncation tracking.
"""

import argparse
import datetime
import json
import os
import re
import signal
import sys
import time
from typing import Dict, Any, Optional

# Match both traditional syslog ("Nov 11 11:45:01 host ...") and ISO8601 ("2026-11-11T11:45:01+07:00 host ...")
LOG_LINE_RE = re.compile(
    r"^(?P<ts>(?:[A-Z][a-z]{2}\s+\d+\s+\d{2}:\d{2}:\d{2}|\d{4}-\d{2}-\d{2}T\S+))\s+"
    r"(?P<host>\S+)\s+"
    r"(?P<proc>[a-zA-Z0-9_/\-]+)(?:\[(?P<pid>\d+)\])?:\s+"
    r"(?P<msg>.*)$"
)

# Queue ID: Postfix standard hex (10-12 chars) or Postfix long queue ID (14+ alphanumeric)
QUEUE_ID_RE = re.compile(
    r"^(?P<qid>[0-9A-F]{8,15}|[0-9A-Za-z]{12,22}):\s+(?P<rest>.*)$"
)

NOQUEUE_RE = re.compile(
    r"^NOQUEUE:\s+reject:\s+(?P<rest>.*)$"
)

CLIENT_RE = re.compile(r"client=(?P<chost>[^\[]+)\[(?P<cip>[^\]]+)\]")
MESSAGE_ID_RE = re.compile(r"message-id=<(?P<msgid>[^>]*)>")
QMGR_FROM_RE = re.compile(
    r"from=<(?P<sender>[^>]*)>,\s*size=(?P<size>\d+),\s*nrcpt=(?P<nrcpt>\d+)"
)
# Cleanup header_checks INFO format:
# info: header Subject: Your OTP is 123456 from app1[10.10.10.50]; from=<otp@company.com> to=<u@gmail.com> proto=ESMTP helo=<app1>
HEADER_INFO_RE = re.compile(
    r"^(?:info|warning):\s+header\s+(?P<hname>[A-Za-z0-9\-]+):\s*(?P<hval>.*?)"
    r"(?:\s+from\s+(?P<chost>[^\[]+)\[(?P<cip>[^\]]+)\];"
    r"(?:\s+from=<(?P<env_from>[^>]*)>)?"
    r"(?:\s+to=<(?P<env_to>[^>]*)>)?\s+proto=(?P<proto>\S+)"
    r"(?:\s+helo=<(?P<helo>[^>]*)>)?|$)"
)
# Delivery line (smtp, error, bounce, local, virtual)
DELIVERY_RE = re.compile(
    r"to=<(?P<to>[^>]*)>,\s*"
    r"(?:orig_to=<(?P<orig_to>[^>]*)>,\s*)?"
    r"relay=(?P<relay>[^,]+),\s*"
    r"(?:conn_use=\d+,\s*)?"
    r"delay=(?P<delay>[0-9.]+),\s*"
    r"(?:delays=(?P<delays>[0-9./]+),\s*)?"
    r"(?:dsn=(?P<dsn>[0-9.]+),\s*)?"
    r"status=(?P<status>\S+)\s*"
    r"(?:\((?P<resp>.*)\))?"
)
OPENDKIM_RE = re.compile(
    r"DKIM-Signature field added\s*\(s=(?P<selector>[^,\s]+),\s*d=(?P<domain>[^\)\s]+)\)"
)
DKIM_HDR_RE = re.compile(
    r"\bd=(?P<domain>[^;\s]+).*?\bs=(?P<selector>[^;\s]+)|\bs=(?P<selector2>[^;\s]+).*?\bd=(?P<domain2>[^;\s]+)"
)

VIP_PROC_RE = re.compile(
    r"(?:postfix/)?(?:vip(?P<v1>[a-zA-Z0-9_-]+)/smtp|smtp_vip(?P<v2>[a-zA-Z0-9_-]+)|vip(?P<v3>[a-zA-Z0-9_-]+))"
)


class QueueConsolidator:
    def __init__(self, output_path: str, timeout_sec: int = 300):
        self.output_path = output_path
        self.timeout_sec = timeout_sec
        self.inflight: Dict[str, Dict[str, Any]] = {}
        self.running = True
        self.vip_map = self._load_vip_map()

    @staticmethod
    def _load_vip_map() -> Dict[str, str]:
        vm = {}
        for k, v in os.environ.items():
            m = re.match(r"^OUTBOUND_VIP_(\w+)$", k)
            if m and v:
                idx = m.group(1).lower()
                vm[f"vip{idx}"] = v
                vm[idx] = v
                vm[f"smtp_vip{idx}"] = v
        return vm

    def now_iso(self) -> str:
        return datetime.datetime.now(datetime.timezone.utc).astimezone().isoformat()

    def get_or_create(self, qid: str, ts: str, host: str) -> Dict[str, Any]:
        if qid not in self.inflight:
            self.inflight[qid] = {
                "first_seen": ts,
                "last_seen": ts,
                "queue_id": qid,
                "client_ip": None,
                "client_hostname": None,
                "from": None,
                "to": [],
                "cc": None,
                "message_id": None,
                "size": None,
                "subject": None,
                "status": "in_progress",
                "dsn": None,
                "smtp_response": None,
                "vip": None,
                "vip_ip": None,
                "_updated_at": time.time(),
            }
        rec = self.inflight[qid]
        rec["last_seen"] = ts
        rec["_updated_at"] = time.time()
        return rec

    def emit_json(self, record: Dict[str, Any]) -> None:
        to_val: Optional[str] = None
        if record.get("to"):
            if isinstance(record["to"], list):
                seen = set()
                deduped = []
                for addr in record["to"]:
                    if addr and addr not in seen:
                        seen.add(addr)
                        deduped.append(addr)
                to_val = ", ".join(deduped) if deduped else None
            else:
                to_val = str(record["to"])

        out = {
            "timestamp": self.now_iso(),
            "first_seen": record.get("first_seen"),
            "last_seen": record.get("last_seen"),
            "queue_id": record.get("queue_id"),
            "client_ip": record.get("client_ip"),
            "client_hostname": record.get("client_hostname"),
            "from": record.get("from"),
            "to": to_val,
            "cc": record.get("cc"),
            "message_id": record.get("message_id"),
            "size": record.get("size"),
            "subject": record.get("subject"),
            "status": record.get("status"),
            "dsn": record.get("dsn"),
            "smtp_response": record.get("smtp_response"),
            "vip": record.get("vip"),
            "vip_ip": record.get("vip_ip"),
        }
        os.makedirs(os.path.dirname(os.path.abspath(self.output_path)), exist_ok=True)
        with open(self.output_path, "a", encoding="utf-8") as f:
            f.write(json.dumps(out, ensure_ascii=False) + "\n")
            f.flush()

    def process_line(self, line: str) -> None:
        line = line.rstrip("\r\n")
        if not line:
            return

        m = LOG_LINE_RE.match(line)
        if not m:
            return

        ts = m.group("ts")
        host = m.group("host")
        proc = m.group("proc")
        msg = m.group("msg")

        # Check for NOQUEUE rejections
        nq = NOQUEUE_RE.match(msg)
        if nq:
            rest = nq.group("rest")
            rec = {
                "first_seen": ts,
                "last_seen": ts,
                "queue_id": "NOQUEUE",
                "client_ip": None,
                "client_hostname": None,
                "from": None,
                "to": [],
                "cc": None,
                "message_id": None,
                "size": None,
                "subject": None,
                "status": "rejected",
                "dsn": None,
                "smtp_response": rest,
                "vip": None,
                "vip_ip": None,
            }
            cm = re.search(r"from\s+([^\[]+)\[([^\]]+)\]", rest)
            if cm:
                rec["client_hostname"] = cm.group(1)
                rec["client_ip"] = cm.group(2)
            fm = re.search(r"from=<([^>]*)>", rest)
            if fm:
                rec["from"] = fm.group(1)
            tm = re.search(r"to=<([^>]*)>", rest)
            if tm:
                rec["to"] = [tm.group(1)]
            dm = re.search(r"\b([45]\.\d+\.\d+)\b", rest)
            if dm:
                rec["dsn"] = dm.group(1)
            self.emit_json(rec)
            return

        qm = QUEUE_ID_RE.match(msg)
        if not qm:
            return

        qid = qm.group("qid")
        rest = qm.group("rest")
        rec = self.get_or_create(qid, ts, host)

        # 1. smtpd client connection
        cm = CLIENT_RE.search(rest)
        if cm:
            rec["client_hostname"] = cm.group("chost")
            rec["client_ip"] = cm.group("cip")

        # 2. cleanup message-id
        mid = MESSAGE_ID_RE.search(rest)
        if mid and not rec["message_id"]:
            rec["message_id"] = f"<{mid.group('msgid')}>"

        # 3. cleanup header_checks / milter_header_checks INFO lines
        hm = HEADER_INFO_RE.match(rest)
        if hm:
            hname = hm.group("hname").lower()
            hval = hm.group("hval").strip()
            if hname == "subject" and not rec["subject"]:
                rec["subject"] = hval
            elif hname == "cc" and not rec["cc"]:
                rec["cc"] = hval
            elif hname == "message-id" and not rec["message_id"]:
                rec["message_id"] = hval

            if hm.group("chost") and not rec["client_hostname"]:
                rec["client_hostname"] = hm.group("chost")
            if hm.group("cip") and not rec["client_ip"]:
                rec["client_ip"] = hm.group("cip")
            if hm.group("env_from") and not rec["from"]:
                rec["from"] = hm.group("env_from")
            if hm.group("env_to") and hm.group("env_to") not in rec["to"]:
                rec["to"].append(hm.group("env_to"))
            return

        # 4. qmgr from/size/nrcpt
        qfm = QMGR_FROM_RE.search(rest)
        if qfm:
            rec["from"] = qfm.group("sender")
            rec["size"] = int(qfm.group("size"))
            return

        # 5. smtp / delivery line
        dlv = DELIVERY_RE.search(rest)
        if dlv:
            to_addr = dlv.group("to")
            if to_addr and to_addr not in rec["to"]:
                rec["to"].append(to_addr)
            rec["dsn"] = dlv.group("dsn")
            rec["status"] = dlv.group("status")
            rec["smtp_response"] = dlv.group("resp")

            # Extract VIP from delivery process name (e.g. postfix/vip2/smtp)
            vm = VIP_PROC_RE.search(proc)
            if vm:
                vid = vm.group("v1") or vm.group("v2") or vm.group("v3")
                rec["vip"] = f"vip{vid}"
                rec["vip_ip"] = self.vip_map.get(f"vip{vid}") or self.vip_map.get(vid)

            # If message is deferred, emit a deferred snapshot immediately so operators see it right away
            if dlv.group("status") == "deferred":
                self.emit_json(rec)
            return

        # 6. qmgr removed -> final completion of queue_id lifecycle
        if rest.strip() == "removed":
            self.emit_json(rec)
            del self.inflight[qid]

    def flush_expired(self, force_all: bool = False) -> None:
        now = time.time()
        expired = [
            qid for qid, rec in self.inflight.items()
            if force_all or (now - rec["_updated_at"] >= self.timeout_sec)
        ]
        for qid in expired:
            rec = self.inflight.pop(qid)
            if rec["status"] == "in_progress":
                rec["status"] = "timeout_partial"
            self.emit_json(rec)


def tail_file(input_path: str, consolidator: QueueConsolidator, from_start: bool = False, once: bool = False) -> None:
    def handle_sig(signum, frame):
        consolidator.running = False

    signal.signal(signal.SIGTERM, handle_sig)
    signal.signal(signal.SIGINT, handle_sig)

    f: Optional[Any] = None
    current_inode: Optional[int] = None
    last_pos: int = 0
    last_flush = time.time()

    while consolidator.running:
        try:
            if not os.path.exists(input_path):
                if once:
                    break
                time.sleep(0.5)
                continue

            st = os.stat(input_path)
            # Detect file creation or inode change (logrotate create) or truncation (logrotate copytruncate)
            if f is None or current_inode != st.st_ino or st.st_size < last_pos:
                if f is not None:
                    try:
                        f.close()
                    except Exception:
                        pass
                f = open(input_path, "r", encoding="utf-8", errors="replace")
                current_inode = st.st_ino
                if not from_start and last_pos == 0 and not once:
                    f.seek(0, os.SEEK_END)
                last_pos = f.tell()

            line = f.readline()
            if line:
                last_pos = f.tell()
                consolidator.process_line(line)
            else:
                if once:
                    break
                now = time.time()
                if now - last_flush >= 10:
                    consolidator.flush_expired(force_all=False)
                    last_flush = now
                time.sleep(0.2)

        except Exception as exc:
            sys.stderr.write(f"[postfix-log-consolidator] Error: {exc}\n")
            time.sleep(1.0)

    if f is not None:
        try:
            f.close()
        except Exception:
            pass
    consolidator.flush_expired(force_all=True)


def main() -> None:
    parser = argparse.ArgumentParser(description="Consolidate Postfix logs by queue-id into single-line JSON.")
    parser.add_argument(
        "--input",
        default=os.environ.get("MAILLOG_PATH", "/var/log/maillog"),
        help="Path to raw Postfix maillog",
    )
    parser.add_argument(
        "--output",
        default=os.environ.get("CONSOLIDATED_LOG_PATH", "/var/log/postfix-consolidate.log"),
        help="Path to consolidated JSON output log",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=int(os.environ.get("CONSOLIDATE_QUEUE_TIMEOUT_SEC", "300")),
        help="Timeout in seconds before flushing incomplete queue IDs",
    )
    parser.add_argument(
        "--from-start",
        action="store_true",
        help="Read input log from the beginning of the file",
    )
    parser.add_argument(
        "--once",
        action="store_true",
        help="Process current file contents once and exit (for batch/testing)",
    )
    args = parser.parse_args()

    consolidator = QueueConsolidator(output_path=args.output, timeout_sec=args.timeout)
    tail_file(args.input, consolidator, from_start=args.from_start or args.once, once=args.once)


if __name__ == "__main__":
    main()
