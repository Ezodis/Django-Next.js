"""Project-owned settings and literal options for the shared development tools.

Add integration settings here only when this project uses them. Environment
values and secrets belong in the root .env; shared architecture stays generic.
"""
CUSTOM_URL_PREFIXES = {}
SYNC_PROJECT_PATHS = []
SYNC_TEMPLATE_REPO = "Ezodis/Django-Next.js"
MOBILE_APP_ORDER = []
MOBILE_ANDROID_METADATA = {}
ENV_DEFAULTS = {
    'PROJECT_ACCOUNT_EMAIL': '',
    'DEFAULT_FROM_EMAIL': '',
    'EMAIL_BACKEND': '',
    'MAILBOX_DOMAIN': '',
    'CLOUDFLARE_ACCOUNT_ID': '',
    'CLOUDFLARE_EMAIL_API_TOKEN': '',
    'BREVO_API_KEY': '',
    'EMAIL_USE_SSL': '',
}
COMPOSE_SERVICES = """
services:
  mail-worker:
    image: ${COMPOSE_PROJECT_NAME}_backend:latest
    env_file:
      - .env
    entrypoint: []
    command: python manage.py process_mail --loop
    working_dir: /backend
    environment:
      DJANGO_DEBUG: "${DJANGO_DEBUG:-true}"
      DB_HOST: "db"
      DB_PORT: "5432"
      DB_NAME: "${DB_NAME:-postgres}"
      DB_USER: "${DB_USER:-postgres}"
      DB_PASSWORD: "${DB_PASSWORD:-postgres}"
      REDIS_HOST: "redis"
    volumes:
      - ./backend:/backend:delegated
    depends_on:
      backend:
        condition: service_healthy
    restart: unless-stopped
"""


# Shared mailbox behavior, with identity and credentials owned by this project.
from mailroom.configuration import project_email_settings as _project_email_settings
globals().update(_project_email_settings())
