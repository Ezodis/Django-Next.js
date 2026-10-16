from datetime import timedelta

from django.core.mail import EmailMessage
from django.conf import settings
from django.db import transaction
from django.db.models import Q
from django.utils import timezone

from .models import OutgoingEmail, address_list


def send_pending_mail():
    ids = list(OutgoingEmail.objects.filter(sent_at__isnull=True, is_draft=False, thread__is_trashed=False).filter(
        Q(next_attempt_at__isnull=True) | Q(next_attempt_at__lte=timezone.now())
    ).values_list("pk", flat=True)[:50])
    for pk in ids:
        with transaction.atomic():
            email = OutgoingEmail.objects.select_for_update().get(pk=pk)
            if email.is_draft or email.thread.is_trashed or email.sent_at or (email.next_attempt_at and email.next_attempt_at > timezone.now()):
                continue
            email.attempts += 1
            try:
                if settings.EMAIL_BACKEND in ("django.core.mail.backends.console.EmailBackend", "django.core.mail.backends.dummy.EmailBackend", "django.core.mail.backends.filebased.EmailBackend"):
                    raise RuntimeError("Configure a delivery provider before sending queued mail.")
                headers = {"Message-ID": email.message_id}
                if email.in_reply_to:
                    headers["In-Reply-To"] = email.in_reply_to
                if email.references:
                    headers["References"] = email.references
                message = EmailMessage(email.subject, email.body, email.sender, address_list(email.recipient),
                                       cc=address_list(email.cc), bcc=address_list(email.bcc), headers=headers)
                for attachment in email.attachments.all():
                    message.attach(attachment.filename, bytes(attachment.content), attachment.content_type)
                if message.send(fail_silently=False) != 1:
                    raise RuntimeError("Email was not accepted.")
                email.sent_at = timezone.now()
                email.last_error = ""
                email.next_attempt_at = None
            except Exception:
                email.last_error = "Delivery failed. Check this project’s email provider credentials, sender authorization and sending quota. Automatic retry is scheduled."
                email.next_attempt_at = timezone.now() + timedelta(minutes=min(60, 2 ** min(email.attempts, 6)))
            email.save(update_fields=["sent_at", "attempts", "last_error", "next_attempt_at"])
