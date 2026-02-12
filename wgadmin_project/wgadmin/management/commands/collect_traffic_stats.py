"""Management command to collect WireGuard traffic statistics from a dump file."""

from django.core.management.base import BaseCommand, CommandError

from wgadmin.models import TrafficSnapshot
from wgadmin.services.wireguard import WireGuardService


class Command(BaseCommand):
    help = "Collects WireGuard traffic statistics from a wg dump file"

    def add_arguments(self, parser):
        parser.add_argument(
            "dump_file",
            type=str,
            help="Path to the file with wg show dump output",
        )

    def handle(self, *args, **options):
        dump_file = options["dump_file"]

        try:
            with open(dump_file, "r") as f:
                lines = f.readlines()
        except FileNotFoundError:
            raise CommandError(f"Dump file not found: {dump_file}")
        except PermissionError:
            raise CommandError(f"Permission denied reading: {dump_file}")

        # Get mapping of pubkey -> client_name from config
        wg_service = WireGuardService()
        try:
            peers = wg_service.list_peers(include_runtime=False)
        except Exception as e:
            self.stderr.write(self.style.WARNING(f"Could not read WG config: {e}"))
            peers = []

        pubkey_to_name = {peer.public_key: peer.name for peer in peers}

        # Process each line from dump (skip first line - it's the interface info)
        # Format: pubkey, preshared-key, endpoint, allowed-ips, latest-handshake, rx-bytes, tx-bytes
        created_count = 0
        for line in lines[1:]:
            parts = line.strip().split("\t")
            if len(parts) < 7:
                continue

            pubkey = parts[0]
            # parts[1] = preshared-key
            # parts[2] = endpoint
            # parts[3] = allowed-ips
            # parts[4] = latest-handshake
            rx_bytes_str = parts[5]
            tx_bytes_str = parts[6]

            try:
                rx_bytes = int(rx_bytes_str)
                tx_bytes = int(tx_bytes_str)
            except ValueError:
                self.stderr.write(
                    self.style.WARNING(f"Invalid bytes value for peer {pubkey[:8]}...")
                )
                continue

            TrafficSnapshot.objects.create(
                public_key=pubkey,
                client_name=pubkey_to_name.get(pubkey, ""),
                rx_bytes=rx_bytes,
                tx_bytes=tx_bytes,
                total_bytes=rx_bytes + tx_bytes,
            )
            created_count += 1

        self.stdout.write(
            self.style.SUCCESS(f"Created {created_count} traffic snapshot records")
        )
