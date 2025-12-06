from __future__ import annotations

import json
import re
import subprocess
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Dict, Iterable, List, Optional

from django.conf import settings
from django.utils import timezone


class WireGuardError(Exception):
    """Raised when the WireGuard service encounters a problem."""


class WireGuardScriptError(WireGuardError):
    """Raised when an underlying management script fails."""


@dataclass
class WireGuardPeer:
    identifier: str
    name: str
    public_key: str
    allowed_ips: List[str]
    endpoint: Optional[str] = None
    persistent_keepalive: Optional[int] = None
    latest_handshake: Optional[datetime] = None
    transfer_rx: Optional[int] = None
    transfer_tx: Optional[int] = None
    is_enabled: bool = True
    raw_block: Optional[List[str]] = None


class WireGuardService:
    def __init__(
        self,
        config_path: Path | str | None = None,
        interface: str | None = None,
        scripts_dir: Path | str | None = None,
    ):
        self.config_path = Path(config_path or settings.WG_CONFIG_PATH)
        self.interface = interface or settings.WG_INTERFACE
        self.scripts_dir = Path(scripts_dir or settings.WG_SCRIPTS_DIR)
        self.client_config_dir = settings.WG_CLIENT_CONFIG_DIR
        self.script_timeout = getattr(settings, "WG_SCRIPT_TIMEOUT", 15)
        # Use sudo by default so scripts can run with root privileges via sudoers; can be disabled via WG_USE_SUDO.
        self.use_sudo = getattr(settings, "WG_USE_SUDO", True)
        self.sudo_bin = getattr(settings, "WG_SUDO_BIN", "sudo")

    # -------------------- Parsing --------------------
    def list_peers(self, include_runtime: bool = True) -> List[WireGuardPeer]:
        peers = self._parse_config()
        if include_runtime:
            try:
                runtime = self._runtime_peer_map()
            except WireGuardError:
                runtime = {}
            for peer in peers:
                status = runtime.get(peer.public_key)
                if status:
                    peer.latest_handshake = status.get("latest_handshake")
                    peer.transfer_rx = status.get("transfer_rx")
                    peer.transfer_tx = status.get("transfer_tx")
                    peer.persistent_keepalive = status.get("persistent_keepalive")
                    peer.endpoint = status.get("endpoint")
        return peers

    def get_peer(self, identifier: str) -> Optional[WireGuardPeer]:
        identifier = identifier.strip()
        for peer in self.list_peers(include_runtime=True):
            if peer.identifier == identifier or peer.public_key == identifier:
                return peer
        return None

    def _parse_config(self) -> List[WireGuardPeer]:
        lines = self._read_config_lines()
        peers: List[WireGuardPeer] = []
        i = 0
        while i < len(lines):
            line = lines[i].strip()
            if self._is_peer_header(line):
                name = self._extract_name(lines, i)
                block_lines, jump_to = self._collect_block(lines, i)
                peer = self._parse_peer_block(block_lines, name)
                if peer:
                    peers.append(peer)
                i = jump_to
                continue
            i += 1
        return peers

    def _read_config_lines(self) -> List[str]:
        if self.use_sudo:
            data = self._run_script("wg_read_config.sh", {}).get("config", "")
            if not data:
                raise WireGuardError(f"Unable to read config via script: {self.config_path}")
            return data.splitlines()
        try:
            return self.config_path.read_text(encoding="utf-8").splitlines()
        except PermissionError as exc:
            raise WireGuardError(f"Permission denied reading config: {self.config_path}") from exc
        except FileNotFoundError as exc:
            raise WireGuardError(f"Config path not found: {self.config_path}") from exc

    def _is_peer_header(self, line: str) -> bool:
        normalized = line.lstrip("#").strip()
        return normalized.lower().startswith("[peer]")

    def _collect_block(self, lines: List[str], start_index: int) -> tuple[list[str], int]:
        block: list[str] = []
        j = start_index
        while j < len(lines):
            if j != start_index and self._is_peer_header(lines[j]):
                break
            block.append(lines[j])
            j += 1
        return block, j

    def _extract_name(self, lines: List[str], start_index: int) -> Optional[str]:
        k = start_index - 1
        while k >= 0 and lines[k].strip().startswith("#"):
            comment = lines[k].strip().lstrip("#").strip()
            if comment:
                if comment.lower().startswith("name:"):
                    return comment.split(":", 1)[1].strip()
                return comment
            k -= 1
        return None

    def _parse_peer_block(self, block_lines: List[str], name: Optional[str]) -> Optional[WireGuardPeer]:
        is_enabled = any(line.strip() and not line.strip().startswith("#") for line in block_lines)
        data: Dict[str, str] = {}
        for raw_line in block_lines:
            line = raw_line.lstrip("#").strip()
            if "=" not in line:
                continue
            key, value = [part.strip() for part in line.split("=", 1)]
            data[key.lower()] = value

        public_key = data.get("publickey")
        if not public_key:
            return None

        allowed_ips = [ip.strip() for ip in data.get("allowedips", "").split(",") if ip.strip()]
        persistent_keepalive = None
        if "persistentkeepalive" in data:
            try:
                persistent_keepalive = int(data["persistentkeepalive"])
            except ValueError:
                persistent_keepalive = None

        identifier = name or public_key
        return WireGuardPeer(
            identifier=identifier,
            name=name or public_key[:12],
            public_key=public_key,
            allowed_ips=allowed_ips,
            endpoint=data.get("endpoint"),
            persistent_keepalive=persistent_keepalive,
            is_enabled=is_enabled,
            raw_block=block_lines,
        )

    # -------------------- Runtime data --------------------
    def _runtime_peer_map(self) -> Dict[str, Dict]:
        try:
            proc = subprocess.run(
                ["wg", "show", self.interface, "dump"],
                check=True,
                capture_output=True,
                text=True,
            )
        except FileNotFoundError as exc:
            raise WireGuardError("wg binary not found on PATH") from exc
        except subprocess.CalledProcessError as exc:
            raise WireGuardError(f"wg show failed: {exc.stderr}") from exc

        lines = proc.stdout.splitlines()
        status: Dict[str, Dict] = {}
        # dump format: private-key, public-key, preshared-key, endpoint, allowed-ips,
        # latest-handshake, transfer-rx, transfer-tx, persistent-keepalive
        for line in lines[1:]:
            parts = line.split("\t")
            if len(parts) < 9:
                continue
            public_key = parts[1]
            latest_handshake = int(parts[5]) if parts[5].isdigit() else 0
            status[public_key] = {
                "endpoint": parts[3] if parts[3] != "(none)" else None,
                "allowed_ips": parts[4],
                "latest_handshake": (
                    datetime.fromtimestamp(latest_handshake, tz=timezone.utc) if latest_handshake else None
                ),
                "transfer_rx": int(parts[6]),
                "transfer_tx": int(parts[7]),
                "persistent_keepalive": int(parts[8]) if parts[8].isdigit() else None,
            }
        return status

    # -------------------- Script wrappers --------------------
    def create_peer(self, name: str, allowed_ips: str = "0.0.0.0/0") -> Dict:
        return self._run_script("wg_create_peer.sh", ["--name", name, "--allowed-ips", allowed_ips])

    def delete_peer(self, identifier: str) -> Dict:
        return self._run_script("wg_delete_peer.sh", ["--id", identifier])

    def set_peer_enabled(self, identifier: str, enabled: bool) -> Dict:
        flag = "--enable" if enabled else "--disable"
        return self._run_script("wg_toggle_peer.sh", [flag, "--id", identifier])

    def generate_qr(self, identifier: str) -> Dict:
        return self._run_script("wg_generate_qr.sh", ["--id", identifier])

    def _run_script(self, script_name: str, args: Iterable[str] | Dict[str, str]) -> Dict:
        script_path = self.scripts_dir / script_name
        if not script_path.exists():
            raise WireGuardError(f"Script not found: {script_path}")
        if isinstance(args, dict):
            normalized_args: list[str] = []
            for key, value in args.items():
                normalized_args.extend([str(key), str(value)])
            args = normalized_args
        cmd = [str(script_path), *args]
        if self.use_sudo:
            cmd = [self.sudo_bin, *cmd]
        try:
            print(cmd)
            proc = subprocess.run(cmd, capture_output=True, text=True, check=True, timeout=self.script_timeout)
        except subprocess.TimeoutExpired as exc:
            raise WireGuardScriptError(f"{script_name} timed out after {self.script_timeout}s") from exc
        except subprocess.CalledProcessError as exc:
            raise WireGuardScriptError(f"{script_name} failed: {exc.stderr}") from exc

        stdout = proc.stdout.strip()
        if not stdout:
            return {}
        try:
            return json.loads(stdout)
        except json.JSONDecodeError as exc:
            raise WireGuardScriptError(f"{script_name} returned non-JSON output: {stdout}") from exc

    # -------------------- Config helpers --------------------
    def get_config_path(self, peer: WireGuardPeer) -> Path:
        primary_path = self.client_config_dir / f"{peer.identifier}.conf"
        if primary_path.exists():
            return primary_path
        fallback = settings.WG_PUBLIC_CONF_DIR / f"{peer.identifier}.conf"
        return fallback

    def read_config_for_peer(self, peer: WireGuardPeer) -> str:
        config_path = self.get_config_path(peer)
        if not config_path.exists():
            raise WireGuardError(f"Config file not found for {peer.identifier}: {config_path}")
        return config_path.read_text(encoding="utf-8")
