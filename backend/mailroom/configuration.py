"""Per-project mailbox settings; never inherit another project's credentials."""
import os
from email.utils import parseaddr
from django.conf import settings


def project_email_settings(environ=None):
    """Opt in from project.py; read only this process's project environment.

    The account email is an identity, not an authentication credential. Provider
    activation and unique Stripe/email keys still belong to each project's .env.
    Explicit sender/backend overrides are preserved.
    """
    env = os.environ if environ is None else environ
    domain = (env.get('MAILBOX_DOMAIN') or env.get('DOMAIN') or '').strip().lower()
    account = env.get('PROJECT_ACCOUNT_EMAIL') or (('$@' + domain) if domain else '')
    backend = env.get('EMAIL_BACKEND')
    if not backend:
        if env.get('CLOUDFLARE_EMAIL_API_TOKEN'):
            backend = 'mailroom.backends.CloudflareEmailBackend'
        elif env.get('BREVO_API_KEY'):
            backend = 'mailroom.backends.BrevoEmailBackend'
        elif env.get('EMAIL_HOST_USER') or env.get('DJANGO_DEBUG', '').lower() != 'true':
            backend = 'django.core.mail.backends.smtp.EmailBackend'
        else:
            backend = 'django.core.mail.backends.console.EmailBackend'
    values = {
        'PROJECT_ACCOUNT_EMAIL': account,
        'DEFAULT_FROM_EMAIL': env.get('DEFAULT_FROM_EMAIL') or account,
        'EMAIL_BACKEND': backend,
        'EMAIL_TIMEOUT': int(env.get('EMAIL_TIMEOUT') or 20),
        'EMAIL_USE_SSL': (env.get('EMAIL_USE_SSL') or 'false').lower() == 'true',
    }
    if values['EMAIL_USE_SSL']:
        values['EMAIL_USE_TLS'] = False
    for name in ('CLOUDFLARE_ACCOUNT_ID', 'CLOUDFLARE_EMAIL_API_TOKEN', 'BREVO_API_KEY'):
        values[name] = env.get(name) or ''
    return values


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
    return "$"


def inbound_secret():
    return os.getenv("INBOUND_EMAIL_SECRET") or getattr(settings, "INBOUND_EMAIL_SECRET", "")
