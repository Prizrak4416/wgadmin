"""Management command to clean up old traffic statistics."""

from datetime import timedelta

from django.core.management.base import BaseCommand
from django.utils import timezone

from wgadmin.models import TrafficSnapshot


class Command(BaseCommand):
    help = "Deletes traffic statistics older than a specified number of days (default: 90)"

    def add_arguments(self, parser):
        parser.add_argument(
            "--days",
            type=int,
            default=90,
            help="Delete records older than this many days (default: 90)",
        )
        parser.add_argument(
            "--dry-run",
            action="store_true",
            help="Show what would be deleted without actually deleting",
        )

    def handle(self, *args, **options):
        days = options["days"]
        dry_run = options["dry_run"]

        cutoff_date = timezone.now() - timedelta(days=days)

        old_records = TrafficSnapshot.objects.filter(timestamp__lt=cutoff_date)
        count = old_records.count()

        if dry_run:
            self.stdout.write(
                self.style.WARNING(
                    f"DRY RUN: Would delete {count} records older than {days} days"
                )
            )
            return

        if count == 0:
            self.stdout.write(
                self.style.SUCCESS(f"No records older than {days} days to delete")
            )
            return

        deleted_count, _ = old_records.delete()
        self.stdout.write(
            self.style.SUCCESS(
                f"Deleted {deleted_count} traffic snapshot records older than {days} days"
            )
        )
