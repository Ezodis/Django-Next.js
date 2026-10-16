"""Project isolation and complete delivery through HTTPS email providers."""
import base64
import json
from unittest.mock import MagicMock, patch

from django.core.mail import EmailMultiAlternatives
from django.test import SimpleTestCase, override_settings

from .backends import CloudflareEmailBackend, BrevoEmailBackend, email_delivery_ready
from .configuration import project_email_settings


class ProjectEmailSettingsTest(SimpleTestCase):
    def test_each_project_derives_its_own_identity_and_has_no_inherited_secrets(self):
        first = project_email_settings({'DOMAIN': 'one.example', 'BREVO_API_KEY': 'first-key'})
        second = project_email_settings({'DOMAIN': 'two.example'})
        self.assertEqual(first['DEFAULT_FROM_EMAIL'], '$@one.example')
        self.assertEqual(second['DEFAULT_FROM_EMAIL'], '$@two.example')
        self.assertEqual(second['PROJECT_ACCOUNT_EMAIL'], '$@two.example')
        self.assertEqual(second['BREVO_API_KEY'], '')
        self.assertEqual(second['CLOUDFLARE_EMAIL_API_TOKEN'], '')
        self.assertEqual(first['EMAIL_BACKEND'], 'mailroom.backends.BrevoEmailBackend')
        self.assertEqual(second['EMAIL_BACKEND'], 'django.core.mail.backends.smtp.EmailBackend')

    def test_explicit_sender_provider_and_ssl_overrides_survive(self):
        values = project_email_settings({'DOMAIN': 'one.example', 'MAILBOX_DOMAIN': 'mail.example',
                                        'PROJECT_ACCOUNT_EMAIL': '$@account.example',
                                        'DEFAULT_FROM_EMAIL': 'receipts@mail.example',
                                        'EMAIL_BACKEND': 'custom.Backend', 'EMAIL_USE_SSL': 'true'})
        self.assertEqual(values['DEFAULT_FROM_EMAIL'], 'receipts@mail.example')
        self.assertEqual(values['PROJECT_ACCOUNT_EMAIL'], '$@account.example')
        self.assertEqual(values['EMAIL_BACKEND'], 'custom.Backend')
        self.assertFalse(values['EMAIL_USE_TLS'])

    def test_blank_bootstrap_values_still_use_project_domain(self):
        values = project_email_settings({'DOMAIN': 'two.example', 'DEFAULT_FROM_EMAIL': '',
                                        'PROJECT_ACCOUNT_EMAIL': '', 'EMAIL_BACKEND': '',
                                        'DJANGO_DEBUG': 'true'})
        self.assertEqual(values['DEFAULT_FROM_EMAIL'], '$@two.example')
        self.assertEqual(values['EMAIL_BACKEND'], 'django.core.mail.backends.console.EmailBackend')
        self.assertEqual(project_email_settings({'MAILBOX_DOMAIN': 'mail.example'})['DEFAULT_FROM_EMAIL'],
                         '$@mail.example')


@override_settings(CLOUDFLARE_ACCOUNT_ID='a' * 32, CLOUDFLARE_EMAIL_API_TOKEN='test-token',
                   BREVO_API_KEY='test-key', EMAIL_TIMEOUT=20)
class HTTPSDeliveryTest(SimpleTestCase):
    def message(self):
        message = EmailMultiAlternatives('Order', 'Receipt', '$@shop.example', ['to@example.test'],
                                        cc=['cc@example.test'], bcc=['private@example.test'],
                                        reply_to=['$@shop.example'],
                                        headers={'Message-ID': '<order@shop.example>',
                                                 'In-Reply-To': '<question@example.test>'})
        message.attach_alternative('<p>Receipt</p>', 'text/html')
        message.attach('receipt.txt', 'Bücher', 'text/plain')
        return message

    def send_payload(self, backend, result):
        response = MagicMock()
        response.__enter__.return_value.read.return_value = json.dumps(result).encode()
        with patch('mailroom.backends.urlopen', return_value=response) as provider:
            self.assertEqual(backend.send_messages([self.message()]), 1)
        return json.loads(provider.call_args.args[0].data)

    @override_settings(EMAIL_BACKEND='mailroom.backends.CloudflareEmailBackend')
    def test_cloudflare_preserves_private_recipients_threads_and_files(self):
        payload = self.send_payload(CloudflareEmailBackend(), {'success': True, 'result': {
            'queued': ['to@example.test', 'cc@example.test', 'private@example.test']}})
        self.assertTrue(email_delivery_ready())
        self.assertEqual(payload['to'], ['to@example.test'])
        self.assertEqual(payload['cc'], ['cc@example.test'])
        self.assertEqual(payload['bcc'], ['private@example.test'])
        self.assertEqual(payload['reply_to'], '$@shop.example')
        self.assertEqual(payload['headers']['In-Reply-To'], '<question@example.test>')
        self.assertEqual(base64.b64decode(payload['attachments'][0]['content']).decode(), 'Bücher')
        self.assertEqual(payload['attachments'][0]['filename'], 'receipt.txt')
        self.assertEqual(payload['html'], '<p>Receipt</p>')

    @override_settings(EMAIL_BACKEND='mailroom.backends.BrevoEmailBackend')
    def test_brevo_preserves_recipients_reply_to_and_files(self):
        payload = self.send_payload(BrevoEmailBackend(), {'messageId': 'provider-id'})
        self.assertTrue(email_delivery_ready())
        self.assertEqual(payload['to'], [{'email': 'to@example.test'}])
        self.assertEqual(payload['bcc'], [{'email': 'private@example.test'}])
        self.assertEqual(payload['replyTo'], {'email': '$@shop.example'})
        self.assertEqual(base64.b64decode(payload['attachment'][0]['content']).decode(), 'Bücher')

    def test_partial_recipient_acceptance_is_not_success(self):
        response = MagicMock()
        response.__enter__.return_value.read.return_value = b'{"success":true,"result":{"queued":["to@example.test"]}}'
        with patch('mailroom.backends.urlopen', return_value=response):
            with self.assertRaises(RuntimeError):
                CloudflareEmailBackend().send_messages([self.message()])
