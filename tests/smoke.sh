#!/usr/bin/env bash
# smoke.sh — pre-publish assertions, executed inside the built arm64 image.
# CI runs it as:
#   docker run --platform linux/arm64 -i --rm IMAGE bash -s < tests/smoke.sh
# Any failure stops the workflow: a broken build is never published.
# =============================================================================
set -Eeuo pipefail

fail() { printf '\nSMOKE FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'smoke: %s\n' "$1"; }

# 1. core binaries
if [ ! -x /usr/bin/pacman ]; then fail "pacman missing"; fi
if [ ! -x /usr/bin/bash ];   then fail "bash missing"; fi
pass "core binaries present"

# 2. package set has plausible size
N=$(pacman -Qq | wc -l)
if [ "$N" -lt 90 ]; then fail "only $N packages installed"; fi
pass "$N packages installed"

# 3. the systemd trio never made it in (also catches surprise hard deps)
if pacman -Q systemd          >/dev/null 2>&1; then fail "systemd is installed"; fi
if pacman -Q systemd-sysvcompat >/dev/null 2>&1; then fail "systemd-sysvcompat is installed"; fi
if pacman -Q cryptsetup       >/dev/null 2>&1; then fail "cryptsetup is installed"; fi
if [ -e /usr/lib/systemd/systemd ]; then fail "systemd binaries present"; fi
pass "no systemd"

# 4. no kernel / firmware junk, ever
if [ -d /boot ] && [ -n "$(ls -A /boot 2>/dev/null)" ]; then fail "/boot is not empty"; fi
if [ -d /usr/lib/firmware ] && [ -n "$(ls -A /usr/lib/firmware 2>/dev/null)" ]; then
    fail "/usr/lib/firmware is not empty"
fi
pass "no kernel/firmware junk"

# 5. pacman.conf proot tuning (CheckSpace / DownloadUser must be OFF)
if grep -qE '^(CheckSpace|DownloadUser[[:space:]]*=)' /etc/pacman.conf; then
    fail "pacman.conf has CheckSpace/DownloadUser enabled — not proot-tuned"
fi
pass "pacman.conf tuned for proot"

# 6. locale generated at build
locale -a 2>/dev/null | grep -qi '^en_US\.utf8$' || fail "en_US.UTF-8 not generated"
pass "locale en_US.UTF-8 present"

# 7. per-device identity was NOT baked
if [ -s /etc/machine-id ]; then
    fail "machine-id is not empty — per-device identity must never be baked"
fi
pass "machine-id empty"

# 8. keyring sane
pacman-key --populate archlinuxarm >/dev/null 2>&1 || fail "keyring populate failed"
pass "keyring checks out"

# 9. live repo sync — proves mirror + keyring + DNS in one shot
pacman --noconfirm -Sy >/dev/null || fail "pacman -Sy failed (network/mirror/keyring)"
pass "repositories synced live"

printf '\nALL SMOKE CHECKS PASSED (%s packages)\n' "$N"
