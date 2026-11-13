#!/usr/bin/env python3
"""
Unit test suite verifying email address lowercase conversion in postfix-consolidate.log.
Tests:
  1. Envelope sender (from) with uppercase letters converted to lowercase.
  2. Envelope recipient (to) with uppercase letters converted to lowercase.
  3. Case-insensitive deduplication of multiple recipients (e.g. USER@domain.com and user@domain.com).
  4. Cc header with mixed-case addresses converted to lowercase.
  5. NOQUEUE rejections with uppercase from/to converted to lowercase.
"""

import importlib.util
import json
import os
import shutil
import tempfile
import unittest

module_path = os.path.join(os.path.dirname(__file__), "postfix-log-consolidator.py")
spec = importlib.util.spec_from_file_location("postfix_log_consolidator", module_path)
consolidator_mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(consolidator_mod)

QueueConsolidator = consolidator_mod.QueueConsolidator
normalize_email = consolidator_mod.normalize_email
normalize_header_emails = consolidator_mod.normalize_header_emails


class TestConsolidatorLowercase(unittest.TestCase):
    def setUp(self):
        self.test_dir = tempfile.mkdtemp()
        self.output_log = os.path.join(self.test_dir, "postfix-consolidate.log")
        self.consolidator = QueueConsolidator(output_path=self.output_log, timeout_sec=60)

    def tearDown(self):
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def test_normalize_email_helper(self):
        self.assertEqual(normalize_email("User.Name@Company.COM"), "user.name@company.com")
        self.assertEqual(normalize_email("  OTP@COMPANY.COM  "), "otp@company.com")
        self.assertIsNone(normalize_email(None))
        self.assertIsNone(normalize_email(""))

    def test_normalize_header_emails_helper(self):
        header_val = "Manager Name <Manager.One@Company.COM>, Boss <BOSS@COMPANY.COM>"
        expected = "Manager Name <manager.one@company.com>, Boss <boss@company.com>"
        self.assertEqual(normalize_header_emails(header_val), expected)

    def test_full_queue_lifecycle_with_uppercase_emails(self):
        qid = "4ABC123456"
        lines = [
            f"2026-11-13T10:00:00+07:00 mail.company.com postfix/smtpd[100]: connect from app01.internal[10.10.10.50]",
            f"2026-11-13T10:00:01+07:00 mail.company.com postfix/smtpd[100]: {qid}: client=app01.internal[10.10.10.50]",
            f"2026-11-13T10:00:02+07:00 mail.company.com postfix/cleanup[101]: {qid}: message-id=<req-001@company.com>",
            f"2026-11-13T10:00:02+07:00 mail.company.com postfix/cleanup[101]: {qid}: info: header Subject: OTP Code from app01.internal[10.10.10.50]; from=<OTP.Sender@Company.COM> to=<Client.User@GMAIL.COM> proto=ESMTP helo=<app01.internal>",
            f"2026-11-13T10:00:02+07:00 mail.company.com postfix/cleanup[101]: {qid}: info: header Cc: Supervisor <SUPERVISOR@Company.COM> from app01.internal[10.10.10.50]; proto=ESMTP",
            f"2026-11-13T10:00:03+07:00 mail.company.com postfix/qmgr[102]: {qid}: from=<OTP.Sender@Company.COM>, size=1520, nrcpt=1 (queue active)",
            f"2026-11-13T10:00:04+07:00 mail.company.com postfix/vip1/smtp[103]: {qid}: to=<Client.User@GMAIL.COM>, relay=mx.gmail.com[142.250.1.26]:25, delay=1.2, delays=0.1/0.01/0.5/0.6, dsn=2.0.0, status=sent (250 2.0.0 OK)",
            f"2026-11-13T10:00:05+07:00 mail.company.com postfix/qmgr[102]: {qid}: removed",
        ]

        for line in lines:
            self.consolidator.process_line(line)

        self.assertTrue(os.path.exists(self.output_log))
        with open(self.output_log, "r", encoding="utf-8") as f:
            log_entries = [json.loads(l) for l in f if l.strip()]

        self.assertEqual(len(log_entries), 1)
        record = log_entries[0]

        # Verify email addresses were converted to lowercase in the consolidated log
        self.assertEqual(record["from"], "otp.sender@company.com")
        self.assertEqual(record["to"], "client.user@gmail.com")
        self.assertEqual(record["cc"], "Supervisor <supervisor@company.com>")
        self.assertEqual(record["status"], "sent")
        self.assertEqual(record["vip"], "vip1")

    def test_case_insensitive_recipient_deduplication(self):
        qid = "5DEF789012"
        lines = [
            f"2026-11-13T10:05:00+07:00 mail.company.com postfix/smtpd[100]: {qid}: client=app01.internal[10.10.10.50]",
            f"2026-11-13T10:05:01+07:00 mail.company.com postfix/cleanup[101]: {qid}: info: header Subject: Multi-recipient; from=<ALERT@Company.COM> to=<User.One@GMAIL.COM> proto=ESMTP",
            f"2026-11-13T10:05:02+07:00 mail.company.com postfix/qmgr[102]: {qid}: from=<alert@company.com>, size=800, nrcpt=2",
            # First delivery log has uppercase
            f"2026-11-13T10:05:03+07:00 mail.company.com postfix/smtp[103]: {qid}: to=<User.One@GMAIL.COM>, relay=mx.gmail.com:25, delay=0.5, status=sent",
            # Second delivery log has lowercase for same recipient (should dedup)
            f"2026-11-13T10:05:04+07:00 mail.company.com postfix/smtp[103]: {qid}: to=<user.one@gmail.com>, relay=mx.gmail.com:25, delay=0.5, status=sent",
            # Third delivery log has distinct recipient
            f"2026-11-13T10:05:05+07:00 mail.company.com postfix/smtp[103]: {qid}: to=<User.TWO@Company.COM>, relay=mx.company.com:25, delay=0.5, status=sent",
            f"2026-11-13T10:05:06+07:00 mail.company.com postfix/qmgr[102]: {qid}: removed",
        ]

        for line in lines:
            self.consolidator.process_line(line)

        with open(self.output_log, "r", encoding="utf-8") as f:
            records = [json.loads(l) for l in f if l.strip()]

        self.assertEqual(len(records), 1)
        rec = records[0]
        # Should be deduplicated into user.one@gmail.com and user.two@company.com
        self.assertEqual(rec["from"], "alert@company.com")
        self.assertEqual(rec["to"], "user.one@gmail.com, user.two@company.com")

    def test_noqueue_rejection_with_uppercase_emails(self):
        line = "2026-11-13T10:10:00+07:00 mail.company.com postfix/smtpd[100]: NOQUEUE: reject: RCPT from app01.internal[10.10.10.50]: 554 5.7.1 <Bad.Actor@Company.COM>: Sender address rejected: Access denied; from=<Bad.Actor@Company.COM> to=<Target.User@GMAIL.COM> proto=ESMTP helo=<app01.internal>"
        self.consolidator.process_line(line)

        with open(self.output_log, "r", encoding="utf-8") as f:
            records = [json.loads(l) for l in f if l.strip()]

        self.assertEqual(len(records), 1)
        rec = records[0]
        self.assertEqual(rec["queue_id"], "NOQUEUE")
        self.assertEqual(rec["from"], "bad.actor@company.com")
        self.assertEqual(rec["to"], "target.user@gmail.com")
        self.assertEqual(rec["status"], "rejected")


if __name__ == "__main__":
    unittest.main()
