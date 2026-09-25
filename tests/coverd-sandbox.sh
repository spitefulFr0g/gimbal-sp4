#!/usr/bin/env bash
# Run the fold helper under the seccomp and sandbox settings of
# coverd/system/gimbal-sp4-coverd@.service, as transient user services:
#  - the production binary with /dev/null as its device, which must refuse it
#    with exit 2 (not be killed by the filter while starting up and checking);
#  - the event loop (test_coverd --serve-stdin, which also installs the
#    program's own seccomp filter) fed reports through a FIFO.
# It needs no root: settings a user manager cannot apply (User=, devices, file
# system protection) are left to the real unit.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
unit_file="$repo/coverd/system/gimbal-sp4-coverd@.service"
bin="$repo/coverd/test_coverd"
daemon="$repo/coverd/gimbal-sp4-coverd"
make -C "$repo/coverd" --no-print-directory gimbal-sp4-coverd test_coverd >/dev/null

work=$(mktemp -d)
unit="gimbal-sp4-coverd-sandbox-$$"
trap 'exec 3>&- 2>/dev/null || true; systemctl --user stop "$unit" 2>/dev/null || true; rm -rf "$work"' EXIT
mkfifo "$work/device"
mkdir "$work/state"

# Copy the settings that decide which syscalls and memory mappings the
# process may use. A transient unit does not accept
# RestrictAddressFamilies=none, so an allow list of one family the loop never
# uses stands in for it: socket() and socketpair() still fail for every other
# family, including AF_UNIX.
props=()
while IFS= read -r line; do
    [[ $line == RestrictAddressFamilies=none ]] && line=RestrictAddressFamilies=AF_PACKET
    props+=(-p "$line")
done < <(grep -E '^(SystemCallFilter|SystemCallArchitectures|MemoryDenyWriteExecute|RestrictAddressFamilies|LockPersonality|NoNewPrivileges|RestrictNamespaces|RestrictRealtime|RestrictSUIDSGID|UMask|LimitCORE|LimitNOFILE)=' "$unit_file")

state() { cat "$work/state/fold" 2>/dev/null || echo missing; }
expect() {
    for _ in $(seq 100); do
        [[ $(state) == "$1" ]] && return 0
        sleep 0.05
    done
    echo "FAIL: expected $1, have $(state)" >&2
    cat "$work"/run*.log >&2 2>/dev/null || true
    exit 1
}
report() { printf "$1" >&3; sleep 0.2; }

run() {
    systemd-run --user --quiet --wait --collect --unit="$unit" "${props[@]}" \
        -p StandardInput=file:"$work/device" \
        "$bin" --serve-stdin "$work/state"
}

# 0. The production binary: through startup and its device checks under the
# unit's filter, refusing /dev/null with exit 2.
rc=0
systemd-run --user --quiet --wait --collect --unit="$unit-daemon" "${props[@]}" \
    -p StandardInput=file:/dev/null "$daemon" > "$work/run0.log" 2>&1 || rc=$?
[[ $rc == 2 ]] || { echo "FAIL: production binary on /dev/null gave exit $rc, want 2" >&2; cat "$work/run0.log" >&2; exit 1; }

# 1. Reports, then a stop request.
exec 3<>"$work/device"
run 3>&- > "$work/run1.log" 2>&1 &
runner=$!
expect folded
report '\x23\x22\x03\x70\x00\xb8\xff\x91\x00\x27\xfc\x3d\xff\xbe\xfc\x18\xfe'
expect typing
report '\x01\x00\x00\x04\x00\x00\x00\x00\x00'
report '\x23\x33\x03\x12\x01\x09\x00\x69\x00\xf0\x03\xf1\xff\x94\xfc\x1c\x00'
expect between
report '\x23\x43\x03\x68\x01\xa7\xff\xd1\x03\x08\x01\x7c\xff\x5a\xfc\x0d\xff'
expect folded
systemctl --user stop "$unit"
rc=0; wait "$runner" || rc=$?
[[ $rc == 0 ]] || { echo "FAIL: stop gave exit $rc" >&2; cat "$work/run1.log" >&2; exit 1; }
expect missing
exec 3>&-

# 2. The device goes away (the writer closes): exit 69, state removed.
exec 3<>"$work/device"
run 3>&- > "$work/run2.log" 2>&1 &
runner=$!
expect folded
exec 3>&-
rc=0; wait "$runner" || rc=$?
[[ $rc == 69 ]] || { echo "FAIL: device gone gave exit $rc" >&2; cat "$work/run2.log" >&2; exit 1; }
expect missing

echo "coverd sandbox test passed ($(( ${#props[@]} / 2 )) unit settings applied)"
