"""Per-project mailbox settings; never inherit another project's credentials."""
import os
from email.utils import parseaddr
from django.conf import settings


def mailbox_domain():
    return (os.getenv("MAILBOX_DOMAIN") or getattr(settings, "MAILBOX_DOMAIN", "")
            or getattr(settings, "DOMAIN", "") or "").strip().lower()


def inbound_domains():
    """Accept explicitly retained domains while outgoing mail uses the primary one."""
    aliases = os.getenv("MAILBOX_LEGACY_DOMAINS") or getattr(settings, "MAILBOX_LEGACY_DOMAINS", "")
    return {domain.strip().lower() for domain in [mailbox_domain(), *aliases.split(",")] if domain.strip()}


def default_alias():
    address = parseaddr(getattr(settings, "DEFAULT_FROM_EMAIL", ""))[1]
    if "@" in address and address.rsplit("@", 1)[1].lower() == mailbox_domain():
        return address.rsplit("@", 1)[0]
    return "support"


def inbound_secret():
    return os.getenv("INBOUND_EMAIL_SECRET") or getattr(settings, "INBOUND_EMAIL_SECRET", "")
