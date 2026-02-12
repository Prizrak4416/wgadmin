"""Tests for traffic monitoring functionality."""

import tempfile
from datetime import timedelta
from io import StringIO
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.core.management import call_command
from django.core.management.base import CommandError
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone

from wgadmin.models import TrafficSnapshot
from wgadmin.services.wireguard import WireGuardService


class TrafficSnapshotModelTest(TestCase):
    def test_create_snapshot(self):
        snapshot = TrafficSnapshot.objects.create(
            public_key="testkey123456789012345678901234567890123=",
            client_name="test_client",
            rx_bytes=1000,
            tx_bytes=2000,
            total_bytes=3000,
        )
        self.assertEqual(snapshot.rx_bytes, 1000)
        self.assertEqual(snapshot.tx_bytes, 2000)
        self.assertEqual(snapshot.total_bytes, 3000)

    def test_auto_total_bytes(self):
        snapshot = TrafficSnapshot(
            public_key="testkey123456789012345678901234567890123=",
            rx_bytes=1000,
            tx_bytes=2000,
        )
        snapshot.save()
        self.assertEqual(snapshot.total_bytes, 3000)

    def test_str_with_name(self):
        snapshot = TrafficSnapshot.objects.create(
            public_key="testkey123456789012345678901234567890123=",
            client_name="my_client",
            rx_bytes=0,
            tx_bytes=0,
            total_bytes=0,
        )
        self.assertIn("my_client", str(snapshot))

    def test_str_without_name(self):
        snapshot = TrafficSnapshot.objects.create(
            public_key="testkey123456789012345678901234567890123=",
            client_name="",
            rx_bytes=0,
            tx_bytes=0,
            total_bytes=0,
        )
        self.assertIn("testkey1", str(snapshot))

    def test_ordering(self):
        old = TrafficSnapshot.objects.create(
            public_key="key1",
            rx_bytes=0,
            tx_bytes=0,
            total_bytes=0,
        )
        old.timestamp = timezone.now() - timedelta(hours=1)
        old.save(update_fields=["timestamp"])

        new = TrafficSnapshot.objects.create(
            public_key="key2",
            rx_bytes=0,
            tx_bytes=0,
            total_bytes=0,
        )

        snapshots = list(TrafficSnapshot.objects.all())
        self.assertEqual(snapshots[0].public_key, "key2")
        self.assertEqual(snapshots[1].public_key, "key1")


class CollectTrafficStatsCommandTest(TestCase):
    def test_parse_dump_file(self):
        dump_content = """wg0\tprivkey\t51820\tfwmark
pubkey1\t(none)\t1.2.3.4:51820\t10.0.0.2/32\t1609459200\t1000\t2000
pubkey2\t(none)\t5.6.7.8:51820\t10.0.0.3/32\t1609459200\t3000\t4000
"""
        with tempfile.NamedTemporaryFile(mode="w", suffix=".txt", delete=False) as f:
            f.write(dump_content)
            dump_file = f.name

        out = StringIO()
        with patch.object(WireGuardService, "list_peers", return_value=[]):
            call_command("collect_traffic_stats", dump_file, stdout=out)

        self.assertEqual(TrafficSnapshot.objects.count(), 2)

        snap1 = TrafficSnapshot.objects.get(public_key="pubkey1")
        self.assertEqual(snap1.rx_bytes, 1000)
        self.assertEqual(snap1.tx_bytes, 2000)

        snap2 = TrafficSnapshot.objects.get(public_key="pubkey2")
        self.assertEqual(snap2.rx_bytes, 3000)
        self.assertEqual(snap2.tx_bytes, 4000)

    def test_missing_file(self):
        out = StringIO()
        with self.assertRaises(CommandError):
            call_command(
                "collect_traffic_stats",
                "/nonexistent/file.txt",
                stdout=out,
            )


class CleanupTrafficStatsCommandTest(TestCase):
    def test_cleanup_old_records(self):
        old = TrafficSnapshot.objects.create(
            public_key="oldkey",
            rx_bytes=0,
            tx_bytes=0,
            total_bytes=0,
        )
        old.timestamp = timezone.now() - timedelta(days=100)
        old.save(update_fields=["timestamp"])

        new = TrafficSnapshot.objects.create(
            public_key="newkey",
            rx_bytes=0,
            tx_bytes=0,
            total_bytes=0,
        )

        out = StringIO()
        call_command("cleanup_traffic_stats", "--days=90", stdout=out)

        self.assertEqual(TrafficSnapshot.objects.count(), 1)
        self.assertEqual(TrafficSnapshot.objects.first().public_key, "newkey")

    def test_dry_run(self):
        old = TrafficSnapshot.objects.create(
            public_key="oldkey",
            rx_bytes=0,
            tx_bytes=0,
            total_bytes=0,
        )
        old.timestamp = timezone.now() - timedelta(days=100)
        old.save(update_fields=["timestamp"])

        out = StringIO()
        call_command("cleanup_traffic_stats", "--days=90", "--dry-run", stdout=out)

        self.assertEqual(TrafficSnapshot.objects.count(), 1)
        self.assertIn("DRY RUN", out.getvalue())


class TrafficStatsViewTest(TestCase):
    def setUp(self):
        User = get_user_model()
        self.staff_user = User.objects.create_user(
            username="staff",
            password="testpass",
            is_staff=True,
        )
        self.regular_user = User.objects.create_user(
            username="regular",
            password="testpass",
            is_staff=False,
        )

    def test_requires_staff(self):
        response = self.client.get(reverse("traffic-stats"))
        self.assertEqual(response.status_code, 302)

        self.client.login(username="regular", password="testpass")
        response = self.client.get(reverse("traffic-stats"))
        self.assertEqual(response.status_code, 302)

    def test_staff_can_access(self):
        self.client.login(username="staff", password="testpass")
        response = self.client.get(reverse("traffic-stats"))
        self.assertEqual(response.status_code, 200)
        self.assertTemplateUsed(response, "wgadmin/traffic_stats.html")

    def test_period_parameter(self):
        self.client.login(username="staff", password="testpass")

        for period in ["hour", "day", "week", "month"]:
            response = self.client.get(reverse("traffic-stats") + f"?period={period}")
            self.assertEqual(response.status_code, 200)
            self.assertContains(response, period.capitalize())

    def test_invalid_period_defaults_to_day(self):
        self.client.login(username="staff", password="testpass")
        response = self.client.get(reverse("traffic-stats") + "?period=invalid")
        self.assertEqual(response.status_code, 200)


class GetTrafficStatsServiceTest(TestCase):
    def test_empty_stats(self):
        service = WireGuardService()
        stats = service.get_traffic_stats(period="day")

        self.assertEqual(stats["snapshots"], [])
        self.assertEqual(stats["by_client"], [])
        self.assertEqual(stats["total_traffic"], 0)
        self.assertEqual(stats["period"], "day")

    def test_stats_with_data(self):
        TrafficSnapshot.objects.create(
            public_key="key1",
            client_name="client1",
            rx_bytes=1000,
            tx_bytes=2000,
            total_bytes=3000,
        )
        TrafficSnapshot.objects.create(
            public_key="key1",
            client_name="client1",
            rx_bytes=2000,
            tx_bytes=4000,
            total_bytes=6000,
        )

        service = WireGuardService()
        stats = service.get_traffic_stats(period="day")

        self.assertEqual(len(stats["by_client"]), 1)
        self.assertEqual(stats["by_client"][0]["client_name"], "client1")
        self.assertEqual(stats["by_client"][0]["traffic_delta"], 3000)

    def test_period_filtering(self):
        old = TrafficSnapshot.objects.create(
            public_key="key1",
            rx_bytes=1000,
            tx_bytes=1000,
            total_bytes=2000,
        )
        old.timestamp = timezone.now() - timedelta(days=2)
        old.save(update_fields=["timestamp"])

        new = TrafficSnapshot.objects.create(
            public_key="key1",
            rx_bytes=500,
            tx_bytes=500,
            total_bytes=1000,
        )

        service = WireGuardService()
        stats = service.get_traffic_stats(period="day")

        self.assertEqual(len(stats["snapshots"]), 1)
