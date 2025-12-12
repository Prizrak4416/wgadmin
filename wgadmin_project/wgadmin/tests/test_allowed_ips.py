import os
from unittest import mock

from django.test import SimpleTestCase

from wgadmin.forms import ClientCreateForm
from wgadmin.views import get_suggested_allowed_ips


class AllowedIpsValidationTest(SimpleTestCase):
    def test_form_rejects_duplicate_allowed_ips(self):
        form = ClientCreateForm(
            data={"name": "client1", "allowed_ips": "10.0.0.5/32"},
            used_ips={"10.0.0.5/32"},
        )
        self.assertFalse(form.is_valid())
        self.assertIn("allowed_ips", form.errors)
        self.assertIn("IP already in use", form.errors["allowed_ips"][0])

    @mock.patch.dict(os.environ, {"SERVER_WG_IPV4_PREFIX": ""})
    def test_suggests_next_available_allowed_ip(self):
        suggestion = get_suggested_allowed_ips({"10.0.0.2/32", "10.0.0.3/32"})
        self.assertEqual(suggestion, "10.0.0.4/32")
