import logging
import importlib
import os
from datetime import timedelta
from pathlib import Path

import dj_database_url

from .project_config import find_apps

logger = logging.getLogger(__name__)

BASE_DIR = Path(__file__).resolve().parent.parent


def env_value(name, default):
    value = os.getenv(name)
    return value if value and value.strip() else default


def env_int(name, default):
    return int(env_value(name, default))


def env_bool(name, default):
    return env_value(name, str(default)).lower() == "true"


# Core ∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿

# SECURITY WARNING: keep the secret key used in production secret!
SECRET_KEY = os.getenv("DJANGO_SECRET_KEY")

# SECURITY WARNING: don't run with debug turned on in production!
DEBUG = env_bool("DJANGO_DEBUG", False)

DOMAIN = os.getenv("DOMAIN")
if not DOMAIN and not DEBUG:
    raise Exception("DOMAIN environment variable is required in production")

ALLOWED_HOSTS = []
if DEBUG:
    # Allow all hosts in development so mobile apps on local network (Expo Go) can connect.
    ALLOWED_HOSTS = ["*"]
else:
    if DOMAIN:
        ALLOWED_HOSTS.extend([DOMAIN, f"www.{DOMAIN}", f"api.{DOMAIN}"])
    # Railway auto-generates a *.up.railway.app domain — allow it dynamically
    railway_host = os.getenv("RAILWAY_PUBLIC_DOMAIN")
    if railway_host and railway_host not in ALLOWED_HOSTS:
        ALLOWED_HOSTS.append(railway_host)
    # Any extra hosts (comma-separated) for other platforms
    extra = os.getenv("EXTRA_ALLOWED_HOSTS", "")
    if extra:
        ALLOWED_HOSTS.extend([h.strip() for h in extra.split(",") if h.strip()])


# Applications ∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿

INSTALLED_APPS = [
    'corsheaders',
    'rest_framework',
    'rest_framework.authtoken',
    'rest_framework_simplejwt.token_blacklist',
    'import_export',
    'django.contrib.admin',
    'django.contrib.auth',
    'django.contrib.contenttypes',
    'django.contrib.sessions',
    'django.contrib.messages',
    'django.contrib.staticfiles',
] + find_apps(BASE_DIR)

if DEBUG:
    INSTALLED_APPS += ["django_extensions"]

MIDDLEWARE = [
    'corsheaders.middleware.CorsMiddleware',
    'whitenoise.middleware.WhiteNoiseMiddleware',
    'django.middleware.locale.LocaleMiddleware',
    'django.middleware.security.SecurityMiddleware',
    'django.contrib.sessions.middleware.SessionMiddleware',
    'django.middleware.common.CommonMiddleware',
    'django.middleware.csrf.CsrfViewMiddleware',
    'django.contrib.auth.middleware.AuthenticationMiddleware',
    'django.contrib.messages.middleware.MessageMiddleware',
    'django.middleware.clickjacking.XFrameOptionsMiddleware',
]

ROOT_URLCONF = 'config.urls'

TEMPLATES = [
    {
        'BACKEND': 'django.template.backends.django.DjangoTemplates',
        'DIRS': [],
        'APP_DIRS': True,
        'OPTIONS': {
            'context_processors': [
                'django.template.context_processors.request',
                'django.contrib.auth.context_processors.auth',
                'django.contrib.messages.context_processors.messages',
            ],
        },
    },
]

WSGI_APPLICATION = 'config.wsgi.application'

DEFAULT_AUTO_FIELD = 'django.db.models.BigAutoField'


# Database ∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿

if DEBUG:
    DATABASES = {
        "default": {
            "ENGINE": "django.db.backends.postgresql",
            "NAME": env_value("DB_NAME", "postgres"),
            "USER": env_value("DB_USER", "postgres"),
            "PASSWORD": env_value("DB_PASSWORD", "postgres"),
            "HOST": env_value("DB_HOST", "db"),
            "PORT": env_value("DB_PORT", "5432"),
        }
    }
else:
    DATABASES = {
        "default": dj_database_url.config(
            default="postgres://user:password@host:5432/dbname",
            conn_max_age=600,
            ssl_require=env_bool("DB_SSL_REQUIRE", True),
        )
    }


# Cache ∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿

REDIS_URL = os.getenv('REDIS_URL')

if DEBUG:
    # In dev, auto-build Redis URL from individual env vars (set by Docker Compose)
    if not REDIS_URL:
        REDIS_HOST = env_value('REDIS_HOST', 'redis')
        REDIS_PORT = env_value('REDIS_PORT', '6379')
        REDIS_DB   = env_value('REDIS_DB', '0')
        REDIS_URL  = f"redis://{REDIS_HOST}:{REDIS_PORT}/{REDIS_DB}"

if REDIS_URL:
    CACHES = {
        'default': {
            'BACKEND': 'django_redis.cache.RedisCache',
            'LOCATION': REDIS_URL,
            'OPTIONS': {
                'CLIENT_CLASS': 'django_redis.client.DefaultClient',
                'CONNECTION_POOL_KWARGS': {
                    'max_connections': env_int('REDIS_MAX_CONNECTIONS', 50),
                    'retry_on_timeout': True,
                },
            },
            'KEY_PREFIX': env_value(
                'CACHE_KEY_PREFIX',
                env_value('COMPOSE_PROJECT_NAME', DOMAIN or BASE_DIR.parent.name or BASE_DIR.name),
            ),
            'TIMEOUT': env_int('CACHE_TIMEOUT', 300),  # 5 minutes default
        }
    }
    SESSION_ENGINE = 'django.contrib.sessions.backends.cache'
    SESSION_CACHE_ALIAS = 'default'
else:
    # No Redis — use in-memory cache (fine for Railway hobby tier; no persistence)
    CACHES = {
        'default': {
            'BACKEND': 'django.core.cache.backends.locmem.LocMemCache',
            'TIMEOUT': env_int('CACHE_TIMEOUT', 300),
        }
    }
    SESSION_ENGINE = 'django.contrib.sessions.backends.db'


# Password validation ∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿

AUTH_PASSWORD_VALIDATORS = [
    {'NAME': 'django.contrib.auth.password_validation.UserAttributeSimilarityValidator'},
    {
        'NAME': 'django.contrib.auth.password_validation.MinimumLengthValidator',
        'OPTIONS': {'min_length': 8},
    },
    {'NAME': 'django.contrib.auth.password_validation.CommonPasswordValidator'},
    {'NAME': 'django.contrib.auth.password_validation.NumericPasswordValidator'},
]


# Internationalisation ∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿

LANGUAGE_CODE = env_value('LANGUAGE_CODE', 'en-us')
TIME_ZONE = env_value('TIME_ZONE', 'UTC')
USE_I18N = True
USE_TZ = True


# Static & media files ∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿

STATIC_URL = '/static/'
STATIC_ROOT = os.path.join(BASE_DIR, 'config/staticfiles')

MEDIA_URL = '/media/'
MEDIA_ROOT = os.path.join(BASE_DIR, 'media')

PRIVATE_ASSETS_PATH = os.path.join(BASE_DIR.parent, 'private_assets')

DATA_UPLOAD_MAX_MEMORY_SIZE = env_int('DATA_UPLOAD_MAX_MEMORY_SIZE', 524288000)  # 500 MB default
FILE_UPLOAD_MAX_MEMORY_SIZE = env_int('FILE_UPLOAD_MAX_MEMORY_SIZE', 10485760)   # 10 MB default


# REST Framework & JWT ∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿

REST_FRAMEWORK = {
    'DEFAULT_PERMISSION_CLASSES': ['rest_framework.permissions.AllowAny'],
    'DEFAULT_RENDERER_CLASSES': ['rest_framework.renderers.JSONRenderer'],
    'DEFAULT_PARSER_CLASSES': [
        'rest_framework.parsers.JSONParser',
        'rest_framework.parsers.MultiPartParser',
        'rest_framework.parsers.FormParser',
    ],
    'DEFAULT_AUTHENTICATION_CLASSES': [
        'rest_framework_simplejwt.authentication.JWTAuthentication',
        'rest_framework.authentication.SessionAuthentication',
    ],
    'DEFAULT_THROTTLE_CLASSES': [
        'rest_framework.throttling.AnonRateThrottle',
        'rest_framework.throttling.UserRateThrottle',
    ],
    'DEFAULT_THROTTLE_RATES': {
        'anon': env_value('THROTTLE_ANON', '10000/hour'),
        'user': env_value('THROTTLE_USER', '100000/hour'),
    },
}

SIMPLE_JWT = {
    'ACCESS_TOKEN_LIFETIME': timedelta(hours=env_int('JWT_ACCESS_TOKEN_HOURS', 1)),
    'REFRESH_TOKEN_LIFETIME': timedelta(days=env_int('JWT_REFRESH_TOKEN_DAYS', 7)),
    'ROTATE_REFRESH_TOKENS': True,
    'BLACKLIST_AFTER_ROTATION': True,
}


# CORS ∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿

CORS_ALLOW_CREDENTIALS = True
CORS_ALLOWED_ORIGINS = []
CSRF_TRUSTED_ORIGINS = []

if DEBUG:
    # CORS: allow everything in dev — mobile apps, emulators, tunnels all need this.
    CORS_ALLOW_ALL_ORIGINS = True

    CSRF_TRUSTED_ORIGINS.extend([
        # Local dev
        "http://localhost",
        "http://localhost:3000",
        "http://127.0.0.1:3000",
        "http://localhost:8000",
        "http://127.0.0.1:8000",
        "http://10.0.2.2:8000",   # Android emulator host alias
        # Cloudflare quick-tunnel (trycloudflare.com)
        # Safe to wildcard here because SESSION_COOKIE_SAMESITE='Lax' already
        # prevents cross-site cookie attachment, which is the actual CSRF threat.
        # This entry just lets Django render admin pages through the tunnel without
        # needing a container restart every time the tunnel URL rotates.
        "https://*.trycloudflare.com",
    ])

    # Add mobile app API URL from environment if set
    mobile_api_url = os.getenv("EXPO_PUBLIC_API_URL")
    if mobile_api_url:
        from urllib.parse import urlparse
        parsed = urlparse(mobile_api_url)
        if parsed.scheme and parsed.netloc:
            mobile_origin = f"{parsed.scheme}://{parsed.netloc}"
            if mobile_origin not in CSRF_TRUSTED_ORIGINS:
                CSRF_TRUSTED_ORIGINS.append(mobile_origin)
                logger.info(f"Added mobile API origin to CSRF trusted origins: {mobile_origin}")
else:
    CORS_ALLOW_ALL_ORIGINS = False
    if DOMAIN:
        CORS_ALLOWED_ORIGINS.extend([
            f"https://{DOMAIN}",
            f"https://www.{DOMAIN}",
        ])
        CSRF_TRUSTED_ORIGINS.extend([
            f"https://{DOMAIN}",
            f"https://www.{DOMAIN}",
            f"https://api.{DOMAIN}",
        ])
    
    # Extra origins for staging, preview deploys, etc. (comma-separated)
    # Supports both exact URLs and patterns like "https://*.example.com"
    extra_origins = os.getenv("EXTRA_CORS_ORIGINS", "")
    if extra_origins:
        for origin in [o.strip() for o in extra_origins.split(",") if o.strip()]:
            if origin not in CORS_ALLOWED_ORIGINS:
                CORS_ALLOWED_ORIGINS.append(origin)
            if origin not in CSRF_TRUSTED_ORIGINS:
                CSRF_TRUSTED_ORIGINS.append(origin)

# Hosting providers and preview URL formats are configured explicitly.
CORS_ALLOWED_ORIGIN_REGEXES = [
    pattern.strip() for pattern in os.getenv('EXTRA_CORS_ORIGIN_REGEXES', '').split(',')
    if pattern.strip()
]
CSRF_TRUSTED_ORIGINS.extend(
    origin.strip() for origin in os.getenv('EXTRA_CSRF_ORIGINS', '').split(',')
    if origin.strip() and origin.strip() not in CSRF_TRUSTED_ORIGINS
)
if DEBUG and os.getenv('PROJECT_HOST'):
    CSRF_TRUSTED_ORIGINS.extend([
        f"http://{os.environ['PROJECT_HOST']}.localhost",
        f"https://{os.environ['PROJECT_HOST']}.localhost",
    ])

CORS_EXPOSE_HEADERS = ['Content-Type', 'X-CSRFToken']
CORS_ALLOW_HEADERS = [
    'accept',
    'accept-encoding',
    'authorization',
    'cache-control',
    'content-type',
    'dnt',
    'origin',
    'pragma',
    'user-agent',
    'x-csrftoken',
    'x-requested-with',
]


# CSRF & cookies ∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿

CSRF_COOKIE_HTTPONLY = False   # allow JS to read CSRF token
CSRF_USE_SESSIONS = False      # use cookies, not sessions, for CSRF

if DEBUG:
    SESSION_COOKIE_SECURE = False
    CSRF_COOKIE_SECURE = False
    SESSION_COOKIE_SAMESITE = 'Lax'
    CSRF_COOKIE_SAMESITE = 'Lax'
    SESSION_COOKIE_DOMAIN = None
    CSRF_COOKIE_DOMAIN = None
else:
    SESSION_COOKIE_SECURE = True
    CSRF_COOKIE_SECURE = True
    SESSION_COOKIE_SAMESITE = 'None'
    CSRF_COOKIE_SAMESITE = 'None'
    if DOMAIN:
        SESSION_COOKIE_DOMAIN = f".{DOMAIN}"
        CSRF_COOKIE_DOMAIN = f".{DOMAIN}"

SESSION_COOKIE_HTTPONLY = True
SESSION_COOKIE_AGE = env_int('SESSION_COOKIE_AGE', 86400)  # 1 day default
SESSION_EXPIRE_AT_BROWSER_CLOSE = False
SESSION_SAVE_EVERY_REQUEST = False  # Only save modified sessions


# Security headers ∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿

SECURE_CONTENT_TYPE_NOSNIFF = True
X_FRAME_OPTIONS = 'DENY'

if not DEBUG:
    SECURE_SSL_REDIRECT = True
    SECURE_HSTS_SECONDS = env_int('SECURE_HSTS_SECONDS', 31536000)  # 1 year default
    SECURE_HSTS_INCLUDE_SUBDOMAINS = True
    SECURE_HSTS_PRELOAD = True
    SECURE_PROXY_SSL_HEADER = ('HTTP_X_FORWARDED_PROTO', 'https')


# Email ∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿

EMAIL_BACKEND = (
    'django.core.mail.backends.smtp.EmailBackend'
    if not DEBUG
    else 'django.core.mail.backends.console.EmailBackend'
)
EMAIL_HOST = env_value('EMAIL_HOST', 'localhost')
EMAIL_PORT = env_int('EMAIL_PORT', 587)
EMAIL_USE_TLS = env_bool('EMAIL_USE_TLS', True)
EMAIL_HOST_USER = os.environ.get('EMAIL_HOST_USER', '')
EMAIL_HOST_PASSWORD = os.environ.get('EMAIL_HOST_PASSWORD', '')
DEFAULT_FROM_EMAIL = os.environ.get('DEFAULT_FROM_EMAIL', '')

logger.info("Database: %s | DEBUG: %s", DATABASES['default']['ENGINE'], DEBUG)


# Apply project settings while preserving discovered and core Django apps.
# Missing project.py is supported; errors inside an existing module must surface.
try:
    _project = importlib.import_module('project')
except ModuleNotFoundError as _error:
    if _error.name != 'project':
        raise
else:
    for _name, _value in vars(_project).items():
        if not _name.isupper() or _name.startswith('_'):
            continue
        if _name == 'INSTALLED_APPS':
            INSTALLED_APPS = list(dict.fromkeys(INSTALLED_APPS + list(_value)))
        else:
            globals()[_name] = _value


# Dev server autoreloader exclusions ∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿
# Prevent Django's StatReloader from watching large data dirs.
# triggers a reload loop that exits the dev server with code 0.
if DEBUG:
    try:
        import django.utils.autoreload as _autoreload

        _EXCLUDE_PREFIXES = tuple(
            Path(path).resolve() for path in [MEDIA_ROOT] + list(globals().get('AUTORELOAD_EXCLUDE_PATHS', []))
        )

        _orig_watched_files = _autoreload.StatReloader.watched_files

        def _patched_watched_files(self, include_globs=True):
            for path in _orig_watched_files(self, include_globs):
                if not any(Path(path).resolve().is_relative_to(ex) for ex in _EXCLUDE_PREFIXES):
                    yield path

        _autoreload.StatReloader.watched_files = _patched_watched_files
    except Exception:
        pass  # non-fatal — skip if Django internals changed
