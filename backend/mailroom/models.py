from django.db import models
from django.conf import settings
from django.core.exceptions import ValidationError
from django.core.validators import validate_email
from .configuration import mailbox_domain, default_alias


class ReceivedEmail(models.Model):
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


class OutgoingEmail(models.Model):
    from_alias = models.CharField(max_length=64, default=default_alias, help_text="Sender alias on this project’s configured mail domain.")
    sender = models.EmailField(max_length=320, editable=False)
    recipient = models.EmailField(max_length=320)
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
        super().save(*args, **kwargs)

    def __str__(self):
        return self.subject
