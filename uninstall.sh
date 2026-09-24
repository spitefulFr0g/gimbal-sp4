#!/usr/bin/env bash
set -euo pipefail

plugin_id=io.github.spitfulfr0g.gimbal-sp4
hypr_config="$HOME/.config/hypr/hyprland.lua"

omarchy plugin remove "$plugin_id" --yes 2>/dev/null || true
for name in menu polkit emojis clipboard reminders; do
    clone="$HOME/.config/omarchy/plugins/${USER:-$(id -un)}.$name"
    if [[ -f $clone/.gimbal-sp4-owned ]]; then
        omarchy plugin remove "${USER:-$(id -un)}.$name" --yes >/dev/null
    fi
done

if [[ -f $hypr_config ]] && rg -q 'require\("hypr.gimbal_sp4"\)' "$hypr_config"; then
    python3 - "$hypr_config" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
lines = path.read_text().splitlines(keepends=True)
path.write_text(''.join(line for line in lines if line.strip() not in {
    '-- Gimbal SP4 manual tablet mode',
    'require("hypr.gimbal_sp4")',
}))
PY
fi

rm -f "$HOME/.config/hypr/gimbal_sp4.lua" \
      "$HOME/.local/bin/gimbal-sp4-oskbd" \
      "$HOME/.local/bin/gimbal-sp4-mode"

hyprctl reload >/dev/null
omarchy-shell shell rescanPlugins >/dev/null
omarchy restart shell >/dev/null
printf 'Removed Gimbal SP4. Saved settings remain in ~/.config/omarchy/gimbal-sp4.json.\n'
