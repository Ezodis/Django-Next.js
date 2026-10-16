from django.db import models
from django.conf import settings
from django.core.exceptions import ValidationError
from django.core.validators import validate_email
from .configuration import mailbox_domain, default_alias
from email.utils import getaddresses, make_msgid


class MailThread(models.Model):
    key = models.CharField(max_length=64, unique=True)
    subject = models.CharField(max_length=1000, blank=True)
    subject_key = models.CharField(max_length=64, blank=True, db_index=True)
    is_starred = models.BooleanField(default=False)
    is_trashed = models.BooleanField(default=False)


def address_list(value):
    return [address for _, address in getaddresses([value]) if address]


class ReceivedEmail(models.Model):
    thread = models.ForeignKey(MailThread, null=True, on_delete=models.SET_NULL, related_name="received")
    sender = models.CharField(max_length=320, blank=True)
    recipient = models.EmailField(max_length=320, db_index=True)
    subject = models.CharField(max_length=1000, blank=True)
    message_id = models.CharField(max_length=1000, blank=True)
    text_body = models.TextField(blank=True)
    raw_message = models.BinaryField(editable=False)
    digest = models.CharField(max_length=64, unique=True, editable=False)
    is_read = models.BooleanField(default=False)
    is_archived = models.BooleanField(default=False)
    received_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-received_at"]
        verbose_name = "received email"
        verbose_name_plural = "Inbox"

    def __str__(self):
        return self.subject or "(No subject)"

    def save(self, *args, **kwargs):
        if not self.thread_id:
            from .content import assign_thread
            self.thread = assign_thread(self)
        super().save(*args, **kwargs)


class OutgoingEmail(models.Model):
    thread = models.ForeignKey(MailThread, null=True, on_delete=models.SET_NULL, related_name="outgoing")
    message_id = models.CharField(max_length=1000, blank=True, editable=False)
    in_reply_to = models.CharField(max_length=1000, blank=True, editable=False)
    references = models.TextField(blank=True, editable=False)
    is_draft = models.BooleanField(default=False, db_index=True)
    created_by = models.ForeignKey(settings.AUTH_USER_MODEL, null=True, blank=True, on_delete=models.SET_NULL, editable=False)
    from_alias = models.CharField(max_length=64, default=default_alias, help_text="Sender alias on this project’s configured mail domain.")
    sender = models.EmailField(max_length=320, editable=False)
    recipient = models.CharField(max_length=2000)
    cc = models.CharField(max_length=2000, blank=True)
    bcc = models.CharField(max_length=2000, blank=True)
    subject = models.CharField(max_length=255)
    body = models.TextField()
    sent_at = models.DateTimeField(null=True, blank=True, editable=False)
    attempts = models.PositiveIntegerField(default=0, editable=False)
    last_error = models.TextField(blank=True, editable=False)
    next_attempt_at = models.DateTimeField(null=True, blank=True, editable=False)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]
        verbose_name = "outgoing email"
        verbose_name_plural = "Compose and sent mail"

    def clean(self):
        super().clean()
        for field in ("recipient", "cc", "bcc"):
            value = getattr(self, field)
            try:
                if any(char in value for char in ("\r", "\n")):
                    raise ValidationError("Invalid address")
                addresses = address_list(value)
                if value.strip() and not addresses:
                    raise ValidationError("Invalid address")
                for address in addresses:
                    validate_email(address)
                if len(addresses) > 50:
                    raise ValidationError("Too many addresses")
            except (ValidationError, ValueError):
                raise ValidationError({field: "Enter a valid email address or comma-separated addresses (up to 50)."})
        if any(char in self.subject for char in ("\r", "\n")):
            raise ValidationError({"subject": "The subject must be a single line."})
        if "@" in self.from_alias or any(char in self.from_alias for char in ("\r", "\n")):
            raise ValidationError({"from_alias": "Enter only the alias before @."})
        domain = mailbox_domain()
        if not domain:
            raise ValidationError({"from_alias": "Configure MAILBOX_DOMAIN or DOMAIN before sending."})
        self.sender = self.from_alias + "@" + domain
        try:
            validate_email(self.sender)
        except ValidationError:
            raise ValidationError({"from_alias": "Enter a valid email alias."})

    def save(self, *args, **kwargs):
        if not self.pk:
            self.clean()
        if not self.message_id:
            self.message_id = make_msgid(domain=mailbox_domain() or None)
        if not self.thread_id:
            from .content import assign_thread
            self.thread = assign_thread(self)
        super().save(*args, **kwargs)

    def __str__(self):
        return self.subject


class OutgoingAttachment(models.Model):
    email = models.ForeignKey(OutgoingEmail, on_delete=models.CASCADE, related_name="attachments")
    filename = models.CharField(max_length=200)
    content_type = models.CharField(max_length=200, default="application/octet-stream")
    content = models.BinaryField()
