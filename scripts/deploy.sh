#!/usr/bin/env bash
# Copyright (c) 2026 TheMizeGuy. All rights reserved.
# Stage, hash-check, then replace only TwitchEmotes inside the selected AddOns folder.
set -euo pipefail

deploy_host="${1:-mizepc}"
addons_dir="${2:-C:\\Program Files (x86)\\World of Warcraft\\_classic_beta_\\Interface\\AddOns}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
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
prepare=$(printf "\$ErrorActionPreference='Stop'; [IO.Directory]::CreateDirectory('%s') | Out-Null" "$remote_stage" | encode_ps)
ssh -o BatchMode=yes "$deploy_host" "powershell -NoProfile -NonInteractive -EncodedCommand $prepare"
COPYFILE_DISABLE=1 tar -czf - -C "$repo_root" --exclude='.DS_Store' --exclude='._*' TwitchEmotes \
  -C "$local_stage" manifest.json deploy.ps1 \
  | ssh -o BatchMode=yes "$deploy_host" "tar -xzf - -C \"$remote_stage\""
install=$(printf "& '%s\\deploy.ps1' -AddOnsPath '%s' -StageName '%s'" "$remote_stage" "$addons_dir" "$stage_name" | encode_ps)
ssh -o BatchMode=yes "$deploy_host" "powershell -NoProfile -NonInteractive -EncodedCommand $install"
