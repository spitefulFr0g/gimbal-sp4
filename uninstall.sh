#!/usr/bin/env bash
# Remove everything install.sh put in place: the plugin, its Omarchy clones,
# the Hyprland module, the keyboard and CLI, the optional Type Cover fold
# helper, and the state they keep. Pass --purge to also remove the saved
# settings (~/.config/omarchy/gimbal-sp4.json and the knob positions).
set -euo pipefail

purge=0
case ${1:-} in
    '') ;;
    --purge) purge=1 ;;
    *) echo 'Usage: uninstall.sh [--purge]' >&2; exit 2 ;;
esac

plugin_id=io.github.spitfulfr0g.gimbal-sp4
hypr_config="$HOME/.config/hypr/hyprland.lua"
runtime=${XDG_RUNTIME_DIR:-/tmp}

omarchy plugin remove "$plugin_id" --yes 2>/dev/null || true
for name in menu polkit emojis clipboard reminders lock; do
    clone="$HOME/.config/omarchy/plugins/${USER:-$(id -un)}.$name"
    if [[ -f $clone/.gimbal-sp4-owned ]]; then
        omarchy plugin remove "${USER:-$(id -un)}.$name" --yes >/dev/null
    fi
done
# The shell normally takes the keyboard down with the plugin; make sure.
pkill -x -u "$(id -u)" gimbal-sp4-oskbd 2>/dev/null || true

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

# Nothing that writes these is loaded any more. The saved mode and the cover
# state it was chosen under are state, not settings.
rm -f "$runtime"/gimbal-sp4-{mode,osk,autoshow,autocover,cover,look} \
      "$HOME/.config/omarchy/gimbal-sp4-mode" \
      "$HOME/.config/omarchy/gimbal-sp4-cover"
if (( purge )); then
    rm -f "$HOME/.config/omarchy/gimbal-sp4.json" \
          "$HOME/.local/state/omarchy/gimbal-sp4-pads.json"
fi

# The optional Type Cover fold helper (install.sh --with-fold-helper). Done
# last because it needs sudo: if that is declined, everything above is
# already gone and the message below says exactly what is left. The udev
# rule goes first so nothing starts a new instance, then running instances
# are stopped, which also removes /run/gimbal-sp4-cover. A "change" event on
# the cover's node clears the rule's properties from the udev database. The
# service used a dynamic user, so no account is left behind.
fold_rules=/etc/udev/rules.d/70-gimbal-sp4-cover.rules
fold_unit=/etc/systemd/system/gimbal-sp4-coverd@.service
fold_dir=/usr/local/lib/gimbal-sp4
fold_bin=$fold_dir/gimbal-sp4-coverd
fold_left() {
    [[ -e $fold_rules || -e $fold_unit || -e $fold_bin || -e /run/gimbal-sp4-cover ]] \
        || systemctl is-active --quiet 'gimbal-sp4-coverd@*.service'
}
if fold_left; then
    echo 'Removing the Type Cover fold helper with sudo.'
    if ! sudo -v; then
        echo "The fold helper was not removed. Run ./uninstall.sh again, or remove $fold_rules, $fold_unit and $fold_dir by hand." >&2
        exit 1
    fi
    if [[ -e $fold_rules ]]; then
        sudo rm -f "$fold_rules"
        sudo udevadm control --reload
    fi
    sudo systemctl stop 'gimbal-sp4-coverd@*.service'
    sudo systemctl reset-failed 'gimbal-sp4-coverd@*.service' 2>/dev/null || true
    sudo rm -f "$fold_unit" "$fold_bin"
    sudo rmdir --ignore-fail-on-non-empty "$fold_dir" 2>/dev/null || true
    sudo systemctl daemon-reload
    for node in /sys/class/hidraw/hidraw*; do
        if grep -qx 'HID_ID=0003:0000045E:000007E8' "$node/device/uevent" 2>/dev/null; then
            sudo udevadm trigger --action=change --settle "$node"
        fi
    done
    if fold_left; then
        echo 'The fold helper is not fully removed; `systemctl status gimbal-sp4-coverd@*` shows what remains.' >&2
        exit 1
    fi
    echo 'Removed the Type Cover fold helper.'
fi

if (( purge )); then
    printf 'Removed Gimbal SP4 and its saved settings.\n'
else
    printf 'Removed Gimbal SP4. Saved settings remain in ~/.config/omarchy/gimbal-sp4.json; ./uninstall.sh --purge removes them.\n'
fi
