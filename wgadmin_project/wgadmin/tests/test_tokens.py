from datetime import timedelta

from django.test import TestCase
from django.urls import reverse
from django.utils import timezone

from wgadmin.models import ConfigDownloadToken


class ConfigDownloadTokenTest(TestCase):
    def test_expiration_property(self):
        token = ConfigDownloadToken.create_token(client_identifier="abc", ttl_minutes=0)
        token.expires_at = timezone.now() - timedelta(minutes=1)
        token.save()
        self.assertTrue(token.is_expired)


class PublicConfigViewTest(TestCase):
    def test_invalid_token(self):
        response = self.client.get(reverse("public-config", kwargs={"token": "missing"}))
        self.assertEqual(response.status_code, 404)

    def test_expired_token(self):
        token = ConfigDownloadToken.create_token(client_identifier="abc", ttl_minutes=-1)
        response = self.client.get(reverse("public-config", kwargs={"token": token.token}))
        self.assertEqual(response.status_code, 404)
        token.refresh_from_db()
        self.assertFalse(token.is_active)
