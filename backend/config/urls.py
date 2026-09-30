import importlib
import json
import logging
import os

from django.conf import settings
from django.contrib import admin
from django.contrib.auth import authenticate
from django.http import JsonResponse
from django.middleware.csrf import get_token
from django.urls import include, path, re_path
from django.views.decorators.http import require_http_methods
from django.views.static import serve
from rest_framework_simplejwt.views import TokenRefreshView

from .project_config import find_apps

logger = logging.getLogger(__name__)


def _try_include(app, url_module=None):
    """Return an include() for the app's urls module, or None if it doesn't exist."""
    module = url_module or f"{app}.urls"
    try:
        importlib.import_module(module)
        return include(module)
    except ModuleNotFoundError as error:
        if error.name == module:
            return None
        raise


def health_check(request):
    return JsonResponse({"status": "healthy", "service": "backend"})


def csrf_token(request):
    return JsonResponse({"csrfToken": get_token(request)})


@require_http_methods(["POST"])
def admin_login(request):
    try:
        data = json.loads(request.body)
        username = data.get("username")
        password = data.get("password")

        if not username or not password:
            return JsonResponse({"error": "Username and password are required"}, status=400)

        if len(username) > 150 or len(password) > 128:
            return JsonResponse({"error": "Invalid credentials"}, status=401)

        user = authenticate(request, username=username, password=password)

        if user is not None and user.is_staff:
            from django.contrib.auth import login
            login(request, user)
            return JsonResponse({
                "success": True,
                "message": "Login successful",
                "token": "authenticated",
                "username": user.username,
            })
        else:
            return JsonResponse({"error": "Invalid credentials or not an admin user"}, status=401)

    except json.JSONDecodeError:
        return JsonResponse({"error": "Invalid JSON"}, status=400)
    except Exception as e:
        logger.error("Admin login error: %s", e)
        return JsonResponse({"error": "Login failed"}, status=500)


urlpatterns = [
    path("health/", health_check, name="health-check"),
    path("csrf/", csrf_token, name="csrf-token"),
    path("admin/", admin.site.urls),
    path("api/health/", health_check, name="api-health-check"),
    path("api/csrf/", csrf_token, name="api-csrf-token"),
    path("api/admin/login/", admin_login, name="admin-login"),
    # JWT token refresh — used by mobile clients to get a new access token
    path("api/token/refresh/", TokenRefreshView.as_view(), name="token-refresh"),
]

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
apps = find_apps(BASE_DIR, exclude_dirs=["backend", "migrations"])
apps = [app for app in apps if app in settings.INSTALLED_APPS or any(
    installed.startswith(f'{app}.') for installed in settings.INSTALLED_APPS
)]

# CUSTOM_URL_PREFIXES is defined in settings.py under project-specific integrations
custom_prefixes = getattr(settings, "CUSTOM_URL_PREFIXES", {})

for app in apps:
    prefix = custom_prefixes.get(app, app)
    urls = _try_include(app)
    if urls is None:
        continue
    urlpatterns.append(path(f"{prefix}/", urls))

if settings.DEBUG:
    urlpatterns += [
        re_path(r"^media/(?P<path>.*)$", serve, {
            "document_root": settings.MEDIA_ROOT,
            "show_indexes": True,
        }),
    ]
