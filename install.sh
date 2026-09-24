#!/usr/bin/env bash
# Install only the unlocked-session Surface Pro 4 keyboard and bar controls.
set -euo pipefail

plugin_id=io.github.spitfulfr0g.gimbal-sp4
source_dir=$(cd "$(dirname "$0")" && pwd)
plugin_dir="$HOME/.config/omarchy/plugins/$plugin_id"
hypr_config="$HOME/.config/hypr/hyprland.lua"

[[ $(cat /sys/class/dmi/id/product_name 2>/dev/null) == 'Surface Pro 4' ]] || {
    echo 'This installer targets Surface Pro 4 only.' >&2; exit 1;
}
command -v omarchy-shell >/dev/null || { echo 'Omarchy 4 shell is required.' >&2; exit 1; }
command -v hyprctl >/dev/null || { echo 'Hyprland is required.' >&2; exit 1; }
for command_name in jq rg python3; do
    command -v "$command_name" >/dev/null || { echo "Missing command: $command_name" >&2; exit 1; }
done
[[ -f $hypr_config ]] || { echo "Missing $hypr_config" >&2; exit 1; }
for pkg in gtk4 gtk4-layer-shell libxkbcommon wayland pkgconf gcc; do
    pacman -Qq "$pkg" >/dev/null 2>&1 || { echo "Missing package: $pkg" >&2; exit 1; }
done

# Gimbal owns the same keyboard shortcut. Keep a second installation from
# silently changing the user's existing controls.
if omarchy plugin list --json | jq -e 'any(.[]; .id == "io.github.mechanicsunlocked.gimbal" and .enabled)' >/dev/null; then
    echo 'Disable the original Gimbal plugin before installing Gimbal SP4.' >&2
    exit 1
fi

omarchy plugin validate "$source_dir"
make -C "$source_dir/osk" --no-print-directory

# Back up the only pre-existing config file changed by this installer.
if ! rg -q 'require\("hypr.gimbal_sp4"\)' "$hypr_config"; then
    backup="$hypr_config.gimbal-sp4.bak.$(date +%Y%m%d%H%M%S)"
    cp -p "$hypr_config" "$backup"
    printf '\n-- Gimbal SP4 manual tablet mode\nrequire("hypr.gimbal_sp4")\n' >> "$hypr_config"
    echo "Backed up Hyprland config to $backup"
fi

install -Dm644 "$source_dir/lua/gimbal_sp4.lua" "$HOME/.config/hypr/gimbal_sp4.lua"
install -Dm755 "$source_dir/osk/gimbal-sp4-oskbd" "$HOME/.local/bin/gimbal-sp4-oskbd"
install -Dm755 "$source_dir/bin/gimbal-sp4-mode" "$HOME/.local/bin/gimbal-sp4-mode"
install -Dm644 "$source_dir/manifest.json" "$plugin_dir/manifest.json"
install -Dm644 "$source_dir/Panel.qml" "$plugin_dir/Panel.qml"
install -Dm644 "$source_dir/BarWidget.qml" "$plugin_dir/BarWidget.qml"

hyprctl reload >/dev/null
config_errors=$(hyprctl configerrors)
if [[ -n $config_errors && $config_errors != 'ok' ]]; then
    echo "Hyprland reported config errors: $config_errors" >&2
    exit 1
fi
omarchy-shell shell rescanPlugins >/dev/null
if ! omarchy plugin list --json | jq -e --arg id "$plugin_id" 'any(.[]; .id == $id and .enabled)' >/dev/null; then
    omarchy plugin enable "$plugin_id" --section right
fi

# These Omarchy popups use exclusive keyboard focus. Gimbal's Wayland keyboard
# needs them to use on-demand focus while the Surface is in tablet mode so a
# finger on a key reaches the keyboard instead of the popup's full-screen
# surface. Clone only unlocked-session popups; the secure lock screen is later.
shell_config="$HOME/.config/omarchy/shell.json"
if [[ -f $shell_config ]]; then
    cp -p "$shell_config" "$shell_config.gimbal-sp4.bak.$(date +%Y%m%d%H%M%S)"
fi
for spec in menu:Menu.qml polkit:PolkitAgent.qml emojis:Emojis.qml clipboard:Clipboard.qml reminders:ReminderFlow.qml; do
    name=${spec%%:*}
    entry=${spec#*:}
    clone="$HOME/.config/omarchy/plugins/${USER:-$(id -un)}.$name"
    if [[ ! -d $clone ]]; then
        omarchy plugin clone "omarchy.$name" >/dev/null
        touch "$clone/.gimbal-sp4-owned"
    elif [[ ! -f $clone/.gimbal-sp4-owned ]]; then
        echo "Existing $clone belongs to the user; not patching it." >&2
        continue
    fi
    python3 "$source_dir/bin/patch-overlays.py" "$clone/$entry"
done
omarchy restart shell >/dev/null

echo 'Gimbal SP4 installed. Tap its keyboard icon in the bar to show or hide the keyboard.'
echo 'The adjacent tablet icon switches manual tablet mode. Lock-screen files were not changed.'
