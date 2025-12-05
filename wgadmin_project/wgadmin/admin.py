from django.contrib import admin

from .models import ConfigDownloadToken


@admin.register(ConfigDownloadToken)
class ConfigDownloadTokenAdmin(admin.ModelAdmin):
    list_display = ("client_identifier", "token", "is_active", "created_at", "expires_at")
    search_fields = ("client_identifier", "token")
    list_filter = ("is_active",)
