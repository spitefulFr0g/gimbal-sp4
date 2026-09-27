#!/usr/bin/env bash
# Install the Surface Pro 4/9 keyboard, bar controls, and lock-screen keypad.
# Pass --without-lock to leave Omarchy's lock screen untouched. Pass
# --with-fold-helper to also install the system service that lets folding the
# Type Cover back enter tablet mode; that part uses sudo (see README.md).
# Pass --with-unlock-keyboard to let a Surface Pro 9 Type Cover type at the
# disk-unlock prompt; that part also uses sudo and rebuilds the initramfs.
set -euo pipefail

install_lock=1
install_fold=0
install_unlock=0
for arg in "$@"; do
    case $arg in
        --without-lock) install_lock=0 ;;
        --with-fold-helper) install_fold=1 ;;
        --with-unlock-keyboard) install_unlock=1 ;;
        *) echo 'Usage: install.sh [--without-lock] [--with-fold-helper] [--with-unlock-keyboard]' >&2; exit 2 ;;
    esac
done

plugin_id=io.github.spitfulfr0g.gimbal-sp4
source_dir=$(cd "$(dirname "$0")" && pwd)
plugin_dir="$HOME/.config/omarchy/plugins/$plugin_id"
hypr_config="$HOME/.config/hypr/hyprland.lua"

product=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
case $product in
    'Surface Pro 4'|'Surface Pro 9') ;;
    *) echo "This installer targets Surface Pro 4 and 9, not '${product:-unknown}'." >&2; exit 1 ;;
esac
# Surface touchscreens need the linux-surface kernel (IPTS on the SP4, ITHC on
# the SP9). Without it the keyboard installs but cannot be reached by finger.
if ! udevadm info --export-db 2>/dev/null | grep -q '^E: ID_INPUT_TOUCHSCREEN=1'; then
    echo "Warning: no touchscreen found. Is the linux-surface kernel running? (uname -r: $(uname -r))" >&2
fi
command -v omarchy-shell >/dev/null || { echo 'Omarchy 4 shell is required.' >&2; exit 1; }
command -v hyprctl >/dev/null || { echo 'Hyprland is required.' >&2; exit 1; }
for command_name in jq rg python3 patch; do
    command -v "$command_name" >/dev/null || { echo "Missing command: $command_name" >&2; exit 1; }
done
[[ -f $hypr_config ]] || { echo "Missing $hypr_config" >&2; exit 1; }
for pkg in gtk4 gtk4-layer-shell libxkbcommon wayland pkgconf gcc; do
    pacman -Qq "$pkg" >/dev/null 2>&1 || { echo "Missing package: $pkg" >&2; exit 1; }
done
if (( install_fold )); then
    for command_name in sudo systemctl udevadm make; do
        command -v "$command_name" >/dev/null || { echo "Missing command: $command_name" >&2; exit 1; }
    done
fi
if (( install_unlock )); then
    for command_name in sudo mkinitcpio; do
        command -v "$command_name" >/dev/null || { echo "Missing command: $command_name" >&2; exit 1; }
    done
fi

# Gimbal owns the same keyboard shortcut. Keep a second installation from
# silently changing the user's existing controls.
if omarchy plugin list --json | jq -e 'any(.[]; .id == "io.github.mechanicsunlocked.gimbal" and .enabled)' >/dev/null; then
    echo 'Disable the original Gimbal plugin before installing Gimbal SP4.' >&2
    exit 1
fi

omarchy plugin validate "$source_dir"
make -C "$source_dir/osk" --no-print-directory
if (( install_fold )); then
    # Build and test as the user; only the finished files are installed as root.
    make -C "$source_dir/coverd" --no-print-directory check >/dev/null
fi

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
# surface. The lock screen is handled separately below.
shell_config="$HOME/.config/omarchy/shell.json"
if [[ -f $shell_config ]]; then
    cp -p "$shell_config" "$shell_config.gimbal-sp4.bak.$(date +%Y%m%d%H%M%S)"
fi
for spec in polkit:PolkitAgent.qml emojis:Emojis.qml clipboard:Clipboard.qml reminders:ReminderFlow.qml; do
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

# The menu is not cloned: a third-party copy of it gets a scoped app library
# and its Apps list comes up empty. Remove the clone an earlier install made,
# which switches back to Omarchy's own menu.
menu_clone="$HOME/.config/omarchy/plugins/${USER:-$(id -un)}.menu"
if [[ -f $menu_clone/.gimbal-sp4-owned ]]; then
    omarchy plugin remove "${USER:-$(id -un)}.menu" --yes >/dev/null
    echo 'Removed the earlier menu clone; the stock Omarchy menu is active.'
fi

# The lock screen is an ext-session-lock surface: while locked, no layer
# surface such as the on-screen keyboard is drawn or touchable. Clone Omarchy's
# lock plugin and add a keypad drawn by the lock view itself. Each install
# copies the current stock files and reapplies the patch, so an Omarchy update
# is either patched again or refused, never silently mixed with old files.
lock_clone="$HOME/.config/omarchy/plugins/${USER:-$(id -un)}.lock"
lock_message='Lock-screen files were not changed.'
if (( install_lock )); then
    stock_lock=$(omarchy-plugin-catalog | jq -r '.[] | select(.firstParty and .id == "omarchy.lock") | .sourceDir')
    patched_view=$(mktemp)
    if [[ -d $lock_clone && ! -f $lock_clone/.gimbal-sp4-owned ]]; then
        echo "Existing $lock_clone belongs to the user; not patching it." >&2
    elif [[ ! -f $stock_lock/LockView.qml ]] || ! cp "$stock_lock/LockView.qml" "$patched_view" \
            || ! patch --quiet --fuzz=0 --no-backup-if-mismatch -r - "$patched_view" < "$source_dir/lock-clone/LockView.patch"; then
        echo "Omarchy's LockView.qml has changed; the lock keypad was not installed." >&2
        if [[ -f $lock_clone/.gimbal-sp4-owned ]]; then
            omarchy plugin remove "${USER:-$(id -un)}.lock" --yes >/dev/null
            echo 'Removed the previous lock keypad; the stock lock screen is active.' >&2
        fi
    else
        if [[ ! -d $lock_clone ]]; then
            omarchy plugin clone omarchy.lock >/dev/null
            touch "$lock_clone/.gimbal-sp4-owned"
        fi
        install -m644 "$stock_lock/Service.qml" "$lock_clone/Service.qml"
        install -m644 "$patched_view" "$lock_clone/LockView.qml"
        install -m644 "$source_dir/lock-clone/LockKeypad.qml" "$lock_clone/LockKeypad.qml"
        lock_message='The lock screen shows a touch keypad; lock once with the Type Cover attached to check it.'
    fi
    rm -f "$patched_view"
fi

# The fold helper is the only part that runs with system privileges. Its
# files are installed root-owned outside the home directory, so no user
# process can change what runs; the service itself runs as an unprivileged
# dynamic user (see coverd/system/gimbal-sp4-coverd@.service).
fold_bin=/usr/local/lib/gimbal-sp4/gimbal-sp4-coverd
fold_unit=/etc/systemd/system/gimbal-sp4-coverd@.service
fold_rules=/etc/udev/rules.d/70-gimbal-sp4-cover.rules
fold_message='Folding the Type Cover back is not detected; pass --with-fold-helper to add it.'
if [[ $product != 'Surface Pro 4' ]]; then
    # Only the SP4 cover needs the helper; newer Surfaces report the fold
    # through their tablet-mode switch, which the Lua half reads directly.
    fold_message="The $product's tablet-mode switch reports folding the Type Cover back; no fold helper is needed."
    if (( install_fold )); then fold_message+=' --with-fold-helper was ignored.'; fi
elif (( install_fold )); then
    echo 'Installing the Type Cover fold helper with sudo:'
    printf '  %s\n' "$fold_bin" "$fold_unit" "$fold_rules"
    sudo install -d -o root -g root -m755 /usr/local/lib/gimbal-sp4
    sudo install -o root -g root -m755 "$source_dir/coverd/gimbal-sp4-coverd" "$fold_bin"
    sudo install -o root -g root -m644 "$source_dir/coverd/system/gimbal-sp4-coverd@.service" "$fold_unit"
    sudo install -o root -g root -m644 "$source_dir/coverd/system/70-gimbal-sp4-cover.rules" "$fold_rules"
    sudo systemctl daemon-reload
    sudo udevadm control --reload
    # Replay "add" for the cover's hidraw node only, so an attached cover
    # starts the helper now; a running one is restarted onto the new binary.
    sudo systemctl try-restart 'gimbal-sp4-coverd@*.service'
    for node in /sys/class/hidraw/hidraw*; do
        if grep -qx 'HID_ID=0003:0000045E:000007E8' "$node/device/uevent" 2>/dev/null; then
            sudo udevadm trigger --action=add --settle "$node"
        fi
    done
    fold_message='Folding the Type Cover back enters tablet mode when Follow the Type Cover is on; `gimbal-sp4-mode cover` shows the fold helper.'
elif [[ -e $fold_bin || -e $fold_unit || -e $fold_rules ]]; then
    fold_message='The installed Type Cover fold helper was left as it was; pass --with-fold-helper to update it.'
fi

# The Surface Pro 9 Type Cover is not a USB keyboard: it reaches the kernel
# through the Surface Aggregator, whose modules load only after the root
# filesystem is mounted. On an encrypted root the unlock prompt comes first,
# so without these modules in the initramfs the cover cannot type there.
# Omarchy's own Surface fix (install/hardware/fix-surface-keyboard.sh) skips
# kernels that build the pinctrl driver in, which linux-surface does. The
# SP4 cover is USB and already works at the prompt through usbhid.
unlock_conf=/etc/mkinitcpio.conf.d/gimbal-sp4-type-cover.conf
unlock_message=''
if [[ $product == 'Surface Pro 9' ]] && rg -q '(^| )(cryptdevice|rd\.luks\.[a-z]+)=' /proc/cmdline; then
    if [[ -f $unlock_conf ]] && ! (( install_unlock )); then
        unlock_message='The Type Cover types at the disk-unlock prompt; the installed initramfs modules were left as they were.'
    elif [[ ! -f $unlock_conf ]] && rg -q -w surface_hid /etc/mkinitcpio.conf /etc/mkinitcpio.conf.d/ 2>/dev/null; then
        unlock_message='The mkinitcpio configuration already loads the Type Cover modules; the disk-unlock prompt was not changed.'
    elif (( install_unlock )); then
        unlock_modules=(surface_aggregator surface_aggregator_registry surface_aggregator_hub
                        surface_hid_core surface_hid intel_lpss intel_lpss_pci 8250_dw)
        # The GPIO controller driver is built in on linux-surface but a module
        # on other kernels; add it only when it is one.
        for driver in /sys/bus/platform/drivers/*-pinctrl; do
            compgen -G "$driver/*:*" >/dev/null || continue
            if [[ -e $driver/module/initstate ]]; then
                unlock_modules+=("$(basename "$(readlink -f "$driver/module")")")
            fi
        done
        unlock_file=$(mktemp)
        {
            echo '# Installed by Gimbal SP4 (install.sh --with-unlock-keyboard); uninstall.sh removes it.'
            echo '# Lets the Surface Pro 9 Type Cover type at the disk-unlock prompt.'
            echo "MODULES+=(${unlock_modules[*]})"
        } > "$unlock_file"
        echo "Adding the Type Cover modules to the initramfs with sudo: $unlock_conf"
        sudo install -o root -g root -m644 "$unlock_file" "$unlock_conf"
        rm -f "$unlock_file"
        # Omarchy boots through limine; its wrapper also refreshes the boot
        # entries, which plain mkinitcpio -P would leave stale.
        if command -v limine-mkinitcpio >/dev/null; then
            sudo limine-mkinitcpio
        else
            sudo mkinitcpio -P
        fi
        unlock_message='The Type Cover types at the disk-unlock prompt after the next boot; attach it before powering on.'
    else
        unlock_message='The Type Cover cannot type at the disk-unlock prompt; pass --with-unlock-keyboard to fix that.'
    fi
elif (( install_unlock )); then
    unlock_message="--with-unlock-keyboard was ignored: it is for a Surface Pro 9 with an encrypted root, and this is a $product"
    rg -q '(^| )(cryptdevice|rd\.luks\.[a-z]+)=' /proc/cmdline || unlock_message+=' without one'
    unlock_message+='.'
fi

# Qt caches loaded components, so the lock view only changes after a restart.
omarchy restart shell >/dev/null

echo 'Gimbal SP4 installed. Tap its keyboard icon in the bar to show or hide the keyboard.'
echo 'The adjacent tablet icon switches manual tablet mode.'
echo "$lock_message"
echo "$fold_message"
if [[ -n $unlock_message ]]; then echo "$unlock_message"; fi
