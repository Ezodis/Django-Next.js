"""
URL configuration for backend project.

The `urlpatterns` list routes URLs to views. For more information please see:
    https://docs.djangoproject.com/en/5.2/topics/http/urls/
Examples:
Function views
    1. Add an import:  from my_app import views
    2. Add a URL to urlpatterns:  path('', views.home, name='home')
Class-based views
    1. Add an import:  from other_app.views import Home
    2. Add a URL to urlpatterns:  path('', Home.as_view(), name='home')
Including another URLconf
    1. Import the include() function: from django.urls import include, path
    2. Add a URL to urlpatterns:  path('blog/', include('blog.urls'))
"""

# backend/urls.py
import os
import importlib
from django.contrib import admin
from django.urls import path, include, re_path
from django.http import JsonResponse
from django.middleware.csrf import get_token
from django.conf import settings
from django.views.static import serve
from django.contrib.auth import authenticate
from django.views.decorators.http import require_http_methods
import json
import logging

# --- Dynamic app discovery ---
def find_apps(base_dir, exclude_dirs=None):
    exclude_dirs = exclude_dirs or []
    exclude_dirs = list(exclude_dirs) + ["config", "__pycache__"]
    apps = []
    for item in os.listdir(base_dir):
        item_path = os.path.join(base_dir, item)
        if (
            os.path.isdir(item_path)
            and item not in exclude_dirs
            and os.path.isfile(os.path.join(item_path, "__init__.py"))
        ):
            apps.append(item)
    return apps


# --- Health and CSRF endpoints ---
def health_check(request):
    return JsonResponse({"status": "healthy", "service": "backend"})


def csrf_token(request):
    """CSRF token endpoint for frontend API calls"""
    return JsonResponse({"csrfToken": get_token(request)})


@require_http_methods(["POST"])
def admin_login(request):
    """Simple admin login endpoint for /equipo/ admin panel"""
    try:
        data = json.loads(request.body)
        username = data.get('username')
        password = data.get('password')
        
        if not username or not password:
            return JsonResponse({'error': 'Username and password are required'}, status=400)
        
        # Basic input validation
        if len(username) > 150 or len(password) > 128:
            return JsonResponse({'error': 'Invalid credentials'}, status=401)
        
        # Authenticate user
        user = authenticate(request, username=username, password=password)
        
        if user is not None and user.is_staff:
            # User is authenticated and is a staff member
            # Store user session
            from django.contrib.auth import login
            login(request, user)
            
            return JsonResponse({
                'success': True,
                'message': 'Login successful',
                'token': 'authenticated',  # Using Django sessions instead of tokens
                'username': user.username
            })
        else:
            return JsonResponse({'error': 'Invalid credentials or not an admin user'}, status=401)
    
    except json.JSONDecodeError:
        return JsonResponse({'error': 'Invalid JSON'}, status=400)
    except Exception as e:
        logger = logging.getLogger(__name__)
        logger.error(f'Admin login error: {e}')
        return JsonResponse({'error': 'Login failed'}, status=500)


# --- Build urlpatterns dynamically ---
urlpatterns = [
    path("health/", health_check, name="health-check"),
    path("csrf/", csrf_token, name="csrf-token"),
    path("admin/login/", admin_login, name="admin-login"),
    path("auth/", include("phone_auth.urls")),
    path("call/", include("communications.api_urls")),
    path("admin/", admin.site.urls),
]

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
apps = find_apps(BASE_DIR, exclude_dirs=["backend", "migrations", "phone_auth"])

for app in apps:
    try:
        importlib.import_module(f"{app}.urls")  # check if app has urls
        # Register under both bare path (used by Traefik after stripping /api prefix)
        # and under api/ prefix (used by mobile apps hitting port 8000 directly)
        urlpatterns.append(path(f"{app}/", include(f"{app}.urls")))
        urlpatterns.append(path(f"api/{app}/", include(f"{app}.urls")))
    except ModuleNotFoundError:
        # silently skip apps without urls.py
        pass

# Also register health/csrf/auth under api/ prefix for direct mobile access
urlpatterns += [
    path("api/health/", health_check, name="api-health-check"),
    path("api/csrf/", csrf_token, name="api-csrf-token"),
    path("api/auth/", include("phone_auth.urls")),
    path("api/call/", include("communications.api_urls")),
]

# Serve media files in development
if settings.DEBUG:
    urlpatterns += [
        re_path(r'^media/(?P<path>.*)$', serve, {
            'document_root': settings.MEDIA_ROOT,
            'show_indexes': True,
        }),
    ]
    
