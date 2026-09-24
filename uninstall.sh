#!/usr/bin/env bash
set -euo pipefail

plugin_id=io.github.spitfulfr0g.gimbal-sp4
hypr_config="$HOME/.config/hypr/hyprland.lua"

omarchy plugin remove "$plugin_id" --yes 2>/dev/null || true
for name in menu polkit emojis clipboard reminders lock; do
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

# The optional Type Cover fold helper (install.sh --with-fold-helper). The
# udev rule goes first so nothing starts a new instance, then running
# instances are stopped. A "change" event on the cover's node then clears
# the rule's properties from the udev database.
fold_rules=/etc/udev/rules.d/70-gimbal-sp4-cover.rules
fold_unit=/etc/systemd/system/gimbal-sp4-coverd@.service
fold_bin=/usr/local/lib/gimbal-sp4/gimbal-sp4-coverd
if [[ -e $fold_rules || -e $fold_unit || -e $fold_bin ]]; then
    echo 'Removing the Type Cover fold helper with sudo.'
    if [[ -e $fold_rules ]]; then
        sudo rm -f "$fold_rules"
        sudo udevadm control --reload
    fi
    sudo systemctl stop 'gimbal-sp4-coverd@*.service'
    sudo systemctl reset-failed 'gimbal-sp4-coverd@*.service' 2>/dev/null || true
    sudo rm -f "$fold_unit" "$fold_bin"
    sudo rmdir --ignore-fail-on-non-empty /usr/local/lib/gimbal-sp4 2>/dev/null || true
    sudo systemctl daemon-reload
    for node in /sys/class/hidraw/hidraw*; do
        if grep -qx 'HID_ID=0003:0000045E:000007E8' "$node/device/uevent" 2>/dev/null; then
            sudo udevadm trigger --action=change --settle "$node"
        fi
    done
fi

rm -f "$HOME/.config/hypr/gimbal_sp4.lua" \
      "$HOME/.local/bin/gimbal-sp4-oskbd" \
      "$HOME/.local/bin/gimbal-sp4-mode"

hyprctl reload >/dev/null
omarchy-shell shell rescanPlugins >/dev/null
omarchy restart shell >/dev/null
printf 'Removed Gimbal SP4. Saved settings remain in ~/.config/omarchy/gimbal-sp4.json.\n'
