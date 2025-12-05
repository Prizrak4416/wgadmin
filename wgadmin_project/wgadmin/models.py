import secrets
from datetime import timedelta
from typing import Optional

from django.conf import settings
from django.db import models
from django.utils import timezone


class ConfigDownloadToken(models.Model):
    client_identifier = models.CharField(max_length=255, db_index=True)
    token = models.CharField(max_length=128, unique=True, db_index=True)
    created_at = models.DateTimeField(auto_now_add=True)
    expires_at = models.DateTimeField()
    is_active = models.BooleanField(default=True)
    client_name = models.CharField(max_length=255, blank=True, default="")

    class Meta:
        ordering = ("-created_at",)

    def __str__(self) -> str:
        return f"{self.client_identifier} ({'active' if self.is_active else 'inactive'})"

    @property
    def is_expired(self) -> bool:
        return timezone.now() >= self.expires_at

    @classmethod
    def create_token(cls, client_identifier: str, client_name: str = "", ttl_minutes: int = 60) -> "ConfigDownloadToken":
        token = secrets.token_urlsafe(48)
        expires_at = timezone.now() + timedelta(minutes=ttl_minutes)
        return cls.objects.create(
            client_identifier=client_identifier,
            client_name=client_name,
            token=token,
            expires_at=expires_at,
        )


class AuditLog(models.Model):
    ACTION_CHOICES = [
        ("create", "create"),
        ("delete", "delete"),
        ("enable", "enable"),
        ("disable", "disable"),
        ("activate", "activate"),
        ("deactivate", "deactivate"),
    ]

    action = models.CharField(max_length=32, choices=ACTION_CHOICES)
    client_identifier = models.CharField(max_length=255)
    performed_by = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.SET_NULL, null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    details = models.JSONField(blank=True, null=True)

    class Meta:
        ordering = ("-created_at",)

    def __str__(self) -> str:
        return f"{self.action} {self.client_identifier} at {self.created_at.isoformat()}"
