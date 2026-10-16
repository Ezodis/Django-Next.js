"""MIME presentation and RFC message threading for the project mailbox."""
import hashlib
import re
import uuid
from email import policy
from email.parser import BytesParser
from email.utils import getaddresses
from html import escape
from html.parser import HTMLParser
from urllib.parse import urlsplit

from django.db.models import Q
from django.utils.html import urlize
from django.utils.safestring import mark_safe


def parse_message(raw):
    return BytesParser(policy=policy.default).parsebytes(bytes(raw))


def message_ids(value):
    return re.findall(r"<[^<>\s]+>", str(value or ""))[-100:]


def subject_key(subject):
    normalized = re.sub(r"^(?:(?:re|fw|fwd)\s*:\s*)+", "", subject, flags=re.I).strip().casefold()
    return hashlib.sha256(normalized.encode()).hexdigest()


def assign_thread(email):
    from .models import MailThread, ReceivedEmail, OutgoingEmail
    incoming = isinstance(email, ReceivedEmail)
    mime = parse_message(email.raw_message) if incoming else None
    refs = message_ids(mime.get("References", "")) + message_ids(mime.get("In-Reply-To", "")) if incoming else message_ids(email.references) + message_ids(email.in_reply_to)
    for model in (ReceivedEmail, OutgoingEmail):
        parent = model.objects.filter(message_id__in=refs, thread__isnull=False).select_related("thread").order_by("-pk").first() if refs else None
        if parent:
            return parent.thread
    key = subject_key(email.subject)
    # Only headerless replies may fall back to subject + the same two parties.
    # New messages with a repeated subject must remain separate conversations.
    if not refs and re.match(r"^re\s*:", email.subject, re.I):
        for model in (ReceivedEmail, OutgoingEmail):
            parent = model.objects.filter(thread__subject_key=key).filter(
                Q(sender__iexact=email.sender, recipient__iexact=email.recipient)
                | Q(sender__iexact=email.recipient, recipient__iexact=email.sender)
            ).select_related("thread").order_by("-pk").first()
            if parent:
                return parent.thread
    root = refs[0] if refs else email.message_id
    thread_key = hashlib.sha256(root.encode()).hexdigest() if root else uuid.uuid4().hex
    return MailThread.objects.get_or_create(key=thread_key, defaults={"subject": email.subject, "subject_key": key})[0]


def decode_part(part):
    try:
        return part.get_content()
    except (LookupError, UnicodeError):
        return (part.get_payload(decode=True) or b"").decode("utf-8", errors="replace")


class MailHTML(HTMLParser):
    """Rebuild a small inert HTML vocabulary; never retain CSS or remote resources."""
    allowed = {"p", "br", "div", "span", "strong", "b", "em", "i", "u", "s", "blockquote", "pre", "code", "ul", "ol", "li", "h1", "h2", "h3", "h4", "hr", "table", "thead", "tbody", "tr", "td", "th", "a"}
    blocked = {"script", "style", "head", "title", "iframe", "object", "embed", "svg", "math", "template", "form"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.output = []
        self.hidden = []

    def handle_starttag(self, tag, attrs):
        if tag in self.blocked:
            self.hidden.append(tag)
        if self.hidden:
            return
        attrs = dict(attrs)
        if tag == "img":
            if attrs.get("alt"):
                self.output.append(escape(attrs["alt"]))
            return
        if tag not in self.allowed:
            return
        safe_attrs = ""
        if tag == "a":
            href = (attrs.get("href") or "").strip()
            try:
                parsed = urlsplit(href)
                safe = parsed.scheme.lower() in {"https", "http"} and bool(parsed.netloc) or parsed.scheme.lower() == "mailto"
            except ValueError:
                safe = False
            if safe and not any(ord(char) < 32 for char in href):
                safe_attrs = f' href="{escape(href, quote=True)}" target="_blank" rel="noopener noreferrer"'
        if tag in {"td", "th"}:
            for name in ("colspan", "rowspan"):
                value = attrs.get(name, "")
                if value and value.isdecimal() and len(value) < 3:
                    safe_attrs += f' {name}="{value}"'
        self.output.append(f"<{tag}{safe_attrs}>")

    def handle_endtag(self, tag):
        if self.hidden:
            if tag in self.hidden:
                self.hidden = self.hidden[:self.hidden.index(tag)]
            return
        if tag in self.allowed and tag not in {"br", "hr"}:
            self.output.append(f"</{tag}>")

    def handle_data(self, data):
        if not self.hidden:
            self.output.append(escape(data))


def safe_html(value):
    parser = MailHTML()
    parser.feed(value)
    parser.close()
    return mark_safe("".join(parser.output))


def linked_text(value):
    # Django escapes text and detects URLs; the same allowlist adds safe targets.
    return safe_html(urlize(value, autoescape=True))


def html_text(value):
    class TextReader(HTMLParser):
        def __init__(self):
            super().__init__(convert_charrefs=True)
            self.output = []
            self.link = ""

        def handle_starttag(self, tag, attrs):
            if tag in {"p", "div", "br", "li", "tr", "blockquote", "h1", "h2", "h3"}:
                self.output.append("\n")
            if tag == "a":
                self.link = dict(attrs).get("href", "")

        def handle_endtag(self, tag):
            if tag == "a" and self.link:
                self.output.append(" (" + self.link + ")")
                self.link = ""
            if tag in {"p", "div", "li", "tr", "blockquote"}:
                self.output.append("\n")

        def handle_data(self, data):
            self.output.append(data)

    reader = TextReader()
    reader.feed(safe_html(value))
    return "".join(reader.output).strip()


def message_content(email):
    mime = parse_message(email.raw_message)
    part = mime.get_body(preferencelist=("html",))
    return {"html": safe_html(decode_part(part)) if part else "", "text": linked_text(email.text_body),
            "reply_to": next((address for _, address in getaddresses([str(mime.get("Reply-To", ""))]) if address), email.sender),
            "cc": str(mime.get("Cc", "")), "to": str(mime.get("To", "")) or email.recipient,
            "references": " ".join(message_ids(mime.get("References", "")) + message_ids(email.message_id)),
            "mime": mime}
