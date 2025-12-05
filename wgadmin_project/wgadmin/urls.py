from django.urls import path

from . import views

urlpatterns = [
    path("", views.client_list, name="clients"),
    path("clients/create/", views.create_client, name="client-create"),
    path("clients/<path:identifier>/enable/", views.enable_client, name="client-enable"),
    path("clients/<path:identifier>/disable/", views.disable_client, name="client-disable"),
    path("clients/<path:identifier>/delete/", views.delete_client, name="client-delete"),
    path("clients/<path:identifier>/activate/", views.activate_client, name="client-activate"),
    path("config/<str:token>/", views.public_config, name="public-config"),
    path("config/<str:token>/download/", views.public_config_download, name="public-config-download"),
]
