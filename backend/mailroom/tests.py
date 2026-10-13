import hashlib
import hmac
import time
from email.message import EmailMessage

from django.contrib.auth.models import User
from django.test import TestCase, override_settings
from django.urls import reverse

from .models import ReceivedEmail
from .models import OutgoingEmail
from unittest.mock import patch


@override_settings(INBOUND_EMAIL_SECRET="mail-test-secret", MAILBOX_DOMAIN="oldbook.ai")
class MailboxTests(TestCase):
    def setUp(self):
        message = EmailMessage()
        message["Subject"] = "A question about a book"
        message["From"] = "reader@example.test"
        message["To"] = "support@oldbook.ai"
        message.set_content("Please help me find this book.")
        message.add_attachment(b"attachment content", maintype="text", subtype="plain", filename="note.txt")
        self.raw = message.as_bytes()

    def deliver(self, recipient="support@oldbook.ai", raw=None, timestamp=None, signature=None):
        raw = self.raw if raw is None else raw
        timestamp = str(timestamp or int(time.time()))
        prefix = f"{timestamp}\nreader@example.test\n{recipient}\n".encode()
        signed = signature or hmac.new(b"mail-test-secret", prefix + raw, hashlib.sha256).hexdigest()
        return self.client.post("/mailroom/inbound/", raw, content_type="application/octet-stream",
                                HTTP_X_MAIL_TIMESTAMP=timestamp, HTTP_X_MAIL_FROM="reader@example.test",
                                HTTP_X_MAIL_TO=recipient, HTTP_X_MAIL_SIGNATURE=signed)

    def test_catch_all_accepts_any_alias_and_deduplicates_retries(self):
        for alias in ("bonn", "support", "any-name"):
            self.assertEqual(self.deliver(alias + "@oldbook.ai").status_code, 201)
            self.assertEqual(self.deliver(alias + "@oldbook.ai").status_code, 200)
        self.assertEqual(ReceivedEmail.objects.count(), 3)
        message = ReceivedEmail.objects.first()
        self.assertIn("Please help", message.text_body)
        self.assertFalse(message.is_read)

    def test_rejects_invalid_signature_expired_request_and_foreign_domain(self):
        self.assertEqual(self.deliver(signature="0" * 64).status_code, 403)
        self.assertEqual(self.deliver(timestamp=int(time.time()) - 600).status_code, 403)
        self.assertEqual(self.deliver("support@example.test").status_code, 400)
        self.assertEqual(self.deliver("oldbook.ai").status_code, 400)
        self.assertFalse(ReceivedEmail.objects.exists())

    @override_settings(INBOUND_EMAIL_SECRET="")
    def test_unconfigured_receiver_is_closed(self):
        self.assertEqual(self.deliver().status_code, 503)

    def test_rejects_oversize_message(self):
        self.assertEqual(self.deliver(raw=b"x" * (10 * 1024 * 1024 + 1)).status_code, 413)

    def test_html_content_is_read_as_text_without_rendering_resources(self):
        message = EmailMessage()
        message["Subject"] = '<script>alert("bad")</script>'
        message.set_content('<p>Hello reader</p><img src="https://tracker.example.test/x">', subtype="html")
        self.deliver(raw=message.as_bytes())
        stored = ReceivedEmail.objects.get()
        self.assertIn("Hello reader", stored.text_body)
        self.assertNotIn("<img", stored.text_body)
        user = User.objects.create_superuser("owner", "owner@example.test", "test-pass")
        self.client.force_login(user)
        response = self.client.get(reverse("admin:mailroom_receivedemail_change", args=[stored.pk]))
        self.assertContains(response, '&lt;script&gt;')
        self.assertNotContains(response, '<script>alert("bad")</script>')

    def test_downloads_require_mailbox_permission_and_are_private(self):
        self.deliver()
        message = ReceivedEmail.objects.get()
        url = reverse("admin:mailroom_receivedemail_download", args=[message.pk, 1])
        self.assertEqual(self.client.get(url).status_code, 302)
        staff = User.objects.create_user("staff", is_staff=True)
        self.client.force_login(staff)
        self.assertEqual(self.client.get(url).status_code, 403)
        owner = User.objects.create_superuser("owner", "owner@example.test", "test-pass")
        self.client.force_login(owner)
        response = self.client.get(url)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(b"".join(response.streaming_content), b"attachment content")
        self.assertIn("private", response["Cache-Control"])
        self.assertIn("no-store", response["Cache-Control"])
        self.assertIn("attachment", response["Content-Disposition"])


@override_settings(MAILBOX_DOMAIN="oldbook.ai", EMAIL_BACKEND="django.core.mail.backends.locmem.EmailBackend")
class ComposeTests(TestCase):
    def test_any_alias_is_saved_and_sent_once(self):
        from django.core import mail
        from .delivery import send_pending_mail
        message = OutgoingEmail.objects.create(from_alias="support", recipient="reader@example.test", subject="Book reply", body="Hello")
        self.assertEqual(message.sender, "support@oldbook.ai")
        send_pending_mail()
        send_pending_mail()
        self.assertEqual(len(mail.outbox), 1)
        self.assertEqual(mail.outbox[0].from_email, "support@oldbook.ai")
        message.refresh_from_db()
        self.assertIsNotNone(message.sent_at)

    def test_foreign_domain_and_header_injection_are_rejected(self):
        from django.core.exceptions import ValidationError
        for alias in ("fake@example.test", "support\nBcc: attacker@example.test"):
            with self.assertRaises(ValidationError):
                OutgoingEmail.objects.create(from_alias=alias, recipient="reader@example.test", subject="Reply", body="Hello")

    def test_failure_remains_queued_and_retains_sender(self):
        from .delivery import send_pending_mail
        message = OutgoingEmail.objects.create(from_alias="orders", recipient="reader@example.test", subject="Reply", body="Hello")
        with patch("mailroom.delivery.send_mail", side_effect=RuntimeError("secret")):
            send_pending_mail()
        message.refresh_from_db()
        self.assertIsNone(message.sent_at)
        self.assertIsNotNone(message.next_attempt_at)
        self.assertNotIn("secret", message.last_error)
        self.assertEqual(message.sender, "orders@oldbook.ai")

    def test_admin_compose_and_reply_prefill(self):
        owner = User.objects.create_superuser("owner", "owner@example.test", "test-pass")
        self.client.force_login(owner)
        message = ReceivedEmail.objects.create(sender="reader@example.test", recipient="support@oldbook.ai", subject="Help",
                                              text_body="A question", raw_message=b"Subject: Help\n\nA question", digest="b" * 64)
        response = self.client.get(reverse("admin:mailroom_outgoingemail_add"), {"reply_to": message.pk})
        self.assertContains(response, "Send email")
        self.assertContains(response, 'value="support"')
        self.assertContains(response, 'value="reader@example.test"')
        response = self.client.post(reverse("admin:mailroom_outgoingemail_add"), {
            "from_alias": "support", "recipient": "reader@example.test", "subject": "Re: Help", "body": "Hello", "_save": "Send email",
        })
        self.assertEqual(response.status_code, 302)
        self.assertEqual(OutgoingEmail.objects.get().sender, "support@oldbook.ai")

    @override_settings(MAILBOX_DOMAIN="edy.chat")
    def test_project_domain_is_isolated(self):
        message = OutgoingEmail.objects.create(from_alias="support", recipient="friend@example.test", subject="Hello", body="Hello")
        self.assertEqual(message.sender, "support@edy.chat")

    @override_settings(EMAIL_BACKEND="django.core.mail.backends.console.EmailBackend")
    def test_console_backend_does_not_mark_mail_delivered(self):
        from .delivery import send_pending_mail
        message = OutgoingEmail.objects.create(from_alias="support", recipient="friend@example.test", subject="Hello", body="Hello")
        send_pending_mail()
        message.refresh_from_db()
        self.assertIsNone(message.sent_at)
        self.assertIsNotNone(message.next_attempt_at)
