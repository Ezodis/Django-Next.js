import hashlib
import hmac
import time
from email.message import EmailMessage

from django.contrib.auth.models import User
from django.test import TestCase, TransactionTestCase, override_settings
from django.urls import reverse

from .models import ReceivedEmail
from .models import OutgoingEmail
from unittest.mock import patch


@override_settings(INBOUND_EMAIL_SECRET="mail-test-secret", MAILBOX_DOMAIN="current.example.test")
class MailboxTests(TestCase):
    def setUp(self):
        message = EmailMessage()
        message["Subject"] = "A question about a book"
        message["From"] = "reader@example.test"
        message["To"] = "support@current.example.test"
        message.set_content("Please help me find this book.")
        message.add_attachment(b"attachment content", maintype="text", subtype="plain", filename="note.txt")
        self.raw = message.as_bytes()

    def deliver(self, recipient="support@current.example.test", raw=None, timestamp=None, signature=None):
        raw = self.raw if raw is None else raw
        timestamp = str(timestamp or int(time.time()))
        prefix = f"{timestamp}\nreader@example.test\n{recipient}\n".encode()
        signed = signature or hmac.new(b"mail-test-secret", prefix + raw, hashlib.sha256).hexdigest()
        return self.client.post("/mailroom/inbound/", raw, content_type="application/octet-stream",
                                HTTP_X_MAIL_TIMESTAMP=timestamp, HTTP_X_MAIL_FROM="reader@example.test",
                                HTTP_X_MAIL_TO=recipient, HTTP_X_MAIL_SIGNATURE=signed)

    def test_catch_all_accepts_any_alias_and_deduplicates_retries(self):
        for alias in ("bonn", "support", "any-name"):
            self.assertEqual(self.deliver(alias + "@current.example.test").status_code, 201)
            self.assertEqual(self.deliver(alias + "@current.example.test").status_code, 200)
        self.assertEqual(ReceivedEmail.objects.count(), 3)
        message = ReceivedEmail.objects.first()
        self.assertIn("Please help", message.text_body)
        self.assertFalse(message.is_read)

    def test_rejects_invalid_signature_expired_request_and_foreign_domain(self):
        self.assertEqual(self.deliver(signature="0" * 64).status_code, 403)
        self.assertEqual(self.deliver(timestamp=int(time.time()) - 600).status_code, 403)
        self.assertEqual(self.deliver("support@example.test").status_code, 400)
        self.assertEqual(self.deliver("current.example.test").status_code, 400)
        self.assertFalse(ReceivedEmail.objects.exists())

    @override_settings(INBOUND_EMAIL_SECRET="")
    def test_unconfigured_receiver_is_closed(self):
        self.assertEqual(self.deliver().status_code, 503)

    @override_settings(MAILBOX_LEGACY_DOMAINS=" legacy.example.test ")
    def test_retained_domain_accepts_signed_mail_without_changing_sender_domain(self):
        self.assertEqual(self.deliver("support@legacy.example.test").status_code, 201)
        self.assertEqual(self.deliver("support@current.example.test").status_code, 201)
        self.assertEqual(self.deliver("support@unrelated.example.test").status_code, 400)
        message = OutgoingEmail(from_alias="support", recipient="reader@example.test", subject="Reply", body="Hello")
        message.clean()
        self.assertEqual(message.sender, "support@current.example.test")

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


@override_settings(MAILBOX_DOMAIN="current.example.test", EMAIL_BACKEND="django.core.mail.backends.locmem.EmailBackend")
class ComposeTests(TestCase):
    def test_any_alias_is_saved_and_sent_once(self):
        from django.core import mail
        from .delivery import send_pending_mail
        message = OutgoingEmail.objects.create(from_alias="support", recipient="reader@example.test", subject="Book reply", body="Hello")
        self.assertEqual(message.sender, "support@current.example.test")
        send_pending_mail()
        send_pending_mail()
        self.assertEqual(len(mail.outbox), 1)
        self.assertEqual(mail.outbox[0].from_email, "support@current.example.test")
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
        with patch("mailroom.delivery.EmailMessage.send", side_effect=RuntimeError("secret")):
            send_pending_mail()
        message.refresh_from_db()
        self.assertIsNone(message.sent_at)
        self.assertIsNotNone(message.next_attempt_at)
        self.assertNotIn("secret", message.last_error)
        self.assertEqual(message.sender, "orders@current.example.test")

    def test_admin_compose_and_reply_prefill(self):
        owner = User.objects.create_superuser("owner", "owner@example.test", "test-pass")
        self.client.force_login(owner)
        message = ReceivedEmail.objects.create(sender="reader@example.test", recipient="support@current.example.test", subject="Help",
                                              text_body="A question", raw_message=b"Subject: Help\n\nA question", digest="b" * 64)
        response = self.client.get(reverse("admin:mailroom_outgoingemail_add"), {"reply_to": message.pk})
        self.assertContains(response, "Send email")
        self.assertContains(response, 'value="support"')
        self.assertContains(response, 'value="reader@example.test"')
        response = self.client.post(reverse("admin:mailroom_outgoingemail_add"), {
            "from_alias": "support", "recipient": "reader@example.test", "subject": "Re: Help", "body": "Hello", "_save": "Send email",
        })
        self.assertEqual(response.status_code, 302)
        self.assertEqual(OutgoingEmail.objects.get().sender, "support@current.example.test")

    @override_settings(MAILBOX_DOMAIN="other.example.test")
    def test_project_domain_is_isolated(self):
        message = OutgoingEmail.objects.create(from_alias="support", recipient="friend@example.test", subject="Hello", body="Hello")
        self.assertEqual(message.sender, "support@other.example.test")

    @override_settings(EMAIL_BACKEND="django.core.mail.backends.console.EmailBackend")
    def test_console_backend_does_not_mark_mail_delivered(self):
        from .delivery import send_pending_mail
        message = OutgoingEmail.objects.create(from_alias="support", recipient="friend@example.test", subject="Hello", body="Hello")
        send_pending_mail()
        message.refresh_from_db()
        self.assertIsNone(message.sent_at)
        self.assertIsNotNone(message.next_attempt_at)


@override_settings(MAILBOX_DOMAIN="example.test")
class MailboxWorkspaceTests(TestCase):
    def setUp(self):
        self.owner = User.objects.create_superuser("mailowner", "owner@example.test", "test-pass")
        self.client.force_login(self.owner)
        self.url = reverse("admin:mailroom_receivedemail_changelist")
        self.message = ReceivedEmail.objects.create(sender="reader@example.test", recipient="support@example.test",
            subject="A special edition", text_body="Could you help find a signed copy? <script>unsafe()</script>",
            raw_message=b"Subject: A special edition\n\nHello", digest="c" * 64)

    def test_one_navigation_entry_and_unified_layout(self):
        from django.contrib import admin
        response = self.client.get(self.url)
        self.assertContains(response, 'class="mailbox')
        self.assertContains(response, "A special edition")
        self.assertContains(response, "Compose")
        self.assertContains(response, "Search mail")
        entries = next(app for app in admin.site.get_app_list(response.wsgi_request) if app["app_label"] == "mailroom")
        self.assertEqual([item["object_name"] for item in entries["models"]], ["ReceivedEmail"])

    def test_search_and_folders_filter_without_exposing_unrelated_results(self):
        response = self.client.get(self.url, {"q": "signed"})
        self.assertContains(response, "A special edition")
        self.assertNotContains(self.client.get(self.url, {"q": "absent phrase"}), "A special edition")
        self.client.post(self.url, {"action": "archive", "selected": self.message.pk})
        self.assertNotContains(self.client.get(self.url), "A special edition")
        self.assertContains(self.client.get(self.url, {"folder": "archive"}), "A special edition")
        self.client.post(self.url + "?folder=archive", {"action": "restore", "selected": self.message.pk})
        self.assertContains(self.client.get(self.url), "A special edition")

    def test_reader_escapes_message_content_and_does_not_mutate_on_get(self):
        response = self.client.get(self.url, {"message": self.message.pk})
        self.assertContains(response, "&lt;script&gt;unsafe()&lt;/script&gt;")
        self.assertNotContains(response, "<script>unsafe()</script>")
        self.assertContains(response, "Download original email")
        self.assertContains(response, "Reply")
        self.message.refresh_from_db()
        self.assertFalse(self.message.is_read)
        self.client.post(self.url, {"action": "read", "selected": self.message.pk})
        self.message.refresh_from_db()
        self.assertTrue(self.message.is_read)

    def test_compose_reply_and_delivery_status_share_the_workspace(self):
        response = self.client.get(self.url, {"reply": self.message.pk})
        self.assertContains(response, 'class="mail-composer"')
        self.assertContains(response, 'value="reader@example.test"')
        self.assertContains(response, 'value="support"')
        with patch("mailroom.delivery.EmailMessage.send") as send:
            response = self.client.post(self.url, {"action": "send", "from_alias": "support",
                "recipient": "reader@example.test", "subject": "Re: A special edition", "body": "Hello"})
            send.assert_not_called()
        self.assertRedirects(response, self.url + "?folder=outbox")
        self.assertEqual(OutgoingEmail.objects.get().sender, "support@example.test")
        self.assertContains(self.client.get(self.url, {"folder": "outbox"}), "Queued")
        self.assertNotContains(self.client.get(self.url, {"folder": "sent"}), "Re: A special edition")

    @override_settings(LANGUAGE_CODE="en")
    def test_invalid_compose_retains_form_errors_without_queuing(self):
        response = self.client.post(self.url, {"action": "send", "from_alias": "other@foreign.test",
            "recipient": "not-an-email", "subject": "Test", "body": "Body"})
        self.assertContains(response, 'class="mail-composer"')
        self.assertContains(response, "Enter a valid email address")
        self.assertFalse(OutgoingEmail.objects.exists())

    def test_readonly_staff_cannot_modify_or_send_and_unprivileged_staff_are_denied(self):
        from django.contrib.auth.models import Permission
        staff = User.objects.create_user("reader", is_staff=True)
        staff.user_permissions.add(Permission.objects.get(codename="view_receivedemail"))
        self.client.force_login(staff)
        self.assertEqual(self.client.get(self.url).status_code, 200)
        for action in ("read", "archive", "send", "retry"):
            self.assertEqual(self.client.post(self.url, {"action": action, "selected": self.message.pk}).status_code, 403)
        self.assertEqual(self.client.get(self.url, {"compose": 1}).status_code, 403)
        outsider = User.objects.create_user("outsider", is_staff=True)
        self.client.force_login(outsider)
        self.assertEqual(self.client.get(self.url).status_code, 403)

    def test_outgoing_only_staff_cannot_read_incoming_messages(self):
        from django.contrib.auth.models import Permission
        staff = User.objects.create_user("sentreader", is_staff=True)
        staff.user_permissions.add(Permission.objects.get(codename="view_outgoingemail"))
        self.client.force_login(staff)
        response = self.client.get(self.url, {"folder": "sent"})
        self.assertEqual(response.status_code, 200)
        self.assertNotContains(response, "A special edition")
        self.assertEqual(self.client.get(self.url, {"message": self.message.pk}).status_code, 404)

    def test_pagination_limits_rows_and_malformed_identifiers_fail_closed(self):
        [ReceivedEmail.objects.create(sender="reader@example.test", recipient="support@example.test",
            subject=f"Message {index}", raw_message=b"Hello", digest=f"{index:064x}") for index in range(35)]
        response = self.client.get(self.url)
        self.assertEqual(len(response.context["page"].object_list), 30)
        self.assertTrue(response.context["page"].has_next())
        self.assertEqual(self.client.get(self.url, {"message": "invalid"}).status_code, 404)
        self.assertEqual(self.client.post(self.url, {"action": "archive", "selected": "invalid"}).status_code, 404)

    def test_actions_require_csrf(self):
        from django.test import Client
        client = Client(enforce_csrf_checks=True)
        client.force_login(self.owner)
        self.assertEqual(client.post(self.url, {"action": "archive", "selected": self.message.pk}).status_code, 403)


@override_settings(MAILBOX_DOMAIN="example.test", EMAIL_BACKEND="django.core.mail.backends.locmem.EmailBackend")
class ConversationTests(TestCase):
    def setUp(self):
        self.owner = User.objects.create_superuser("owner", "owner@example.test", "test-pass")
        self.client.force_login(self.owner)
        self.url = reverse("admin:mailroom_receivedemail_changelist")
        self.original = self.receive("<first@example.test>", "Availability", "Hello https://example.test/book?edition=1&lang=en")

    def receive(self, message_id, subject, text="Hello", references="", html=None):
        mime = EmailMessage()
        mime["From"] = "Reader <reader@example.test>"
        mime["To"] = "support@example.test"
        mime["Cc"] = "Friend <friend@example.test>"
        mime["Reply-To"] = "replies@example.test"
        mime["Subject"] = subject
        mime["Message-ID"] = message_id
        if references:
            mime["References"] = references
        mime.set_content(text)
        if html:
            mime.add_alternative(html, subtype="html")
        raw = mime.as_bytes()
        return ReceivedEmail.objects.create(sender="reader@example.test", recipient="support@example.test", subject=subject,
            message_id=message_id, text_body=text, raw_message=raw, digest=hashlib.sha256(raw).hexdigest())

    def test_rfc_threading_includes_sent_replies_and_preserves_external_headers(self):
        from .delivery import send_pending_mail
        from django.core import mail
        response = self.client.post(self.url, {"action": "send", "mode": "reply", "source_type": "incoming",
            "source_id": self.original.pk, "from_alias": "support", "recipient": "reader@example.test",
            "subject": "Re: Availability", "body": "Yes, it is available."})
        self.assertEqual(response.status_code, 302)
        reply = OutgoingEmail.objects.get()
        self.assertEqual(reply.thread_id, self.original.thread_id)
        send_pending_mail()
        sent = mail.outbox[0]
        self.assertEqual(sent.extra_headers["In-Reply-To"], self.original.message_id)
        self.assertIn(self.original.message_id, sent.extra_headers["References"])
        self.assertEqual(sent.extra_headers["Message-ID"], reply.message_id)
        followup = self.receive("<followup@example.test>", "A changed subject", references=self.original.message_id + " " + reply.message_id)
        self.assertEqual(followup.thread_id, reply.thread_id)
        response = self.client.get(self.url, {"thread": reply.thread_id})
        self.assertEqual(response.context["page"].paginator.count, 1)
        self.assertEqual(len(response.context["conversation"]), 3)
        self.assertContains(response, "Yes, it is available.")

    def test_duplicate_subjects_are_separate_but_out_of_order_replies_join(self):
        separate = self.receive("<new@example.test>", "Availability")
        self.assertNotEqual(separate.thread_id, self.original.thread_id)
        child = self.receive("<child@example.test>", "Re: Another conversation", references="<missing@example.test>")
        parent = self.receive("<missing@example.test>", "Another conversation")
        self.assertEqual(child.thread_id, parent.thread_id)

    def test_links_and_html_are_clickable_without_executable_or_remote_content(self):
        message = self.receive("<html@example.test>", "Your confirmation", html='''<html><head><style>body{display:none}</style></head><body>
            <p>Confirm your address <a href="https://example.test/confirm?token=abc&amp;lang=en" onclick="steal()">Confirm email</a></p>
            <img src="https://tracker.example.test/pixel"><script>steal()</script><iframe src="https://evil.test"></iframe>
            <a href="javascript:steal()">Bad</a><svg onload="steal()"></svg><form action="https://evil.test"><input name="password"></form>
            <b>Thanks!</b></body></html>''')
        response = self.client.get(self.url, {"thread": message.thread_id})
        self.assertContains(response, 'href="https://example.test/confirm?token=abc&amp;lang=en" target="_blank" rel="noopener noreferrer"')
        self.assertContains(response, "<b>Thanks!</b>")
        for unsafe in ('onclick=', 'javascript:', '<iframe', '<form action="https://evil', 'tracker.example.test', 'steal()'):
            self.assertNotContains(response, unsafe)
        response = self.client.get(self.url, {"thread": self.original.thread_id})
        self.assertContains(response, 'href="https://example.test/book?edition=1&amp;lang=en"')

    def test_reply_all_uses_reply_to_and_excludes_own_address(self):
        response = self.client.get(self.url, {"reply_all": self.original.pk})
        initial = response.context["compose_form"].initial
        self.assertEqual(initial["recipient"], "replies@example.test")
        self.assertEqual(initial["cc"], "friend@example.test")
        response = self.client.get(self.url, {"forward": self.original.pk})
        self.assertEqual(response.context["compose_form"].initial["recipient"], "")
        self.assertIn("Forwarded message", response.context["compose_form"].initial["body"])

    def test_partial_drafts_are_private_and_never_sent_until_explicitly_queued(self):
        from .delivery import send_pending_mail
        from django.core import mail
        self.client.post(self.url, {"action": "save_draft", "from_alias": "support", "body": "Unfinished"})
        draft = OutgoingEmail.objects.get()
        self.assertTrue(draft.is_draft)
        send_pending_mail()
        self.assertEqual(len(mail.outbox), 0)
        other = User.objects.create_superuser("other", "other@example.test", "test-pass")
        self.client.force_login(other)
        self.assertNotContains(self.client.get(self.url, {"folder": "drafts"}), "Unfinished")
        self.assertEqual(self.client.get(self.url, {"draft": draft.pk}).status_code, 404)
        legacy = self.client.get(reverse("admin:mailroom_outgoingemail_change", args=[draft.pk]))
        self.assertNotContains(legacy, "Unfinished", status_code=302)
        self.client.force_login(self.owner)
        self.client.post(self.url, {"action": "send", "draft": draft.pk, "from_alias": "support",
            "recipient": "reader@example.test", "subject": "Finished", "body": "Ready"})
        self.assertEqual(OutgoingEmail.objects.count(), 1)
        draft.refresh_from_db()
        self.assertFalse(draft.is_draft)
        send_pending_mail()
        self.assertEqual(len(mail.outbox), 1)
        self.assertEqual(self.client.post(self.url, {"action": "send", "draft": draft.pk}).status_code, 404)

    def test_cc_bcc_and_attachments_deliver_with_private_downloads(self):
        from django.core.files.uploadedfile import SimpleUploadedFile
        from django.core import mail
        from .delivery import send_pending_mail
        response = self.client.post(self.url, {"action": "send", "from_alias": "support", "subject": "Details", "body": "Attached",
            "recipient": "One <one@example.test>, two@example.test", "cc": "friend@example.test", "bcc": "private@example.test",
            "attachments": SimpleUploadedFile("details.txt", b"the details", content_type="text/plain")})
        self.assertEqual(response.status_code, 302)
        email = OutgoingEmail.objects.get()
        send_pending_mail()
        self.assertEqual(mail.outbox[0].to, ["one@example.test", "two@example.test"])
        self.assertEqual(mail.outbox[0].cc, ["friend@example.test"])
        self.assertEqual(mail.outbox[0].bcc, ["private@example.test"])
        self.assertNotIn("Bcc", mail.outbox[0].message())
        self.assertEqual(mail.outbox[0].attachments[0].filename, "details.txt")
        url = reverse("admin:mailroom_outgoing_attachment", args=[email.attachments.get().pk])
        response = self.client.get(url)
        self.assertEqual(b"".join(response.streaming_content), b"the details")
        self.assertIn("no-store", response["Cache-Control"])
        self.client.force_login(User.objects.create_user("staff", is_staff=True))
        self.assertEqual(self.client.get(url).status_code, 403)

    def test_bulk_thread_actions_trash_restore_and_worker_hold(self):
        from .delivery import send_pending_mail
        from django.core import mail
        self.receive("<second@example.test>", "Re: Availability", references=self.original.message_id)
        queued = OutgoingEmail.objects.create(thread=self.original.thread, from_alias="support", recipient="reader@example.test", subject="Re: Availability", body="Hi")
        for action in ("read", "star", "archive"):
            self.client.post(self.url, {"action": action, "threads": self.original.thread_id})
        self.assertFalse(ReceivedEmail.objects.filter(is_read=False).exists())
        self.assertEqual(self.client.get(self.url, {"folder": "starred"}).context["page"].paginator.count, 1)
        self.assertEqual(self.client.get(self.url).context["page"].paginator.count, 0)
        self.client.post(self.url, {"action": "trash", "threads": self.original.thread_id})
        self.assertEqual(self.client.get(self.url, {"folder": "trash"}).context["page"].paginator.count, 1)
        send_pending_mail()
        self.assertEqual(len(mail.outbox), 0)
        self.client.post(self.url, {"action": "restore", "threads": self.original.thread_id})
        self.assertEqual(self.client.get(self.url).context["page"].paginator.count, 1)
        send_pending_mail()
        self.assertEqual(len(mail.outbox), 1)

    def test_thread_permissions_and_csrf_protect_hidden_messages(self):
        from django.contrib.auth.models import Permission
        outgoing = OutgoingEmail.objects.create(thread=self.original.thread, from_alias="support", recipient="reader@example.test", subject="Reply", body="Outgoing content")
        staff = User.objects.create_user("outgoing", is_staff=True)
        staff.user_permissions.add(Permission.objects.get(codename="view_outgoingemail"))
        self.client.force_login(staff)
        response = self.client.get(self.url, {"folder": "outbox", "thread": outgoing.thread_id})
        self.assertContains(response, "Outgoing content")
        self.assertNotContains(response, "edition=1")
        self.assertEqual(len(response.context["conversation"]), 1)
        self.assertEqual(self.client.post(self.url, {"action": "trash", "threads": outgoing.thread_id}).status_code, 403)
        self.assertEqual(self.client.get(self.url, {"thread": "invalid"}).status_code, 404)

    def test_upload_limit_and_header_injection_do_not_queue_mail(self):
        from django.core.files.uploadedfile import SimpleUploadedFile
        data = {"action": "send", "from_alias": "support", "recipient": "reader@example.test", "subject": "Hi", "body": "Hello"}
        response = self.client.post(self.url, {**data, "attachments": [SimpleUploadedFile(str(i) + ".txt", b"x") for i in range(11)]})
        self.assertContains(response, "Attach up to 10 files")
        response = self.client.post(self.url, {**data, "cc": "friend@example.test\nBcc: attacker@example.test"})
        self.assertEqual(response.status_code, 200)
        self.assertFalse(OutgoingEmail.objects.exists())


class MailboxMigrationTests(TransactionTestCase):
    def test_existing_mail_is_preserved_and_threaded_during_upgrade(self):
        from django.db import connection
        from django.db.migrations.executor import MigrationExecutor
        old = [("mailroom", "0003_project_sender")]
        new = [("mailroom", "0004_mailbox_threads_and_drafts")]
        executor = MigrationExecutor(connection)
        executor.migrate(old)
        apps = executor.loader.project_state(old).apps
        Received = apps.get_model("mailroom", "ReceivedEmail")
        Outgoing = apps.get_model("mailroom", "OutgoingEmail")
        raw = b"Message-ID: <historic@example.test>\nSubject: Original\n\nStored content"
        first = Received.objects.create(sender="reader@example.test", recipient="support@example.test", subject="Original",
            message_id="<historic@example.test>", raw_message=raw, text_body="Stored content", digest="a" * 64, is_read=True, is_archived=True)
        sent = Outgoing.objects.create(from_alias="support", sender="support@example.test", recipient="reader@example.test",
            subject="Re: Original", body="Historic reply")
        try:
            executor = MigrationExecutor(connection)
            executor.migrate(new)
            first = ReceivedEmail.objects.get(pk=first.pk)
            sent = OutgoingEmail.objects.get(pk=sent.pk)
            self.assertEqual(first.thread_id, sent.thread_id)
            self.assertEqual(bytes(first.raw_message), raw)
            self.assertTrue(first.is_read)
            self.assertTrue(first.is_archived)
            self.assertEqual(sent.body, "Historic reply")
            self.assertFalse(sent.is_draft)
            self.assertTrue(sent.message_id)
        finally:
            MigrationExecutor(connection).migrate(new)
