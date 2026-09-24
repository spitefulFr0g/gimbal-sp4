# Gimbal SP4

A Surface Pro 4 adaptation of [Gimbal](https://github.com/mechanicsunlocked/gimbal) for Omarchy 4. The fork keeps Gimbal's GTK4 Wayland keyboard, Quickshell bar widget, and settings panel. It replaces Framework 12 fold detection with a Surface tablet mode that is set by hand or, optionally, follows the Type Cover. The keyboard icon remains available in both modes.

This fork is based on upstream commit `97aa6d44e4949f820cb905673612c11d161aad21`. The original author is Sven Mathieu; see [LICENSE](LICENSE) and [the upstream README](UPSTREAM_README.md). The installer also clones Omarchy's lock screen to add a touch keypad.

## Current behavior

- Tap the keyboard icon on Omarchy's top bar to show or hide the bottom on-screen keyboard. `SUPER+B` is a fallback.
- Tap the adjacent tablet icon to switch between tablet and laptop mode. The choice survives Hyprland reloads and sign-in. The first install starts in tablet mode so the Type Cover can be removed immediately.
- Turn on **Follow the Type Cover** in settings to enter tablet mode when the Type Cover is detached and return to laptop mode when it is reattached. It starts **off**. With it on, a mode chosen with the tablet icon holds until the cover is next detached or reattached, including across Hyprland reloads and shell restarts. The settings panel shows the cover state and says when a manual choice is holding. Folding the cover behind the screen does not disconnect it on the SP4, so that stays laptop mode.
- Open the settings icon to change keyboard opacity, choose overlay or reserved space, and enable automatic appearance for supported text fields. Automatic appearance starts **off** because focus behavior varies by application.
- The keyboard defaults to a 90% opaque bottom dock that reserves space for application windows. It follows the current Hyprland xkb layout, sends modifiers and shortcuts, and targets the internal `eDP` display. The settings panel can switch it to an overlay.
- Gimbal's gesture knobs remain available in tablet mode and may be switched off individually in settings.
- The lock screen has its own touch keypad, because the on-screen keyboard cannot appear over a locked session. In tablet mode it opens with the lock screen. In either mode, a finger or pen tap on the password field opens it, so a Surface locked in laptop mode and then undocked can still be unlocked. It types the account password through the stock Omarchy authentication path; fingerprint unlock is unchanged. Mouse and touchpad clicks on the field behave as before.

This version does not yet rotate the display or provide a draggable floating keyboard. The [project plan](PLAN.md) covers those later milestones. No PIN or PAM changes are made. The lock keypad has passed a preview check but still needs a real lock and unlock by touch. Real finger input still needs a check on the tablet; automated verification has confirmed the keyboard sends keys into a focused Foot terminal.

## Install on a Surface Pro 4

Read `install.sh` before running it. It builds the keyboard, adds one `require` line to `~/.config/hypr/hyprland.lua` after making a timestamped backup, installs the shell plugin under its own ID, and enables its bar widget. It clones Omarchy's menu and other unlocked-session text popups to allow touch typing into them. It backs up `shell.json` before cloning. It clones Omarchy's lock plugin as `<user>.lock` and applies `lock-clone/LockView.patch` to a fresh copy of the installed stock `LockView.qml` on each run. If Omarchy's file has changed and the patch no longer applies exactly, it installs no lock keypad, removes any previous one, and leaves the stock lock screen active. Pass `--without-lock` to skip the lock screen entirely. It does not run the original Framework installer.

```bash
./install.sh
```

The installer requires Omarchy 4, Hyprland, and the official Arch packages `gtk4`, `gtk4-layer-shell`, `libxkbcommon`, `wayland`, `pkgconf`, and `gcc`. It stops if the original Gimbal plugin is enabled because both projects use `SUPER+B`.

Useful checks:

```bash
omarchy plugin validate .
omarchy plugin list
gimbal-sp4-mode status
gimbal-sp4-mode cover
gimbal-sp4-mode tablet
gimbal-sp4-mode laptop
hyprctl configerrors
```

If the bar button has not appeared, check that `~/.local/bin` is on the Omarchy shell's `PATH`, then inspect `journalctl --user -t omarchy-shell` for plugin errors. The installer prints the Hyprland config backup path.

To remove this fork's files and bar widget, run `./uninstall.sh` from this repository. It does not remove other plugins or your saved settings.

## Source layout

- `lua/gimbal_sp4.lua`: tablet mode, Type Cover detection, and focus handling. It publishes `tablet` or `laptop` to `$XDG_RUNTIME_DIR/gimbal-sp4-mode` and `attached`, `detached`, or `unknown` to `$XDG_RUNTIME_DIR/gimbal-sp4-cover`. It polls `/proc/bus/input/devices` twice a second for a device named `… Surface Type Cover Keyboard`, because Hyprland's Lua API has no device events and the SP4 has no tablet-mode switch. A detached reading must hold for two reads and, after startup or resume, for five seconds, because resume can drop the cover for about 2.5 seconds while USB re-enumerates.
- `Panel.qml` and `BarWidget.qml`: Gimbal's Quickshell UI, with an always-visible keyboard and mode button.
- `osk/`: Gimbal's Wayland virtual keyboard, built as `gimbal-sp4-oskbd` and using separate runtime state names.
- `bin/gimbal-sp4-mode`: command-line mode control.
- `bin/patch-overlays.py`: updates cloned unlocked-session popups so touch reaches the keyboard.
- `lock-clone/`: the lock-screen keypad (`LockKeypad.qml`) and the patch to Omarchy's `LockView.qml`. See [its README](lock-clone/README.md).
- `menu-clone/`, `upstream/`: inherited reference material.

The keyboard, bar, and lock view consume the mode word rather than Surface sensor names. That seam keeps hardware detection in one place.
