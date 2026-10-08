from django.test import SimpleTestCase, TestCase
from django.conf import settings
from django.urls import reverse, resolve
import os
import json


class MediaURLConfigurationTestCase(SimpleTestCase):
    """Test cases for media URL configuration (no database needed)

Note: Django's test runner sets DEBUG=False during tests, so media URLs
won't be served during testing. These tests verify the configuration.
"""

    def test_media_url_code_has_show_indexes(self):
        """Test that the URLs module configures show_indexes=True for media when DEBUG=True"""
        # Read the actual urls.py file to verify the configuration
        urls_file_path = os.path.join(
            os.path.dirname(__file__), 
            'urls.py'
        )

        with open(urls_file_path, 'r') as f:
            urls_content = f.read()

        # Verify that show_indexes is set to True in the code
        self.assertIn('"show_indexes": True', urls_content,
                      "show_indexes should be set to True in urls.py")

        # Verify it's within the DEBUG check
        self.assertIn("if settings.DEBUG:", urls_content,
                      "Media serving should be conditional on DEBUG")

        # Verify we're using django.views.static.serve
        self.assertIn("from django.views.static import serve", urls_content,
                      "Should import serve from django.views.static")

    def test_media_root_configuration(self):
        """Test that MEDIA_ROOT and MEDIA_URL are properly configured"""
        self.assertTrue(hasattr(settings, 'MEDIA_ROOT'))
        self.assertTrue(hasattr(settings, 'MEDIA_URL'))

        # In development, MEDIA_URL should be '/media/'
        # In production with GCS, it will be a GCS URL
        if settings.DEBUG:
            self.assertEqual(settings.MEDIA_URL, '/media/')
        else:
            # In production, MEDIA_URL could be a GCS URL or local fallback
            self.assertTrue(settings.MEDIA_URL.startswith(('http://', 'https://', '/media/')))

    def test_storage_backend_configuration(self):
        """Storage may be local or supplied by any project's overrides."""
        self.assertIn('default', settings.STORAGES)
        self.assertIn('BACKEND', settings.STORAGES['default'])
        self.assertIn('staticfiles', settings.STORAGES)


class AdminLoginURLTestCase(TestCase):
    """Test cases for admin login URL configuration"""

    def test_admin_login_url_resolves_correctly(self):
        """Test that /admin/login/ resolves to custom admin_login view"""
        # Resolve the URL and check it goes to the correct view
        resolved = resolve('/admin/login/')

        # The view function should be admin_login, not Django's admin login
        self.assertEqual(resolved.view_name, 'admin-login',
                        "/admin/login/ should resolve to custom admin-login view")

    def test_admin_login_requires_credentials(self):
        """Test that admin_login endpoint requires username and password"""
        # Try to POST without credentials
        response = self.client.post('/admin/login/',
                                   content_type='application/json',
                                   data='{}')

        # Should return 400 Bad Request for missing credentials
        self.assertEqual(response.status_code, 400)
        data = response.json()
        self.assertIn('error', data)

    def test_admin_login_rejects_invalid_credentials(self):
        """Test that admin_login rejects invalid credentials"""
        # Try to POST with invalid credentials
        response = self.client.post('/admin/login/',
                                   content_type='application/json',
                                   data='{"username": "invalid", "password": "wrong"}')

        # Should return 401 Unauthorized
        self.assertEqual(response.status_code, 401)
        data = response.json()
        self.assertIn('error', data)

    def test_admin_login_requires_staff_permission(self):
        """Test that admin_login requires user to be staff"""
        from django.contrib.auth import get_user_model
        User = get_user_model()

        # Create a regular user (not staff)
        regular_user = User.objects.create_user(
            username='regular',
            password='testpass123',
            is_staff=False
        )

        # Try to login with non-staff user
        response = self.client.post('/admin/login/',
                                   content_type='application/json',
                                   data='{"username": "regular", "password": "testpass123"}')

        # Should return 401 Unauthorized
        self.assertEqual(response.status_code, 401)
        data = response.json()
        self.assertIn('error', data)

    def test_admin_login_accepts_staff_credentials(self):
        """Test that admin_login accepts valid staff credentials"""
        from django.contrib.auth import get_user_model
        User = get_user_model()

        # Create a staff user
        staff_user = User.objects.create_user(
            username='admin',
            password='admin',
            is_staff=True
        )

        # Try to login with staff credentials
        response = self.client.post('/admin/login/',
                                   content_type='application/json',
                                   data='{"username": "admin", "password": "admin"}')

        # Should return 200 OK
        self.assertEqual(response.status_code, 200)
        data = response.json()
        self.assertTrue(data.get('success'))
        self.assertEqual(data.get('username'), 'admin')




class TemplateSyncTests(SimpleTestCase):
    def test_web_sync_preserves_project_dependencies_scripts_and_identity(self):
        from .project_config import merge_web_package
        template = {'dependencies': {'next': '16.4.0', 'react': '19.3.0'},
                    'devDependencies': {'typescript': '5.9.3'},
                    'scripts': {'build': 'next build --webpack', 'typecheck': 'tsc --noEmit'},
                    'engines': {'node': '>=24 <25'}}
        project = {'name': 'custom-app', 'dependencies': {'next': '15.0.0', 'stripe': 'custom'},
                   'scripts': {'postinstall': 'custom-command', 'export': 'next export'},
                   'devDependencies': {'custom-tool': '1'}}
        merged = json.loads(merge_web_package(json.dumps(template).encode(), json.dumps(project).encode()))
        self.assertEqual(merged['name'], 'custom-app')
        self.assertEqual(merged['dependencies'], {'next': '16.4.0', 'react': '19.3.0', 'stripe': 'custom'})
        self.assertEqual(merged['scripts']['postinstall'], 'custom-command')
        self.assertNotIn('export', merged['scripts'])
        self.assertEqual(merged['devDependencies']['custom-tool'], '1')
        self.assertEqual(merged['scripts']['build'], 'next build --webpack')

    def test_requirement_sync_preserves_project_integrations(self):
        from .project_config import merge_requirements
        template = b'Django==5.2.18\n\n# Project-specific integrations\ntemplate-only==1\n'
        project = b'Django==4.2.16\n\n# Project-specific integrations\nproject-only==2\n'
        merged = merge_requirements(template, project)
        self.assertIn(b'Django==5.2.18', merged)
        self.assertIn(b'project-only==2', merged)
        self.assertNotIn(b'template-only', merged)

    def test_sync_does_not_downgrade_newer_project_versions(self):
        from .project_config import merge_requirements, merge_web_package
        template = {'dependencies': {'next': '16.4.0'}}
        project = {'dependencies': {'next': '16.4.1'}}
        merged = json.loads(merge_web_package(json.dumps(template).encode(), json.dumps(project).encode()))
        self.assertEqual(merged['dependencies']['next'], '16.4.1')
        merged_requirements = merge_requirements(b'Django==5.2.18\n', b'Django==5.2.19\n')
        self.assertIn(b'Django==5.2.19', merged_requirements)
