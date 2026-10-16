"""Reusable HTTPS email backends with credentials isolated to project settings.

Configure EMAIL_BACKEND and credentials in each project's root .env, or opt in
to project_email_settings() from project.py. No provider keys are synchronized.
"""

import base64
import json
import re
from email.utils import getaddresses
from urllib.request import Request, urlopen

from django.conf import settings
from django.core.mail.backends.base import BaseEmailBackend
from django.utils.module_loading import import_string


def email_delivery_ready():
    backend = getattr(settings, "EMAIL_BACKEND", "")
    backend_class = import_string(backend) if backend else None
    if backend_class and issubclass(backend_class, BrevoEmailBackend):
        return bool(getattr(settings, "BREVO_API_KEY", ""))
    if backend_class and issubclass(backend_class, CloudflareEmailBackend):
        return bool(
            re.fullmatch(r"[a-fA-F0-9]{32}", getattr(settings, "CLOUDFLARE_ACCOUNT_ID", ""))
            and getattr(settings, "CLOUDFLARE_EMAIL_API_TOKEN", "")
        )
    return bool(
        backend == "django.core.mail.backends.smtp.EmailBackend"
        and getattr(settings, "EMAIL_HOST_USER", "")
        and getattr(settings, "EMAIL_HOST_PASSWORD", "")
    )


def attachments(message):
    """Encode Django file attachments for the HTTPS providers.

    Unsupported MIME objects fail delivery instead of silently losing a file.
    """
    result = []
    for attachment in message.attachments:
        filename, content, mime_type = attachment
        if isinstance(content, str):
            content = content.encode(message.encoding or "utf-8")
        result.append({"filename": filename, "type": mime_type,
                       "content": base64.b64encode(content).decode("ascii"),
                       "disposition": "attachment"})
    return result


class CloudflareEmailBackend(BaseEmailBackend):
    def send_messages(self, email_messages):
        sent = 0
        for message in email_messages or []:
            if not message.recipients():
                continue
            try:
                if not (re.fullmatch(r"[a-fA-F0-9]{32}", getattr(settings, "CLOUDFLARE_ACCOUNT_ID", ""))
                        and getattr(settings, "CLOUDFLARE_EMAIL_API_TOKEN", "")):
                    raise RuntimeError("Cloudflare email account ID and sending token are required.")
                message.message()  # Django validates headers before they leave the application.
                recipients = [address for _, address in getaddresses(message.recipients())]
                payload = {
                    "from": message.from_email,
                    "subject": message.subject,
                    "html" if message.content_subtype == "html" else "text": message.body,
                }
                for field in ("to", "cc", "bcc"):
                    addresses = getattr(message, field, [])
                    if addresses:
                        payload[field] = [address for _, address in getaddresses(addresses)]
                if message.reply_to:
                    payload["reply_to"] = message.reply_to[0]
                if message.extra_headers:
                    payload["headers"] = message.extra_headers
                if message.attachments:
                    payload["attachments"] = attachments(message)
                for content, mime_type in getattr(message, "alternatives", []):
                    if mime_type == "text/html":
                        payload["html"] = content
                request = Request(
                    "https://api.cloudflare.com/client/v4/accounts/"
                    + settings.CLOUDFLARE_ACCOUNT_ID + "/email/sending/send",
                    data=json.dumps(payload).encode("utf-8"),
                    headers={
                        "Authorization": "Bearer " + settings.CLOUDFLARE_EMAIL_API_TOKEN,
                        "Content-Type": "application/json",
                    },
                    method="POST",
                )
                with urlopen(request, timeout=getattr(settings, "EMAIL_TIMEOUT", 20)) as response:
                    result = json.load(response)
                delivery = result.get("result") or {}
                accepted = {address.lower() for address in delivery.get("delivered", []) + delivery.get("queued", [])}
                if not result.get("success") or any(address.lower() not in accepted for address in recipients):
                    raise RuntimeError("Cloudflare did not accept delivery for every recipient.")
                sent += 1
            except Exception:
                if not self.fail_silently:
                    # Provider errors can include message data; retain a safe retry error.
                    raise RuntimeError("Cloudflare email delivery failed; check domain verification and sending credentials.") from None
        return sent


class BrevoEmailBackend(BaseEmailBackend):
    def send_messages(self, email_messages):
        sent = 0
        for message in email_messages or []:
            if not message.recipients():
                continue
            try:
                if not getattr(settings, "BREVO_API_KEY", ""):
                    raise RuntimeError("Brevo email API key is required.")
                message.message()
                sender_name, sender_address = getaddresses([message.from_email])[0]
                payload = {"sender": {"email": sender_address}, "subject": message.subject,
                           "htmlContent" if message.content_subtype == "html" else "textContent": message.body}
                if sender_name:
                    payload["sender"]["name"] = sender_name
                for field in ("to", "cc", "bcc"):
                    addresses = getattr(message, field, [])
                    if addresses:
                        payload[field] = [{"email": address} for _, address in getaddresses(addresses)]
                if message.reply_to:
                    payload["replyTo"] = {"email": getaddresses(message.reply_to)[0][1]}
                if message.extra_headers:
                    payload["headers"] = message.extra_headers
                if message.attachments:
                    payload["attachment"] = [{"name": item["filename"], "content": item["content"]}
                                             for item in attachments(message)]
                for content, mime_type in getattr(message, "alternatives", []):
                    if mime_type == "text/html":
                        payload["htmlContent"] = content
                        payload.pop("textContent", None)
                request = Request("https://api.brevo.com/v3/smtp/email", data=json.dumps(payload).encode(),
                                  headers={"api-key": settings.BREVO_API_KEY, "Content-Type": "application/json"},
                                  method="POST")
                with urlopen(request, timeout=getattr(settings, "EMAIL_TIMEOUT", 20)) as response:
                    result = json.load(response)
                if not result.get("messageId"):
                    raise RuntimeError("Brevo did not accept this message.")
                sent += 1
            except Exception:
                if not self.fail_silently:
                    raise RuntimeError("Brevo email delivery failed; check domain verification, account activation and sending quota.") from None
        return sent
