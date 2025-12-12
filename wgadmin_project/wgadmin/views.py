import base64
import logging
import re
from datetime import timedelta
from io import BytesIO
from typing import Any, Dict

import qrcode
from django.conf import settings
from django.contrib import messages
from django.contrib.auth.decorators import login_required, user_passes_test
from django.http import FileResponse, Http404, HttpRequest, HttpResponse
from django.shortcuts import get_object_or_404, redirect, render
from django.urls import reverse
from django.utils import timezone

from .forms import ActivateClientForm, ClientCreateForm, DeleteClientForm, ToggleClientForm
from .models import AuditLog, ConfigDownloadToken
from .services.wireguard import WireGuardError, WireGuardService

logger = logging.getLogger(__name__)

# Security: Pattern for valid identifiers (alphanumeric, dot, dash, underscore)
IDENTIFIER_PATTERN = re.compile(r"^[A-Za-z0-9._-]+$")


def _validate_identifier(identifier: str) -> bool:
    """Validate that identifier contains only safe characters."""
    return bool(IDENTIFIER_PATTERN.match(identifier))


def staff_required(view_func):
    decorated = login_required(user_passes_test(lambda u: u.is_staff)(view_func))
    return decorated


@staff_required
def client_list(request: HttpRequest) -> HttpResponse:
    service = WireGuardService()
    try:
        peers = service.list_peers(include_runtime=True)
    except WireGuardError as exc:
        logger.error("Failed to read WireGuard config: %s", exc)
        messages.error(request, "Unable to read WireGuard configuration. Please check server logs.")
        peers = []
    _cleanup_tokens()
    active_tokens = ConfigDownloadToken.objects.filter(is_active=True, expires_at__gt=timezone.now())
    token_map = {token.client_identifier: token for token in active_tokens}
    used_ips = sorted({ip for peer in peers for ip in peer.allowed_ips})
    used_names = sorted({peer.identifier for peer in peers})
    context = {
        "peers": peers,
        "create_form": ClientCreateForm(),
        "activate_form": ActivateClientForm(),
        "toggle_form": ToggleClientForm(),
        "delete_form": DeleteClientForm(),
        "token_map": token_map,
        "wg_config_path": settings.WG_CONFIG_PATH,
        "used_ips": used_ips,
        "used_names": used_names,
    }
    return render(request, "wgadmin/client_list.html", context)


@staff_required
def create_client(request: HttpRequest) -> HttpResponse:
    if request.method != "POST":
        raise Http404()
    form = ClientCreateForm(request.POST)
    if form.is_valid():
        service = WireGuardService()
        try:
            existing_peers = service.list_peers(include_runtime=False)
        except WireGuardError as exc:
            logger.error("Failed to read existing clients: %s", exc)
            messages.error(request, "Unable to read existing clients. Please check server logs.")
            return redirect("clients")
        requested_name = form.cleaned_data["name"]
        used_names = {peer.identifier for peer in existing_peers}
        if requested_name in used_names:
            messages.error(request, f"Name already exists: {requested_name}")
            return redirect("clients")
        used_ips = {ip for peer in existing_peers for ip in peer.allowed_ips}
        requested_ips = {ip.strip() for ip in form.cleaned_data["allowed_ips"].split(",") if ip.strip()}
        duplicate_ips = sorted(used_ips.intersection(requested_ips))
        if duplicate_ips:
            messages.error(request, f"IP already in use: {', '.join(duplicate_ips)}")
        else:
            try:
                service.create_peer(form.cleaned_data["name"], form.cleaned_data["allowed_ips"])
            except WireGuardError as exc:
                logger.error("Failed to create client %s: %s", form.cleaned_data["name"], exc)
                messages.error(request, "Could not create client. Please check server logs.")
            else:
                AuditLog.objects.create(
                    action="create",
                    client_identifier=form.cleaned_data["name"],
                    performed_by=request.user,
                    details={"allowed_ips": form.cleaned_data["allowed_ips"]},
                )
                messages.success(request, f"Client {form.cleaned_data['name']} created.")
    else:
        messages.error(request, "Invalid form submission.")
    return redirect("clients")


@staff_required
def toggle_client(request: HttpRequest, identifier: str, enable: bool) -> HttpResponse:
    if request.method != "POST":
        raise Http404()
    # Security: Validate identifier format
    if not _validate_identifier(identifier):
        logger.warning("Invalid identifier attempted: %s", identifier[:50])
        messages.error(request, "Invalid client identifier.")
        return redirect("clients")
    service = WireGuardService()
    try:
        service.set_peer_enabled(identifier, enable)
    except WireGuardError as exc:
        logger.error("Failed to toggle client %s: %s", identifier, exc)
        messages.error(request, "Unable to update client. Please check server logs.")
    else:
        AuditLog.objects.create(
            action="enable" if enable else "disable",
            client_identifier=identifier,
            performed_by=request.user,
        )
        messages.success(request, f"{identifier} {'enabled' if enable else 'disabled'}.")
    return redirect("clients")


@staff_required
def enable_client(request: HttpRequest, identifier: str) -> HttpResponse:
    return toggle_client(request, identifier, enable=True)


@staff_required
def disable_client(request: HttpRequest, identifier: str) -> HttpResponse:
    return toggle_client(request, identifier, enable=False)


@staff_required
def delete_client(request: HttpRequest, identifier: str) -> HttpResponse:
    if request.method != "POST":
        raise Http404()
    # Security: Validate identifier format
    if not _validate_identifier(identifier):
        logger.warning("Invalid identifier attempted for deletion: %s", identifier[:50])
        messages.error(request, "Invalid client identifier.")
        return redirect("clients")
    service = WireGuardService()
    try:
        service.delete_peer(identifier)
    except WireGuardError as exc:
        logger.error("Failed to delete client %s: %s", identifier, exc)
        messages.error(request, "Unable to delete client. Please check server logs.")
    else:
        AuditLog.objects.create(action="delete", client_identifier=identifier, performed_by=request.user)
        messages.success(request, f"{identifier} deleted.")
    return redirect("clients")


@staff_required
def activate_client(request: HttpRequest, identifier: str) -> HttpResponse:
    if request.method != "POST":
        raise Http404()
    # Security: Validate identifier format
    if not _validate_identifier(identifier):
        logger.warning("Invalid identifier attempted for activation: %s", identifier[:50])
        messages.error(request, "Invalid client identifier.")
        return redirect("clients")
    service = WireGuardService()
    peer = service.get_peer(identifier)
    if not peer:
        messages.error(request, "Client not found.")
        return redirect("clients")

    token = ConfigDownloadToken.create_token(client_identifier=peer.identifier, client_name=peer.name)
    AuditLog.objects.create(action="activate", client_identifier=peer.identifier, performed_by=request.user)
    activation_url = request.build_absolute_uri(reverse("public-config", kwargs={"token": token.token}))
    messages.success(request, f"Activated link for {peer.name}: {activation_url}")
    return redirect("clients")


def public_config(request: HttpRequest, token: str) -> HttpResponse:
    download_token = get_object_or_404(ConfigDownloadToken, token=token, is_active=True)
    if download_token.is_expired:
        download_token.is_active = False
        download_token.save(update_fields=["is_active"])
        return render(request, "wgadmin/link_expired.html", status=404)

    service = WireGuardService()
    peer = service.get_peer(download_token.client_identifier)
    if not peer:
        raise Http404("Client not found")

    try:
        config_text = service.read_config_for_peer(peer)
    except WireGuardError:
        raise Http404("Config not found")
    qr_data_url = _qr_data_url(config_text)
    context = {
        "peer": peer,
        "token": download_token,
        "qr_data_url": qr_data_url,
        "download_url": reverse("public-config-download", kwargs={"token": token}),
    }
    return render(request, "wgadmin/public_config.html", context)


def public_config_download(request: HttpRequest, token: str) -> FileResponse:
    download_token = get_object_or_404(ConfigDownloadToken, token=token, is_active=True)
    if download_token.is_expired:
        download_token.is_active = False
        download_token.save(update_fields=["is_active"])
        raise Http404()

    service = WireGuardService()
    peer = service.get_peer(download_token.client_identifier)
    if not peer:
        raise Http404()
    config_path = service.get_config_path(peer)
    if not config_path.exists():
        raise Http404()
    return FileResponse(config_path.open("rb"), as_attachment=True, filename=f"{peer.identifier}.conf")


def _qr_data_url(text: str) -> str:
    qr = qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_M)
    qr.add_data(text)
    qr.make(fit=True)
    img = qr.make_image(fill_color="black", back_color="white")
    buf = BytesIO()
    img.save(buf, format="PNG")
    encoded = base64.b64encode(buf.getvalue()).decode("ascii")
    return f"data:image/png;base64,{encoded}"


def _cleanup_tokens() -> None:
    """Deactivate expired tokens and delete old ones."""
    now = timezone.now()
    # Deactivate expired tokens
    expired_count = ConfigDownloadToken.objects.filter(is_active=True, expires_at__lte=now).update(is_active=False)
    if expired_count:
        logger.info("Deactivated %d expired tokens", expired_count)
    # Delete tokens older than 30 days to prevent database bloat
    cutoff = now - timedelta(days=30)
    deleted_count, _ = ConfigDownloadToken.objects.filter(created_at__lt=cutoff).delete()
    if deleted_count:
        logger.info("Deleted %d old tokens", deleted_count)
