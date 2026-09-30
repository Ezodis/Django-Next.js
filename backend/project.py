"""
Project-specific overrides — keep settings.py as a shared template.

• Python section  : extra INSTALLED_APPS, setting overrides, integrations
• Services section: extra Docker Compose services for this project
  (written as YAML in the COMPOSE_SERVICES string below — dev.sh picks it up)
• Sync section    : SYNC_PROJECT_PATHS tells dev.sh sync which paths are
  project-owned (will not be overwritten when pulling template updates)
"""
import json
import logging
import os
from pathlib import Path

_logger = logging.getLogger(__name__)
_BASE_DIR = Path(__file__).resolve().parent
DEBUG = os.getenv("DJANGO_DEBUG", "False").lower() == "true"


# Python settings ∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿

# Example: Stripe integration (uncomment and configure as needed)
# STRIPE_PUBLISHABLE_KEY = os.getenv('STRIPE_PUBLISHABLE_KEY')
# STRIPE_SECRET_KEY = os.getenv('STRIPE_SECRET_KEY')
# STRIPE_WEBHOOK_SECRET = os.getenv('STRIPE_WEBHOOK_SECRET')

# Example: Twilio SMS/voice verification (uncomment and configure as needed)
# TWILIO_ACCOUNT_SID = os.getenv('TWILIO_ACCOUNT_SID')
# TWILIO_AUTH_TOKEN = os.getenv('TWILIO_AUTH_TOKEN')
# TWILIO_PHONE_NUMBER = os.getenv('TWILIO_PHONE_NUMBER')
# TWILIO_VERIFY_SERVICE_SID = os.getenv('TWILIO_VERIFY_SERVICE_SID')
# TWILIO_VOICE_GREETING = os.getenv(
#     'TWILIO_VOICE_GREETING',
#     'Hello from assistant. Please confirm your action by saying yes or no.',
# )

# Custom URL prefixes — map app names to a different URL prefix when needed.
# Apps not listed use their own name automatically. See config/urls.py.
# Example: CUSTOM_URL_PREFIXES = {"myapp": "custom-prefix"}
CUSTOM_URL_PREFIXES = {}

# GCS (production media storage) ∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿
# Only active in production (DEBUG=False) when GCS_BUCKET_NAME is set.
# Overrides MEDIA_URL and MEDIA_ROOT from settings.py.
# Remove this block to fall back to local file storage.
if not DEBUG:
    _bucket = os.getenv('GCS_BUCKET_NAME')
    _project_id = os.getenv('GCS_PROJECT_ID')
    _credentials = None
    _credentials_json = os.getenv('GOOGLE_APPLICATION_CREDENTIALS_JSON')
    if _credentials_json:
        try:
            _parsed = json.loads(_credentials_json)
            _required = ['type', 'project_id', 'private_key_id', 'private_key', 'client_email']
            if isinstance(_parsed, dict) and all(k in _parsed for k in _required):
                _credentials = _parsed
            else:
                _logger.warning("GOOGLE_APPLICATION_CREDENTIALS_JSON missing required fields")
        except (json.JSONDecodeError, Exception):
            _logger.warning("GOOGLE_APPLICATION_CREDENTIALS_JSON is not valid JSON")

    if _bucket and _project_id:
        INSTALLED_APPS = [  # noqa: F821 — appended to settings.py's list via import *
            'storages',
        ]
        STORAGES = {
            "default": {
                "BACKEND": "storages.backends.gcloud.GoogleCloudStorage",
                "OPTIONS": {
                    "bucket_name": _bucket,
                    "project_id": _project_id,
                    "credentials": _credentials,
                    "default_acl": None,
                    "querystring_auth": True,
                    "expiration": 3600,
                    "file_overwrite": False,
                    "location": "media",
                },
            },
            "staticfiles": {
                "BACKEND": "django.contrib.staticfiles.storage.StaticFilesStorage",
            },
        }
        MEDIA_URL = f"https://storage.googleapis.com/{_bucket}/media/"
        MEDIA_ROOT = str(_BASE_DIR / 'media')
        _logger.info("GCS storage configured: bucket=%s", _bucket)
    else:
        _logger.info("GCS_PROJECT_ID not set — using local file storage")


# Sync protection ∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿
# Shared tooling discovers application paths without importing this module.
# Keep these bootstrap options as literal values.
SYNC_PROJECT_PATHS = ["backend/ml_service/"]
SYNC_TEMPLATE_REPO = "Ezodis/Django-Next.js"
MOBILE_APP_ORDER = []
MOBILE_ANDROID_METADATA = {}
AUTORELOAD_EXCLUDE_PATHS = [str(_BASE_DIR.parent / 'imports'), '/imports']


# Compose services ∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿
# Extra Docker Compose services merged alongside dev.yml by dev.sh.
#
# Mobile services are auto-discovered and generated dynamically by dev.sh's
# gen_mobile_yaml() function — it scans frontend/mobile/ for any folder with
# a package.json and creates services automatically.
#
# To add project-specific backend services or custom containers, define them
# in the COMPOSE_SERVICES string below (YAML format).
#
# Startup logic: add <app>/management/commands/entrypoint.py to any app.
# entrypoint.sh calls `manage.py entrypoint` which Django discovers it automatically.

COMPOSE_SERVICES = """
# Project-specific services go here (merged with dev.yml by dev.sh)
# Mobile services are auto-generated — no need to define them here.
#
# Example: Mount extra data directory into frontend
# services:
#   frontend:
#     volumes:
#       - ./data:/app/public/data:z,ro
"""
