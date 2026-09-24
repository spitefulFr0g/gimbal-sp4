# Plan: `gimbal-sp4`

Drafted 2026-09-23. Target: Omarchy 4 on the Surface Pro 4, with an on-screen keyboard usable by touch after unlock. A second Surface model can be added after its hardware is measured.

Implementation update, 2026-09-23: milestones 0–2 are implemented and installed on this SP4. The plugin validates, the keyboard builds and maps, the dock reserves and releases screen space, manual mode persists, and a synthetic key reached a focused Foot terminal. Real finger input in the bar, browser, terminal, and Omarchy popups remains to be checked by hand. Milestones 3 and 4 remain future work.

Implementation update, 2026-09-23 (later): milestone 4's lock keypad is implemented and installed. The patch applies exactly to Omarchy 4.0.4's `LockView.qml`, the clone loads without QML errors, and a lock preview showed a stock view in laptop mode and the keypad in tablet mode. A real lock, touch unlock, wrong password, idle lock, and physical-keyboard fallback remain to be tested by hand. This SP4 has no fingerprint reader enrolled. Milestone 3 remains future work.

## Why fork Gimbal

[Gimbal](https://github.com/mechanicsunlocked/gimbal) already has the desired Omarchy bar widget, a Wayland keyboard that can send modifiers and shortcuts, a settings panel, and a lock-screen keypad. Its [MIT license](https://github.com/mechanicsunlocked/gimbal/blob/master/LICENSE) permits a fork with attribution. [`omarchy-surface-touch`](https://github.com/javon27/omarchy-surface-touch) is a useful Surface keyboard and touch-patch reference, but has no integrated keyboard bar icon or movable keyboard. Begin from a pinned Gimbal commit and keep the original project as an upstream remote so later fixes can be reviewed and merged.

The main incompatibility is Gimbal's hardware module, not Omarchy or the touchscreen. It expects a Framework `gpio-keys` tablet switch, `cros-ec-lid-angle`, and `accel-display` ([source](https://github.com/mechanicsunlocked/gimbal/blob/master/lua/gimbal.lua)). This SP4 reports `accel_3d`, `gyro_3d`, `als`, and `dev_rotation`, with no Framework fold source. Gimbal gates its [bar widget](https://github.com/mechanicsunlocked/gimbal/blob/master/BarWidget.qml), [keyboard process](https://github.com/mechanicsunlocked/gimbal/blob/master/Panel.qml), and [lock keypad](https://github.com/mechanicsunlocked/gimbal/blob/master/lock-clone/LockView.qml) on that mode. Its Framework boot fix must not be installed on a Surface.

## Milestones

### 0. Fork and preserve a recoverable baseline

- Create `gimbal-sp4` from pinned upstream commit `97aa6d44e4949f820cb905673612c11d161aad21` (the commit reviewed for this plan); record upstream URL, license, and deviations in the README.
- Give the Omarchy plugin its own namespaced ID and rename IPC/runtime state so it can be distinguished from Gimbal. Update manifests, install/uninstall scripts, and generated file paths together. The fork should not overwrite an installed Gimbal.
- Audit every install action before running it. Make the Framework kernel/module boot fix unavailable in the SP4 installer. Add an install mode for only the unlocked keyboard; defer lock and Omarchy overlay clones.
- Validate the manifest and installer on a disposable config/home first. Keep a Type Cover or other hardware keyboard available for all live tests.

**Done when:** the fork can be installed, validated, and removed without touching Framework-specific boot configuration or an existing Gimbal install.

### 1. Make tablet state a small interface with a Surface adapter

- Put a seam at the existing runtime mode state: consumers should need only `tablet` or `laptop`, plus the existing keyboard-visible state. A Surface adapter owns how that state is decided; the keyboard, bar, and lock view should not read individual sensor names.
- Implement a persistent manual tablet-mode toggle first. The top-bar keyboard icon must remain available even if state detection fails; touching it must summon and hide the keyboard. Preserve `SUPER+B` as a fallback.
- Inspect how the SP4 exposes Type Cover attach/detach and any tablet switch on this machine. Add automatic transitions only after detach/reattach behavior is measured; manual mode must still work if the cover or sensors are absent.
- Keep rotation separate from text input. If later enabled, map the Surface `accel_3d`/`dev_rotation` readings and touchscreen coordinates on the actual device, with a rotation lock and a safe default orientation.

**Done when:** with the Type Cover removed, the bar button remains touchable and the mode does not unexpectedly revert after screen rotation, suspend, or shell restart.

### 2. Deliver a dependable bottom keyboard

- Build Gimbal's keyboard on the SP4 and scale its key geometry for this display (2736×1824 at scale 2). Replace Framework-specific key legends where helpful without changing actual Super/Control/Alt behavior.
- Offer bottom overlay and bottom space-reserving modes; start with a manual bar toggle. Treat automatic text-field appearance as an optional setting because application support varies ([Gimbal known issues](https://github.com/mechanicsunlocked/gimbal/blob/master/KNOWN-ISSUES.md)).
- Test real finger input in a GTK text field, browser, terminal, Omarchy menu, and password prompt. Check that keypresses reach the intended window, modifiers work, the keyboard stays up when needed, and the bar icon reflects actual visibility. Reuse Gimbal's overlay-clone fix only where live tests show it is required.

**Done when:** the SP4 can enter text in those apps with its Type Cover detached and can always dismiss or summon the keyboard by touch.

### 3. Add a movable floating layout

- Add a compact keyboard mode to the existing keyboard engine, with a dedicated touch drag handle, remembered position, screen-edge constraints, and portrait/landscape repositioning. Do not make ordinary key swipes move the board.
- In floating mode use an overlay with no exclusive zone; in docked mode retain the chosen bottom behavior. Verify that dragging does not steal keyboard focus from the field being edited.
- Test movement, typing, hide/show, rotation, and focus with real touch. Gimbal's movable *knobs* are a UI reference, but its keyboard currently supports only fixed top/middle/bottom positions ([README](https://github.com/mechanicsunlocked/gimbal/blob/master/README.md#the-keyboard)).

**Done when:** a user can switch between bottom and floating modes, drag the floating keyboard by touch, and keep typing into the same application.

### 4. Add touch unlock without changing the password system

- Adapt Gimbal's [lock-screen clone and QWERTY keypad](https://github.com/mechanicsunlocked/gimbal/blob/master/lock-clone/README.md) to be available on this Surface without a Framework fold signal. Keep it inside the lock surface: an ordinary layer-shell keyboard cannot render or receive input while locked.
- Use the existing account-password authentication and fingerprint path. Do not add a PIN or alter PAM as part of this milestone. Treat `omarchy-surface-touch`'s optional PIN as a separate later decision.
- Check the patch against the installed Omarchy `LockView.qml`, preview the clone, then test real lock/unlock, wrong password, fingerprint, idle lock, and fallback to physical keyboard. Keep a hardware keyboard available until the live tests pass. Recheck the clone after Omarchy updates.

**Done when:** the SP4 can unlock by touch after a real lock, and existing password and fingerprint behavior still work. This does not cover the pre-boot disk-unlock prompt.

## First implementation slice

Start with milestones 0–2 only. They solve the immediate text-input problem and reveal the actual touch/focus behavior before adding movement or lock-screen changes. Milestones 3 and 4 remain explicit project goals rather than assumptions about Gimbal's current capabilities.
