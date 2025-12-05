#!/usr/bin/env bash
set -euo pipefail

WG_CONFIG_PATH="${WG_CONFIG_PATH:-/etc/wireguard/wg1.conf}"

IDENTIFIER=""
MODE="enable"

usage() {
  echo "Usage: $0 (--enable|--disable) --id <identifier>"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --enable)
      MODE="enable"; shift;;
    --disable)
      MODE="disable"; shift;;
    --id)
      IDENTIFIER="$2"; shift 2;;
    -h|--help)
      usage; exit 0;;
    *)
      echo "Unknown argument: $1" >&2; usage; exit 1;;
  esac
done

if [[ -z "$IDENTIFIER" ]]; then
  echo '{"status":"error","message":"--id required"}'
  exit 1
fi

tmp=$(mktemp)
python - "$IDENTIFIER" "$WG_CONFIG_PATH" "$tmp" "$MODE" <<'PY'
import pathlib
import re
import sys

identifier, source_path, tmp_path, mode = sys.argv[1:]
enable = mode == "enable"
src = pathlib.Path(source_path)
lines = src.read_text().splitlines()
out = []
i = 0
while i < len(lines):
    line = lines[i]
    stripped = line.strip()
    is_peer_header = re.match(r"#?\s*\[Peer\]", stripped, re.IGNORECASE)
    if is_peer_header:
        block = [line]
        j = i + 1
        while j < len(lines) and not re.match(r"#?\s*\[Peer\]", lines[j].strip(), re.IGNORECASE):
            block.append(lines[j])
            j += 1
        block_text = "\n".join(block)
        comment_name = ""
        k = i - 1
        while k >= 0 and lines[k].strip().startswith("#"):
            comment_name = lines[k].strip().lstrip("#").strip()
            break
        normalized_name = comment_name.replace("Name:", "").strip()
        if identifier in block_text or (normalized_name and identifier == normalized_name):
            new_block = []
            for ln in block:
                if enable:
                    new_block.append(re.sub(r"^#\s*", "", ln))
                else:
                    ln_strip = ln.strip()
                    if ln_strip.startswith("#"):
                        new_block.append(ln)
                    else:
                        new_block.append("# " + ln)
            out.extend(new_block)
            i = j
            continue
        out.extend(block)
        i = j
        continue
    out.append(line)
    i += 1

pathlib.Path(tmp_path).write_text("\n".join(out) + "\n")
PY
mv "$tmp" "$WG_CONFIG_PATH"

systemctl restart "wg-quick@${WG_INTERFACE:-wg0}.service" >/dev/null 2>&1 || true

cat <<EOF
{
  "status": "ok",
  "id": "$IDENTIFIER",
  "mode": "$MODE"
}
EOF
