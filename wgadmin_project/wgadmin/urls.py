from django.urls import path, re_path

from . import views

# Security: Restrict identifiers to safe characters only (alphanumeric, dot, dash, underscore)
# This prevents path traversal and shell injection attempts
IDENTIFIER_PATTERN = r"[A-Za-z0-9._-]+"

urlpatterns = [
    path("", views.client_list, name="clients"),
    path("clients/create/", views.create_client, name="client-create"),
    re_path(
        rf"^clients/(?P<identifier>{IDENTIFIER_PATTERN})/enable/$",
        views.enable_client,
        name="client-enable",
    ),
    re_path(
        rf"^clients/(?P<identifier>{IDENTIFIER_PATTERN})/disable/$",
        views.disable_client,
        name="client-disable",
    ),
    re_path(
        rf"^clients/(?P<identifier>{IDENTIFIER_PATTERN})/delete/$",
        views.delete_client,
        name="client-delete",
    ),
    re_path(
        rf"^clients/(?P<identifier>{IDENTIFIER_PATTERN})/activate/$",
        views.activate_client,
        name="client-activate",
    ),
    path("config/<str:token>/", views.public_config, name="public-config"),
    path("config/<str:token>/download/", views.public_config_download, name="public-config-download"),
]
