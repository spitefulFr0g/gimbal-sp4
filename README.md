# Gimbal SP4

A Surface Pro 4 adaptation of [Gimbal](https://github.com/mechanicsunlocked/gimbal) for Omarchy 4. The fork keeps Gimbal's GTK4 Wayland keyboard, Quickshell bar widget, and settings panel. It replaces Framework 12 fold detection with a manual Surface tablet mode. The keyboard icon remains available in both modes.

This fork is based on upstream commit `97aa6d44e4949f820cb905673612c11d161aad21`. The original author is Sven Mathieu; see [LICENSE](LICENSE) and [the upstream README](UPSTREAM_README.md). The lock-screen clone remains in the source as a reference for a later milestone and is not installed by this version.

## Current behavior

- Tap the keyboard icon on Omarchy's top bar to show or hide the bottom on-screen keyboard. `SUPER+B` is a fallback.
- Tap the adjacent tablet icon to switch between tablet and laptop mode. The choice survives Hyprland reloads and sign-in. The first install starts in tablet mode so the Type Cover can be removed immediately.
- Open the settings icon to change keyboard opacity, choose overlay or reserved space, and enable automatic appearance for supported text fields. Automatic appearance starts **off** because focus behavior varies by application.
- The keyboard defaults to a 90% opaque bottom dock that reserves space for application windows. It follows the current Hyprland xkb layout, sends modifiers and shortcuts, and targets the internal `eDP` display. The settings panel can switch it to an overlay.
- Gimbal's gesture knobs remain available in tablet mode and may be switched off individually in settings.

This version does not yet detect Type Cover detach, rotate the display, provide a draggable floating keyboard, or add an on-screen lock keypad. The [project plan](PLAN.md) covers those later milestones. No PIN or PAM changes are made. Real finger input still needs a check on the tablet; automated verification has confirmed the keyboard sends keys into a focused Foot terminal.

## Install on a Surface Pro 4

Read `install.sh` before running it. It builds the keyboard, adds one `require` line to `~/.config/hypr/hyprland.lua` after making a timestamped backup, installs the shell plugin under its own ID, and enables its bar widget. It clones Omarchy's menu and other unlocked-session text popups to allow touch typing into them. It backs up `shell.json` before cloning. It does not run the original Framework installer or edit the lock screen.

```bash
./install.sh
```

The installer requires Omarchy 4, Hyprland, and the official Arch packages `gtk4`, `gtk4-layer-shell`, `libxkbcommon`, `wayland`, `pkgconf`, and `gcc`. It stops if the original Gimbal plugin is enabled because both projects use `SUPER+B`.

Useful checks:

```bash
omarchy plugin validate .
omarchy plugin list
gimbal-sp4-mode status
gimbal-sp4-mode tablet
gimbal-sp4-mode laptop
hyprctl configerrors
```

If the bar button has not appeared, check that `~/.local/bin` is on the Omarchy shell's `PATH`, then inspect `journalctl --user -t omarchy-shell` for plugin errors. The installer prints the Hyprland config backup path.

To remove this fork's files and bar widget, run `./uninstall.sh` from this repository. It does not remove other plugins or your saved settings.

## Source layout

- `lua/gimbal_sp4.lua`: manual tablet mode and focus handling. It publishes `tablet` or `laptop` to `$XDG_RUNTIME_DIR/gimbal-sp4-mode`.
- `Panel.qml` and `BarWidget.qml`: Gimbal's Quickshell UI, with an always-visible keyboard and mode button.
- `osk/`: Gimbal's Wayland virtual keyboard, built as `gimbal-sp4-oskbd` and using separate runtime state names.
- `bin/gimbal-sp4-mode`: command-line mode control.
- `bin/patch-overlays.py`: updates cloned unlocked-session popups so touch reaches the keyboard.
- `lock-clone/`, `menu-clone/`, `upstream/`: inherited reference material. The lock clone is not installed.

The keyboard, bar, and eventual lock view consume the mode word rather than Surface sensor names. That seam keeps later hardware detection in one place.
