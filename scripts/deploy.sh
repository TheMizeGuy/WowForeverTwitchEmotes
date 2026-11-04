#!/usr/bin/env bash
# Copyright (c) 2026 TheMizeGuy. All rights reserved.
# Stage, hash-check, then replace only TwitchEmotes inside the selected AddOns folder.
# Usage: deploy.sh [host] [addons-dir] [--replace-foreign]
set -euo pipefail

deploy_host="${1:-mizepc}"
addons_dir="${2:-C:\\Program Files (x86)\\World of Warcraft\\_forever_\\Interface\\AddOns}"
replace_foreign="${3:-}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -n "$replace_foreign" && "$replace_foreign" != "--replace-foreign" ]]; then
  echo "Unknown option: $replace_foreign" >&2; exit 1
fi
if [[ ! "$deploy_host" =~ ^[A-Za-z0-9][A-Za-z0-9._@-]*$ ]] || [[ "$addons_dir" == *[\"\'\$\`\;\&\|]* ]]; then
  echo 'Unsupported deployment target characters' >&2; exit 1
fi
[[ -f "$repo_root/TwitchEmotes/TwitchEmotes_Camelot.toc" ]] || { echo 'Missing client TOC' >&2; exit 1; }
local_stage=$(mktemp -d)
trap 'rm -rf "$local_stage"' EXIT
stage_name=".TwitchEmotes-stage-$(date +%Y%m%d%H%M%S)-$$"
remote_stage="$addons_dir\\$stage_name"

python3 - "$repo_root/TwitchEmotes" "$local_stage/manifest.json" <<'MANIFEST'
import hashlib, json, sys
from pathlib import Path
root, output = map(Path, sys.argv[1:])
files = []
for file in sorted(root.rglob('*')):
    if file.is_symlink():
        raise SystemExit('Refusing symlink: ' + str(file))
    if file.is_file() and file.name != '.DS_Store' and not file.name.startswith('._'):
        files.append({'path': file.relative_to(root).as_posix(), 'size': file.stat().st_size,
                      'sha256': hashlib.file_digest(file.open('rb'), 'sha256').hexdigest()})
output.write_text(json.dumps(files))
print(f'Staging {len(files)} files ({sum(f["size"] for f in files) / 1024 / 1024:.1f} MiB)')
MANIFEST
cp "$repo_root/scripts/deploy.ps1" "$local_stage/deploy.ps1"
encode_ps() { python3 -c 'import sys,base64; print(base64.b64encode(("$ProgressPreference=\"SilentlyContinue\";"+sys.stdin.read()).encode("utf-16le")).decode())'; }
# The client root two levels above AddOns must hold .flavor.info or a Wow*.exe, so a mistyped path creates nothing.
prepare=$(printf "\$ErrorActionPreference='Stop'; \$client=[IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName('%s'.TrimEnd([IO.Path]::DirectorySeparatorChar))); if (-not \$client -or -not ([IO.File]::Exists([IO.Path]::Combine(\$client, '.flavor.info')) -or (Get-ChildItem -LiteralPath \$client -Filter 'Wow*.exe' -File -ErrorAction SilentlyContinue))) { throw \"No WoW client at \$client\" }; [IO.Directory]::CreateDirectory('%s') | Out-Null" "$addons_dir" "$remote_stage" | encode_ps)
ssh -o BatchMode=yes "$deploy_host" "powershell -NoProfile -NonInteractive -EncodedCommand $prepare"
COPYFILE_DISABLE=1 tar -czf - -C "$repo_root" --exclude='.DS_Store' --exclude='._*' TwitchEmotes \
  -C "$local_stage" manifest.json deploy.ps1 \
  | ssh -o BatchMode=yes "$deploy_host" "tar -xzf - -C \"$remote_stage\""
switch=""
if [[ -n "$replace_foreign" ]]; then switch=" -ReplaceForeign"; fi
install=$(printf "& '%s\\deploy.ps1' -AddOnsPath '%s' -StageName '%s'%s" "$remote_stage" "$addons_dir" "$stage_name" "$switch" | encode_ps)
ssh -o BatchMode=yes "$deploy_host" "powershell -NoProfile -NonInteractive -EncodedCommand $install"
