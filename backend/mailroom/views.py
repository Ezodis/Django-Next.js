import hashlib
import hmac
import time
from email import policy
from email.parser import BytesParser

from django.conf import settings
from django.http import JsonResponse
from django.views.decorators.csrf import csrf_exempt
from django.views.decorators.http import require_POST

from .models import ReceivedEmail
from .configuration import inbound_domains, inbound_secret
from .content import html_text

MAX_MESSAGE_BYTES = 10 * 1024 * 1024


@csrf_exempt  # Provider requests use an HMAC covering timestamp, envelope, and MIME body.
@require_POST
def receive_email(request):
    secret = inbound_secret()
    if not secret:
        return JsonResponse({"error": "Mailbox routing is not configured."}, status=503)
    timestamp = request.headers.get("X-Mail-Timestamp", "")
    sender = request.headers.get("X-Mail-From", "")
    recipient = request.headers.get("X-Mail-To", "")
    signature = request.headers.get("X-Mail-Signature", "")
    try:
        if abs(time.time() - int(timestamp)) > 300:
            raise ValueError
        size = int(request.headers.get("Content-Length", "0"))
    except ValueError:
        return JsonResponse({"error": "Invalid delivery request."}, status=403)
    if len(signature) != 64 or any("\n" in value or "\r" in value for value in (sender, recipient)):
        return JsonResponse({"error": "Invalid delivery request."}, status=403)
    if not 0 < size <= MAX_MESSAGE_BYTES:
        return JsonResponse({"error": "Message exceeds the 10 MiB mailbox limit."}, status=413)
    raw = request.body
    if len(raw) > MAX_MESSAGE_BYTES:
        return JsonResponse({"error": "Message exceeds the 10 MiB mailbox limit."}, status=413)
    prefix = f"{timestamp}\n{sender}\n{recipient}\n".encode()
    expected = hmac.new(secret.encode(), prefix + raw, hashlib.sha256).hexdigest()
    if not hmac.compare_digest(expected, signature):
        return JsonResponse({"error": "Invalid delivery signature."}, status=403)
    if recipient.count("@") != 1 or not recipient.rsplit("@", 1)[0] or recipient.rsplit("@", 1)[-1].lower() not in inbound_domains() or len(recipient) > 320 or len(sender) > 320:
        return JsonResponse({"error": "Recipient is outside the mailbox domain."}, status=400)
    message = BytesParser(policy=policy.default).parsebytes(raw)
    body = message.get_body(preferencelist=("plain", "html"))
    text = ""
    if body:
        try:
            text = body.get_content()
        except (LookupError, UnicodeError):
            text = (body.get_payload(decode=True) or b"").decode("utf-8", errors="replace")
        if body.get_content_type() == "text/html":
            text = html_text(text)
    digest = hashlib.sha256(recipient.lower().encode() + b"\0" + sender.encode() + b"\0" + raw).hexdigest()
    email, created = ReceivedEmail.objects.get_or_create(digest=digest, defaults={
        "sender": sender, "recipient": recipient, "subject": str(message.get("Subject", ""))[:1000],
        "message_id": str(message.get("Message-ID", ""))[:1000], "text_body": text,
        "raw_message": raw,
    })
    return JsonResponse({"received": True, "id": email.pk}, status=201 if created else 200)
