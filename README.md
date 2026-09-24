# Gimbal SP4

A Surface Pro 4 adaptation of [Gimbal](https://github.com/mechanicsunlocked/gimbal) for Omarchy 4. The fork keeps Gimbal's GTK4 Wayland keyboard, Quickshell bar widget, and settings panel. It replaces Framework 12 fold detection with a Surface tablet mode that is set by hand or, optionally, follows the Type Cover. The keyboard icon remains available in both modes.

This fork is based on upstream commit `97aa6d44e4949f820cb905673612c11d161aad21`. The original author is Sven Mathieu; see [LICENSE](LICENSE) and [the upstream README](UPSTREAM_README.md). The installer also clones Omarchy's lock screen to add a touch keypad.

## Current behavior

- Tap the keyboard icon on Omarchy's top bar to show or hide the bottom on-screen keyboard. `SUPER+B` is a fallback.
- Tap the adjacent tablet icon to switch between tablet and laptop mode. The choice survives Hyprland reloads and sign-in. The first install starts in tablet mode so the Type Cover can be removed immediately.
- Turn on **Follow the Type Cover** in settings to enter tablet mode when the Type Cover is detached and return to laptop mode when it is reattached. It starts **off**. With it on, a mode chosen with the tablet icon holds until the cover is next detached or reattached, including across Hyprland reloads and shell restarts. The settings panel shows the cover state and says when a manual choice is holding. Folding the cover behind the screen does not disconnect it on the SP4. With the optional [fold helper](#the-fold-helper) installed, folding it back also enters tablet mode and unfolding it to the typing position returns to laptop mode; a manual choice holds until the next fold or unfold, as it does for detach and reattach. Without the helper, a folded cover counts as attached.
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

Pass `--with-fold-helper` to also install the fold helper described below. That part needs `sudo`; the rest of the installer does not.

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

To remove this fork's files and bar widget, run `./uninstall.sh` from this repository. It does not remove other plugins or your saved settings. If the fold helper is installed, it removes that too, using `sudo`.

## The fold helper

The Type Cover's fold position is reported only on its hidraw node (`/dev/hidrawN`, USB `045e:07e8`, interface 0). The same node carries every keystroke and touchpad report, so it is root-only, and this project does not change that. Byte 1 of the cover's vendor input report 35 is `0x22` in the typing position, `0x33` part-way round, and `0x43` folded behind the screen; the cover sends that report on each change. linux-surface reads the same report as a fold switch, but only for another cover model (product `09c0`), so the kernel gives this one no switch.

`coverd/` is a small C program, `gimbal-sp4-coverd`, and the only part of Gimbal SP4 that is given access the user does not already have. How it is confined:

- **Started per device by udev and systemd.** `70-gimbal-sp4-cover.rules` matches only the cover's interface-0 hidraw node and asks systemd for `gimbal-sp4-coverd@hidrawN.service`. The instance is bound to that device and stops when the cover goes away. The rule does not change the node's owner or mode.
- **It never opens the device.** systemd opens `/dev/hidrawN` read-only as the service's standard input and then drops to a dynamic user (`DynamicUser=yes`), allocated when the instance starts and released when it stops. That user has no login, no groups, and no permission to open any hidraw node; the unit's device list admits only that one node, and only for systemd's open. The service has no capabilities, an empty private `/dev`, no network or sockets of any family, a read-only file system except `/run/gimbal-sp4-cover`, an allow-list syscall filter, no core dumps, and `NoNewPrivileges`. `systemd-analyze security` rates the unit 0.2 ("SAFE").
- **It checks what it was given.** It exits unless standard input is a read-only hidraw node for USB `045e:07e8` on interface 0 whose report descriptor declares report 35 as measured. It takes no arguments and reads no environment variables.
- **It cannot send anything to the cover.** hidraw does not check a descriptor's access mode for ioctls, so read-only alone would not stop a feature or output report being sent. After its checks the program installs its own seccomp filter: 13 syscalls needed by the loop, and `ioctl` only as GET_REPORT (`HIDIOCGINPUT(64)`) on standard input. Anything else kills it.
- **It reads one byte.** Of every report, it looks only at the ID and, for report 35, the first data byte. Other reports, including keystrokes, are discarded once their ID has been checked, and the buffer is wiped. It never logs, stores, or forwards report contents; the journal only sees the fold word and errors.
- **It publishes one word.** `/run/gimbal-sp4-cover/fold` (0644) contains `typing`, `between`, `folded`, or `unknown`. The file is replaced atomically on change and removed when the helper stops, so a stale `folded` cannot outlive it. After a suspend it asks the cover again (GET_REPORT), because a fold during suspend may send no report.
- **Its files are root-owned.** The installer builds and tests it as you, then installs `/usr/local/lib/gimbal-sp4/gimbal-sp4-coverd`, `/etc/systemd/system/gimbal-sp4-coverd@.service`, and `/etc/udev/rules.d/70-gimbal-sp4-cover.rules` as root. No user account is created. Nothing it runs is writable by your user. Read `coverd/` before installing it.

Giving the user, or a group, read access to the node would have been simpler, but it would let any process in the session read keystrokes, including those typed at a password prompt. A root daemon with capabilities dropped would still own every root file the sandbox left visible. Handing it a single read-only descriptor, with ioctls limited to GET_REPORT, keeps both out. A dynamic user rather than a static system user means no account is added and nothing it owns can outlive an instance, since its only writable directory is removed at stop.

The Lua half reads the word (at most 16 bytes, one of the four words) on its existing poll. While the cover is present, `folded` means folded and `typing` means attached. `between`, `unknown`, or no file keeps the last settled reading, so the half-way position never flips the mode. Just after a reload or a reattach, with nothing settled yet, it waits up to five seconds for the helper's word before counting the cover as attached, so a cover reattached folded goes straight to tablet mode. If the helper's unit file is not installed, the word is not read and everything behaves as detach-only detection.

`make -C coverd check` runs the helper's unit and end-to-end tests. `tests/coverd-sandbox.sh` runs its event loop under the unit's syscall filter as a user service. `lua tests/cover_sim.lua` checks the Lua transitions offline.

## Source layout

- `lua/gimbal_sp4.lua`: tablet mode, Type Cover detection, and focus handling. It publishes `tablet` or `laptop` to `$XDG_RUNTIME_DIR/gimbal-sp4-mode` and `attached`, `detached`, `folded`, or `unknown` to `$XDG_RUNTIME_DIR/gimbal-sp4-cover`. It polls `/proc/bus/input/devices` twice a second for a device named `… Surface Type Cover Keyboard`, because Hyprland's Lua API has no device events and the SP4 has no tablet-mode switch. A detached reading must hold for two reads and, after startup or resume, for five seconds, because resume can drop the cover for about 2.5 seconds while USB re-enumerates.
- `Panel.qml` and `BarWidget.qml`: Gimbal's Quickshell UI, with an always-visible keyboard and mode button.
- `osk/`: Gimbal's Wayland virtual keyboard, built as `gimbal-sp4-oskbd` and using separate runtime state names.
- `bin/gimbal-sp4-mode`: command-line mode control. `gimbal-sp4-mode cover` also shows what the fold helper reports.
- `coverd/`: the optional fold helper, its systemd unit and udev rule (in `coverd/system/`), and its tests.
- `tests/`: the offline Type Cover simulation and the helper's sandbox test.
- `bin/patch-overlays.py`: updates cloned unlocked-session popups so touch reaches the keyboard.
- `lock-clone/`: the lock-screen keypad (`LockKeypad.qml`) and the patch to Omarchy's `LockView.qml`. See [its README](lock-clone/README.md).
- `menu-clone/`, `upstream/`: inherited reference material.

The keyboard, bar, and lock view consume the mode word rather than Surface sensor names. That seam keeps hardware detection in one place.
