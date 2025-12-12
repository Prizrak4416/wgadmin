import base64
import logging
import os
import re
from datetime import timedelta
from io import BytesIO
from ipaddress import IPv4Network, ip_network
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

# Security: Pattern for valid identifiers (alphanumeric, dot, dash, underscore, plus, equals)
IDENTIFIER_PATTERN = re.compile(r"^[A-Za-z0-9._+=-]+$")


def _validate_identifier(identifier: str) -> bool:
    """Validate that identifier contains only safe characters."""
    return bool(IDENTIFIER_PATTERN.match(identifier))


def staff_required(view_func):
    decorated = login_required(user_passes_test(lambda u: u.is_staff)(view_func))
    return decorated


def _safe_list_peers(request: HttpRequest, service: WireGuardService, include_runtime: bool = True):
    try:
        return service.list_peers(include_runtime=include_runtime)
    except WireGuardError as exc:
        logger.error("Failed to read WireGuard config: %s", exc)
        messages.error(request, "Unable to read WireGuard configuration. Please check server logs.")
        return []


def get_suggested_allowed_ips(existing_ips: set[str]) -> str:
    """Return the next available /32 address based on config data or env prefix."""
    def _normalize_prefix(raw_prefix: str) -> str:
        raw_prefix = (raw_prefix or "").strip()
        if not raw_prefix:
            return ""
        try:
            network = ip_network(raw_prefix if "/" in raw_prefix else f"{raw_prefix}/24", strict=False)
            if isinstance(network, IPv4Network):
                parts = str(network.network_address).split(".")
                return ".".join(parts[:3]) + "."
        except ValueError:
            pass
        parts = raw_prefix.split(".")
        if len(parts) >= 3:
            return ".".join(parts[:3]) + "."
        return ""

    prefix = _normalize_prefix(os.environ.get("SERVER_WG_IPV4_PREFIX", ""))
    ipv4_networks: list[IPv4Network] = []
    for raw_ip in existing_ips:
        try:
            network = ip_network(raw_ip, strict=False)
        except ValueError:
            continue
        if isinstance(network, IPv4Network):
            ipv4_networks.append(network)
            if not prefix:
                prefix = _normalize_prefix(str(network.network_address))
    if not prefix:
        prefix = _normalize_prefix("10.0.0.")

    used_values = {f"{net.network_address}/{net.prefixlen}" for net in ipv4_networks}
    for host in range(2, 255):
        candidate = f"{prefix}{host}/32"
        if candidate not in used_values:
            return candidate
    return f"{prefix}2/32"


def _build_client_context(
    request: HttpRequest,
    service: WireGuardService,
    peers,
    create_form: ClientCreateForm | None = None,
) -> Dict[str, Any]:
    used_ips = sorted({ip for peer in peers for ip in peer.allowed_ips})
    used_names = sorted({peer.identifier for peer in peers})
    suggested_allowed_ips = get_suggested_allowed_ips(set(used_ips))
    if create_form is None:
        create_form = ClientCreateForm(
            initial={"allowed_ips": suggested_allowed_ips},
            used_ips=used_ips,
            used_names=used_names,
        )
    _cleanup_tokens()
    active_tokens = ConfigDownloadToken.objects.filter(is_active=True, expires_at__gt=timezone.now())
    token_map = {token.client_identifier: token for token in active_tokens}
    base_url = request.build_absolute_uri("/")[:-1]  # remove trailing slash
    return {
        "peers": peers,
        "create_form": create_form,
        "activate_form": ActivateClientForm(),
        "toggle_form": ToggleClientForm(),
        "delete_form": DeleteClientForm(),
        "token_map": token_map,
        "wg_config_path": settings.WG_CONFIG_PATH,
        "used_ips": used_ips,
        "used_names": used_names,
        "base_url": base_url,
    }


@staff_required
def client_list(request: HttpRequest) -> HttpResponse:
    service = WireGuardService()
    peers = _safe_list_peers(request, service, include_runtime=True)
    context = _build_client_context(request, service, peers)
    return render(request, "wgadmin/client_list.html", context)


@staff_required
def create_client(request: HttpRequest) -> HttpResponse:
    if request.method != "POST":
        raise Http404()
    service = WireGuardService()
    peers = _safe_list_peers(request, service, include_runtime=False)
    used_ips = {ip for peer in peers for ip in peer.allowed_ips}
    used_names = {peer.identifier for peer in peers}

    form = ClientCreateForm(request.POST, used_ips=used_ips, used_names=used_names)
    if form.is_valid():
        try:
            service.create_peer(form.cleaned_data["name"], form.cleaned_data["allowed_ips"])
        except WireGuardError as exc:
            logger.error("Failed to create client %s: %s", form.cleaned_data["name"], exc)
            message = str(exc)
            lowered = message.lower()
            if "already in use" in lowered:
                form.add_error("allowed_ips", "IP already in use.")
            elif "name" in lowered and "exists" in lowered:
                form.add_error("name", "Name already exists.")
            else:
                messages.error(request, "Could not create client. Please check server logs.")
        else:
            AuditLog.objects.create(
                action="create",
                client_identifier=form.cleaned_data["name"],
                performed_by=request.user,
                details={"allowed_ips": form.cleaned_data["allowed_ips"]},
            )
            messages.success(request, f"Client {form.cleaned_data['name']} created.")
            return redirect("clients")

    context = _build_client_context(request, service, peers, create_form=form)
    return render(request, "wgadmin/client_list.html", context, status=400)


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
