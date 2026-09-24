# The lock screen keypad

A clone of Omarchy's own lock screen (`omarchy.lock`) with one addition: a
keypad drawn by the lock screen itself. On the Surface Pro 4 it opens with the
lock screen in tablet mode, and a finger or pen tap on the password field opens
it in either mode. Tablet mode is a manual choice that cannot be changed while
locked, so a Surface locked in laptop mode and then undocked still has a way
in. Mouse and touchpad clicks on the field behave exactly as in stock Omarchy.

## Why it cannot ship in the plugin

Two reasons, and both are hard limits rather than preferences.

**The protocol.** The lock screen is an `ext-session-lock` surface. While the
session is locked, the compositor renders *only* lock surfaces and delivers
input *only* to them; every layer surface, including Gimbal's keyboard, is
neither drawn nor touchable. A keyboard for the lock screen therefore has to
be part of the lock screen. There is no protocol path around this, and that is
by design — it is what makes a lock screen a lock screen.

**The plugin system.** Omarchy's lock screen is a first-party plugin of kind
`service`, and a third-party plugin cannot shadow a first-party id or add
itself to another plugin's surface. What Omarchy does offer is
`omarchy plugin clone`: it copies a built-in plugin into your own config as
`<username>.lock`, switches to it, and routes every `lock` IPC call to it. So
the keypad lives in a clone, and the clone lives here as a diff against the
stock files — not in the plugin.

Upstream draft **B** (`upstream/B-lock-extension-slot.md`) asks for a proper
extension point, with these files as the proof of shape.

## What is in here

| file | state |
|---|---|
| (no `manifest.json`) | `omarchy plugin clone` writes it on your machine, with your username in the id and `clonedFrom: omarchy.lock`; a copy here would make the repo look like two plugins |
| `Service.qml` | untouched |
| `LockView.qml` | stock, plus the `gimbal-sp4-mode` reader, the touch tap on the field, and the keypad |
| `LockView.patch` | the same change as a patch against the stock file; `install.sh` applies it with no fuzz to Omarchy's current file and refuses, with a warning, if that has changed |
| `LockKeypad.qml` | new: plain QWERTY, digits, a symbols page, one-shot shift |

`git log -- lock-clone/` shows the stock files as their own commit, so the
diff is the whole change.

## Installing it

`./install.sh` does this. It creates the clone with `omarchy plugin clone
omarchy.lock` (the id carries your username, so it is created on your machine
rather than copied from here), marks it with `.gimbal-sp4-owned`, and on every
run copies the current stock `Service.qml`, a freshly patched stock
`LockView.qml`, and `LockKeypad.qml` into it. An existing `<you>.lock` without
the marker is yours and is left alone.

The installer then restarts the shell. This is not optional: saving a plugin
file hot-reloads it, but Qt caches compiled components by URL and an
already-loaded `LockView` keeps its old code until the shell restarts
(FINDINGS 3.1i and 19.3).

Check it took:

```bash
journalctl --user -t omarchy-shell --since -1min | grep -i -E 'lock|error'
omarchy-shell lock status
omarchy-shell lock preview      # stock in laptop mode, keypad in tablet mode
omarchy-shell lock hidePreview
```

Then lock by hand (`SUPER + CTRL + L`) once while the Type Cover is attached,
before relying on it undocked. `TESTING.md` has the checklist.

After an Omarchy update, run `./install.sh` again. If the stock `LockView.qml`
changed so the patch no longer applies exactly, the installer removes the
clone and the stock lock screen returns; update the patch before reinstalling.

## Taking it out

`./uninstall.sh` removes the clone if it carries the marker. By hand:

```bash
omarchy plugin remove <you>.lock
rm -rf ~/.config/omarchy/plugins/.<you>.lock.bak.*    # the hidden backup `plugin remove` keeps
```

Removing an active clone switches back to the built-in (`shell/README.md`,
"Cloning").

## What it does not do yet

- It is a keypad for a password, not the full on-screen keyboard.
- The layout is QWERTY whatever `input:kb_layout` says. A password typed on
  it is the characters shown on it.
- Fingerprint, the idle blank and the wrong-password state are the stock
  code paths, untouched; the checklist in `TESTING.md` covers them with the
  keypad up.
- The ⌄ key puts the keypad away; a touch tap on the field brings it back.
- It does not cover the pre-boot disk-unlock prompt.
