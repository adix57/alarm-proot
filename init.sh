#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# init.sh — Arch Linux ARM on-device setup for proot-distro (Termux/Android)
# =============================================================================
# Run after installing the container:
#   proot-distro install ghcr.io/adix57/alarm-proot:latest --name archlinux
#   curl -O https://raw.githubusercontent.com/adix57/alarm-proot/main/init.sh
#   bash init.sh
# Works from the Termux side or inside the container (it detects where it
# runs). Also safe on rootfses installed from the stock ALARM tarball — its
# cleanup step then removes the unusable kernel/firmware/systemd payload.
#
# What it does: pacman.conf proot tuning, DNS (from Termux when available,
# with public fallbacks), machine-id, locale, sshd readiness, root shell with
# helper aliases, keyring init + best-effort `pacman -Sy` (offline-safe).
#
# FLAGS (both modes):
#   --force | -f     re-run even if /root/.arch-init-complete exists
#   --upgrade | -u   also run a full `pacman -Syu` at the end
#   --no-trim        keep cryptsetup/device-mapper/iptables/nftables/dhcpcd/
#                    netctl/gpm installed
#   --keep-systemd   keep the systemd package (default: removed)
#   --dry-run        print everything that would happen, change nothing
#   --name NAME      Termux side only: target container (default archlinux)
#   -h | --help      show this header
# ==============================================================================

# Re-exec under bash if launched by some other shell (busybox sh etc.)
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi

# ------------------------------------------------------------------ plumbing --
if [ -t 1 ]; then
    C0=$'\033[0m'; C_B=$'\033[1;34m'; C_G=$'\033[1;32m'; C_Y=$'\033[1;33m'; C_R=$'\033[1;31m'
else
    C0=""; C_B=""; C_G=""; C_Y=""; C_R=""
fi

msg()  { printf '%s ==> %s%s\n'  "$C_B" "$1" "$C0"; }
ok()   { printf '%s   [done]%s %s\n' "$C_G" "$C0" "$1"; }
warn() { printf '%s  [warn]%s %s\n'  "$C_Y" "$1" "$C0" >&2; }
die()  { printf '%s [error]%s %s\n'  "$C_R" "$1" "$C0" >&2; exit "${2:-1}"; }

# run a mutating command — in --dry-run just print it
run() {
    if [ "$DRY" = 1 ]; then
        printf '%s[dry-run] %s' "$C_Y" "$C0"; printf '%q ' "$@"; printf '\n'
        return 0
    fi
    "$@"
}

# write a file delivered on stdin atomically; respects --dry-run
#   usage:  cat ... | file_write DEST [MODE]      or  ... | file_write DEST
file_write() {
    local dest="$1" mode="${2:-644}" tmp="$1.tmp.$$"
    if [ "$DRY" = 1 ]; then
        printf '%s[dry-run] would write file %s (mode %s)%s\n' "$C_Y" "$dest" "$mode" "$C0"
        return 0
    fi
    { cat > "$tmp" && chmod "$mode" "$tmp" && mv -f "$tmp" "$dest"; } \
        || { rm -f "$tmp"; return 1; }
    return 0
}

# list of installed packages. Uses pacman when it is usable (the real
# container); falls back to reading the local DB dir — handy for --dry-run
# launched from a foreign host, and harmless otherwise.
pkg_list() {
    local out=""
    if command -v pacman >/dev/null 2>&1; then
        out="$(pacman -Qq 2>/dev/null)" || out=""
        [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
    fi
    if [ -d /var/lib/pacman/local ]; then
        # db dirs are "<name>-<pkgver>-<pkgrel>"; strip the version suffix
        ls /var/lib/pacman/local 2>/dev/null | grep -v '^ALPM_DB_VERSION' |
            sed -E 's/-[0-9][A-Za-z0-9.+_~:]*-([0-9]+)$//'
    fi
}

usage() {
    awk '/-h[[:space:]]*\|[[:space:]]*--help/ {print; exit} NR > 1 {print}' "$0" | sed 's/^#  *//'
}

# --------------------------------------------------------------------- flags --
FORCE=0; UPGRADE=0; TRIM=1; KEEP_SYSTEMD=0; DRY=0; NAME=""

parse_flags() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --force|-f)        FORCE=1 ;;
            --upgrade|-u)      UPGRADE=1 ;;
            --no-trim)         TRIM=0 ;;
            --keep-systemd)    KEEP_SYSTEMD=1 ;;
            --dry-run)         DRY=1 ;;
            --name)            [ $# -ge 2 ] || die "--name needs a value"; NAME="$2"; shift ;;
            -h|--help)         usage; exit 0 ;;
            *)                 die "unknown option: $1 (see --help)" ;;
        esac
        shift
    done
}

# ---------------------------------------------------------------- mode detect --
is_inside_container() {
    # debug escape hatch for testing: PROOT_INIT_ASSUME_CONTAINER=1
    [ "${PROOT_INIT_ASSUME_CONTAINER:-0}" = 1 ] && return 0
    # new (python) proot-distro exports both of these into every guest session
    [ "${container:-}" = "proot-distro" ] && return 0
    [ -n "${PD_CONTAINER:-}" ] && return 0
    # legacy (bash) proot-distro did not export identity vars, but every proot
    # session binds the HOST's /proc — inside Termux that kernel banner says
    # Android, which a desktop Arch Linux host never does.
    if [ -f /etc/arch-release ] && command -v pacman >/dev/null 2>&1; then
        grep -qi android /proc/version 2>/dev/null && return 0
        [ -d /data/data/com.termux ] && return 0
    fi
    return 1
}

# ==============================================================================
#  HOST MODE (Termux side): copy ourselves in, execute, hand back the session
# ==============================================================================
host_main() {
    local name="${NAME:-${PD_NAME:-archlinux}}"

    local pd
    pd="$(command -v proot-distro 2>/dev/null)" \
        || die "proot-distro not found in PATH (pkg install proot-distro)"

    # rootfs candidates: new python layout, legacy bash layout, non-Termux host
    local candidates=()
    local pd_prefix="${PREFIX:-${TERMUX_PREFIX:-${TERMUX__PREFIX:-}}}"
    [ -n "$pd_prefix" ] && candidates+=(
        "$pd_prefix/var/lib/proot-distro/containers/$name/rootfs"
        "$pd_prefix/var/lib/proot-distro/installed-rootfs/$name"
    )
    candidates+=(
        "${XDG_DATA_HOME:-$HOME/.local/share}/proot-distro/containers/$name/rootfs"
        "$HOME/.local/share/proot-distro/containers/$name/rootfs"
    )

    local rootfs="" d
    for d in "${candidates[@]}"; do
        [ -d "$d" ] && { rootfs="$d"; break; }
    done
    if [ -z "$rootfs" ]; then
        printf '%s[error]%s container '"'"'%s'"'"' not found%s\n' "$C_R" "$C0" "$name" "$C0"
        printf '  install it first, then re-run:\n'
        printf '      proot-distro install ghcr.io/adix57/alarm-proot:latest --name %s\n' "$name"
        printf '      bash %s\n' "$PROG"
        exit 1
    fi

    local pass=()
    [ "$FORCE" = 1 ]        && pass+=( --force )
    [ "$UPGRADE" = 1 ]      && pass+=( --upgrade )
    [ "$TRIM" = 0 ]         && pass+=( --no-trim )
    [ "$KEEP_SYSTEMD" = 1 ] && pass+=( --keep-systemd )

    if [ "$DRY" = 1 ]; then
        printf '%s[dry-run] would: cp %s %s/init.sh%s\n' "$C_Y" "$SELF" "$rootfs" "$C0"
        printf '%s[dry-run] would: proot-distro login %s -- /bin/bash /init.sh%s' "$C_Y" "$name" "$C0"
        if [ ${#pass[@]} -gt 0 ]; then printf ' '; printf '%q ' "${pass[@]}"; fi
        printf '\n'
        return 0
    fi

    msg "copying $PROG into container '$name' ..."
    if command "$pd" copy "$SELF" "$name:/init.sh" >/dev/null 2>&1; then
        ok "copied via proot-distro copy"
    elif cp "$SELF" "$rootfs/init.sh" 2>/dev/null; then
        ok "copied directly into $rootfs/init.sh"
    else
        die "could not copy the script into the container rootfs"
    fi

    msg "running container setup (this takes a few minutes) ..."
    exec "$pd" login "$name" -- /bin/bash /init.sh "${pass[@]}"
}

# ==============================================================================
#  CONTAINER MODE — all of the real setup lives here
# ==============================================================================

# --- 1. pacman.conf ------------------------------------------------------------
configure_pacman() {
    msg "adjusting /etc/pacman.conf for the proot environment ..."
    [ -f /etc/pacman.conf ] || die "/etc/pacman.conf missing — this does not look like an Arch rootfs"

    # CheckSpace: proot bind mounts make df() results meaningless, and pacman
    # would abort transactions with bogus "insufficient free disk space".
    if grep -qE '^CheckSpace[[:space:]]*$' /etc/pacman.conf; then
        run sed -i 's/^CheckSpace$/#CheckSpace/' /etc/pacman.conf
        ok "CheckSpace disabled"
    fi

    # pacman>=7 sandboxed downloads (setuid to the `alpm` user) need real root;
    # under proot every download fails with "cannot switch to uid 65534"/984.
    if grep -qE '^DownloadUser' /etc/pacman.conf; then
        run sed -i -E 's/^DownloadUser[[:space:]]*=.*$/#DownloadUser = alpm/' /etc/pacman.conf
        ok "DownloadUser disabled (proot cannot setuid)"
    fi
}

# --- 2. resolv.conf / hostname / machine-id -------------------------------------
configure_dns_and_misc() {
    msg "configuring DNS and basic identity ..."

    local ns="" termux_resolv="/data/data/com.termux/files/usr/etc/resolv.conf"
    if [ ! -s /etc/resolv.conf ] || [ ! -e /etc/resolv.conf ] ||
       { [ -f /etc/resolv.conf ] && ! grep -q '^nameserver' /etc/resolv.conf; }; then
        # Termux prefix is bound at its real path by proot-distro by default;
        # reuse the device-side DNS setup when we can see it.
        if [ -r "$termux_resolv" ]; then
            ns="$(grep -E '^nameserver[[:space:]]+[0-9A-Za-z.:\[\]]+$' "$termux_resolv" | head -4)"
        fi
        [ -z "$ns" ] && ns="nameserver 8.8.8.8
nameserver 8.8.4.4
nameserver 1.1.1.1"
        cat <<RESOLV | file_write /etc/resolv.conf 644
# Static DNS for the proot-distro container (written by init.sh)
# Edit freely; run 'init.sh --force' or delete this file to regenerate.
$ns
RESOLV
        ok "wrote /etc/resolv.conf"
    else
        ok "resolv.conf already has a resolver — left alone"
    fi

    if [ ! -s /etc/hostname ]; then
        printf 'archlinux\n' | file_write /etc/hostname 644
        ok "wrote /etc/hostname"
    fi

    # several systemd-libs consumers fail politely-but-noisily on an empty id
    if [ ! -s /etc/machine-id ]; then
        local mid
        mid="$(mcookie 2>/dev/null || file /etc/os-release | md5sum)"
        mid="$(printf '%s' "$mid" | tr -cd 'a-f0-9' | head -c 32)"
        if [ -n "$mid" ]; then
            printf '%s\n' "$mid" | file_write /etc/machine-id 444
            ok "generated /etc/machine-id"
        fi
    fi
}

# --- 3. keyring (offline, best-effort) ------------------------------------------
# NOTE: this deliberately runs AFTER the removal step etc. Nothing here needs
#       the network except the initial `-Sy`; sync failures are warnings so a
#       device without connectivity right now still ends with a clean,
#       functional container.
init_keyring() {
    msg "setting up the pacman keyring ..."
    if [ -s /etc/pacman.d/gnupg/pubring.gpg ] && [ -s /etc/pacman.d/gnupg/trustdb.gpg ]; then
        ok "keyring already initialized"
    else
        run pacman-key --init
    fi
    # keyring FILE location: pacman>=7.1 reads /usr/share/keyrings; older
    # pacman builds and ALARM's archlinuxarm-keyring package place the files
    # under /usr/share/pacman/keyrings. Whichever shipped them, mirror to the
    # other so '--populate archlinuxarm' always finds its needles.
    local src dst
    for src in /usr/share/pacman/keyrings /usr/share/keyrings; do
        [ -f "$src/archlinuxarm.gpg" ] || continue
        dst=/usr/share/keyrings
        [ "$src" = "$dst" ] && dst=/usr/share/pacman/keyrings
        if [ ! -f "$dst/archlinuxarm.gpg" ]; then
            run mkdir -p "$dst"
            run cp -a "$src"/archlinuxarm* "$dst"/
            ok "keyring files mirrored into $dst"
        fi
    done
    run pacman-key --populate archlinuxarm
}

# --- 3b. repository sync (network, best effort, stale-keyring fallback) ---------
sync_repositories() {
    SYNC_OK=0
    if [ -n "${INIT_NO_NET:-}" ]; then
        warn "INIT_NO_NET set — skipping repository sync"
        return 0
    fi
    msg "syncing repositories (pacman -Sy) ..."
    if run pacman --noconfirm -Sy; then
        ok "repositories synced"
        SYNC_OK=1
        return 0
    fi

    warn "sync failed — trying the stale-keyring fallback (old tarballs) ..."
    local bak="/etc/pacman.conf.init.bak"
    [ "$DRY" = 1 ] || cp -a /etc/pacman.conf "$bak" 2>/dev/null
    run sed -i -E 's/^([[:space:]]*SigLevel[[:space:]]*=).*$/\1 Optional TrustAll/' /etc/pacman.conf

    if run pacman --noconfirm -Syy archlinuxarm-keyring; then
        run pacman-key --populate archlinuxarm
        [ "$DRY" = 1 ] || cp -a "$bak" /etc/pacman.conf 2>/dev/null
        rm -f "$bak"
        run sed -i -E 's/^([[:space:]]*SigLevel[[:space:]]*=).*$/\1 Required DatabaseOptional/' /etc/pacman.conf
        if run pacman --noconfirm -Sy; then
            ok "keyring updated, repositories synced"
            SYNC_OK=1
            return 0
        fi
    else
        [ "$DRY" = 1 ] || cp -a "$bak" /etc/pacman.conf 2>/dev/null
        rm -f "$bak"
        run sed -i -E 's/^([[:space:]]*SigLevel[[:space:]]*=).*$/\1 Required DatabaseOptional/' /etc/pacman.conf
    fi
    warn "repository sync still failing — clean offline container kept as-is"
    warn "re-run 'bash /init.sh' with internet later to sync (pacman -Sy)"
    return 0
}

# --- 3c. optional full upgrade (only meaningful when sync succeeded) ------------
run_upgrade_if_wanted() {
    [ "$UPGRADE" = 1 ] || return 0
    if [ "$SYNC_OK" != 1 ]; then
        warn "--upgrade requested but repositories are not synced — skipped"
        return 0
    fi
    msg "running full upgrade (pacman -Syu, systemd virtualized) ..."
    # Same virtualization as the `update` alias: a newer pacman package from
    # ALARM hard-depends systemd, and without this -Syu would pull the real
    # systemd (plus cryptsetup, device-mapper, iptables, kbd, kmod, ...).
    run pacman -Syu --noconfirm \
        --assume-installed systemd \
        --assume-installed systemd-sysvcompat
    ok "upgrade pass finished"
}

# --- 4. removals -----------------------------------------------------------------
remove_kernel_boot_systemd() {
    local list boot_sz mod_sz fw_sz n=0 freed

    msg "measuring pre-removal sizes ..."
    if [ "$DRY" != 1 ]; then
        boot_sz=$(du -sk /boot 2>/dev/null | cut -f1);            boot_sz=${boot_sz:-0}
        mod_sz=$(du -sk /usr/lib/modules 2>/dev/null | cut -f1);  mod_sz=${mod_sz:-0}
        fw_sz=$(du -sk /usr/lib/firmware 2>/dev/null | cut -f1);  fw_sz=${fw_sz:-0}
    fi

    msg "building the removal list ..."
    {
        # kernel package(s); never touch linux-api-headers (userland headers)
        pkg_list | grep -E '^linux-(aarch64|armv7|rpi|odroid|imx)[0-9.]*$' || true
        # every linux-firmware split package (amdgpu, atheros, broadcom, ...)
        pkg_list | grep '^linux-firmware' || true
        # initramfs generator — pointless without a kernel
        pkg_list | grep -E '^(mkinitcpio|mkinitcpio-busybox|mkinitcpio-archiso)$' || true
        # systemd front-ends; systemd-libs stays (libsystemd is widely linked)
        [ "$KEEP_SYSTEMD" = 0 ] && \
            pkg_list | grep -E '^(systemd|systemd-sysvcompat|systemd-resolvconf)$' || true
        # container-useless daemons; e2fsprogs deliberately stays (krb5 dep)
        [ "$TRIM" = 1 ] && \
            pkg_list | grep -E '^(cryptsetup|device-mapper|iptables|nftables|dhcpcd|netctl|gpm)$' || true
    } | sort -u > "$REMOVAL_LIST"

    if [ -s "$REMOVAL_LIST" ]; then
        n=$(wc -l < "$REMOVAL_LIST")
        msg "removing $n packages (pacman -Rdd) — this prints a lot ..."
        # shellcheck disable=SC2046 — the list is one package name per line
        if ! run pacman -Rdd --noconfirm $(cat "$REMOVAL_LIST"); then
            # one bad target/failed hook elsewhere should not lose the rest
            warn "bulk removal failed — retrying package by package ..."
            while IFS= read -r p; do
                [ -n "$p" ] || continue
                run pacman -Rdd --noconfirm "$p" ||
                    warn "could not remove '$p' (kept; harmless in a container)"
            done < "$REMOVAL_LIST"
        fi
    else
        msg "no removal candidates found (already cleaned?)"
    fi

    msg "clearing /boot, /usr/lib/modules and /usr/lib/firmware ..."
    run rm -rf /boot/*
    run rm -rf /usr/lib/modules/*
    run rm -rf /usr/lib/firmware/*
    # keep the directories themselves so pacman/tools don't error on missing parents
    run mkdir -p /boot /usr/lib/modules /usr/lib/firmware /run/lock

    if [ "$DRY" != 1 ]; then
        freed=$(( (boot_sz + mod_sz + fw_sz) / 1024 ))
        ok "kernel/boot/firmware space freed: ~${freed} MiB"
    fi
    REMOVED_COUNT=$n
}

# --- 4b. non-English message catalogs ------------------------------------------
trim_share_locale() {
    [ -d /usr/share/locale ] || return 0
    msg "trimming /usr/share/locale to English ..."
    local d before=0 after=0 count=0 freed
    [ "$DRY" = 1 ] || before=$(du -sk /usr/share/locale | cut -f1)
    for d in /usr/share/locale/*; do
        case "${d##*/}" in
            en|en_*|C|C.*) continue ;;
            *)
                [ "$DRY" = 1 ] || rm -rf "$d"
                count=$((count + 1))
                ;;
        esac
    done
    [ "$DRY" = 1 ] && printf '%s[dry-run] would trim non-en locale dirs%s\n' "$C_Y" "$C0"
    [ "$DRY" != 1 ] && after=$(du -sk /usr/share/locale | cut -f1)
    printf '%s   [done]%s trimmed /usr/share/locale (%d dirs)\n' "$C_G" "$C0" "$count"
    [ "$DRY" != 1 ] && {
        after=${after:-$before}
        freed=$(((before - after) / 1024))
        printf '%s   [done]%s locale space freed: ~%s MiB\n' "$C_G" "$C0" "$freed"
    }
    return 0
}

# --- 5. locale --------------------------------------------------------------------
configure_locale() {
    msg "generating UTF-8 locale (this can take a minute or two) ..."
    if [ -f /etc/locale.gen ] && grep -q '^#en_US\.UTF-8' /etc/locale.gen; then
        run sed -i 's/^#en_US\.UTF-8[[:space:]]*UTF-8.*/en_US.UTF-8 UTF-8/' /etc/locale.gen
    fi
    if [ "$DRY" = 1 ]; then
        printf '%s[dry-run] would run: locale-gen%s\n' "$C_Y" "$C0"
    elif [ -x /usr/bin/locale-gen ]; then
        locale-gen >/dev/null 2>&1 || warn "locale-gen failed (continuing with C.UTF-8)"
    fi

    local lang="C.UTF-8"
    if [ "$DRY" = 1 ]; then
        lang="en_US.UTF-8"
    elif [ -x /usr/bin/locale ] && locale -a 2>/dev/null | grep -qi '^en_US\.utf8$'; then
        lang="en_US.UTF-8"
    fi
    if [ ! -s /etc/locale.conf ]; then
        printf 'LANG="%s"\n' "$lang" | file_write /etc/locale.conf 644
        ok "LANG=$lang written to /etc/locale.conf"
    else
        ok "locale.conf exists — left alone"
    fi
}

# --- 6. sshd readiness --------------------------------------------------------------
configure_sshd() {
    command -v sshd >/dev/null 2>&1 || { ok "openssh not installed — skipping ssh step"; return 0; }
    msg "preparing sshd ..."
    run mkdir -p /run/sshd /run/lock
    # root in a rootless container is not a real root account; password login
    # is the point of the exercise for most users of this setup.
    if grep -qE '^#?[[:space:]]*PermitRootLogin' /etc/ssh/sshd_config 2>/dev/null; then
        run sed -i -E 's/^#?[[:space:]]*(PermitRootLogin[[:space:]]*).*/\1yes/' /etc/ssh/sshd_config
        ok "PermitRootLogin -> yes"
    fi
    if [ "$DRY" = 1 ]; then
        printf '%s[dry-run] would run: ssh-keygen -A%s\n' "$C_Y" "$C0"
    else
        ssh-keygen -A >/dev/null 2>&1
        ok "ssh host keys generated"
    fi
    [ "$DRY" = 1 ] || {
        : > /var/log/lastlog
        : > /var/log/wtmp
        : > /var/log/btmp
        chmod 600 /var/log/btmp 2>/dev/null
        chmod 664 /var/log/lastlog /var/log/wtmp 2>/dev/null
    }
}

# --- 7. root shell -------------------------------------------------------------------
configure_root_shell() {
    msg "writing root shell profiles ..."
    if [ ! -f /root/.bash_profile ]; then
        cat <<'BASHPF' | file_write /root/.bash_profile 644
# ~/.bash_profile — login shell entry (generated by init.sh)
[ -f ~/.bashrc ] && . ~/.bashrc
BASHPF
        ok "created /root/.bash_profile"
    fi
    cat <<'BASHRC' | file_write /root/.bashrc 644
# ~/.bashrc — generated by init.sh (proot-distro arch container)
[[ $- == *i* ]] || return

PS1='\[\e[01;32m\]\u@\h\[\e[0m\]:\[\e[01;34m\]\w\[\e[0m\]\$ '
export HISTSIZE=5000 HISTFILESIZE=20000 HISTCONTROL=ignorespace:erasedups

alias ll='ls -lah --color=auto'
alias la='ls -A --color=auto'
alias grep='grep --color=auto'
# ALARM's pacman hard-depends systemd; this keeps full upgrades dep-consistent
# if/when ALARM ships a newer pacman package. NOTE: --assume-installed takes
# ONE package per flag — repeat the flag; a bare second name would be parsed
# as a transaction target and would install the real systemd-sysvcompat.
alias update='pacman -Syu --assume-installed systemd --assume-installed systemd-sysvcompat'

# ---- this container has no kernel access (proot) ---------------------------
# upgrade:        update              (= pacman -Syu with systemd virtualized)
# sshd:           mkdir -p /run/sshd && /usr/bin/sshd
#                 ^ from Termux: proot-distro login archlinux -- /usr/bin/sshd
#                 connect with: proot-distro login archlinux -P  (22 -> 2022)
# timezone:       ln -sf /usr/share/zoneinfo/<Area>/<City> /etc/localtime
# re-run setup:   bash /init.sh --force
BASHRC
    ok "wrote /root/.bashrc"
}

# --- 8. cleanup -----------------------------------------------------------------------
final_cleanup() {
    msg "cleaning caches ..."
    run pacman -Scc --noconfirm
    if [ "$DRY" = 1 ]; then
        printf '%s[dry-run] would run: ldconfig%s\n' "$C_Y" "$C0"
    else
        ldconfig 2>/dev/null
        ok "ld.so cache rebuilt"
    fi
}

# --- 9. marker + summary ----------------------------------------------------------------
write_marker_and_summary() {
    local marker=/root/.arch-init-complete
    if [ "$DRY" = 1 ]; then
        printf '%s[dry-run] would write marker %s%s\n' "$C_Y" "$marker" "$C0"
    else
        {
            printf '# created by init.sh\n'
            printf 'date=%s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
            printf 'packages-removed=%s\n' "$REMOVED_COUNT"
            printf 'systemd=%s\n' "$([ "$KEEP_SYSTEMD" = 1 ] && echo kept || echo removed)"
            printf 'trim=%s\n' "$([ "$TRIM" = 1 ] && echo yes || echo no)"
            printf 'upgrade=%s\n' "$([ "$UPGRADE" = 1 ] && echo yes || echo no)"
        } > "$marker"
        chmod 644 "$marker"
    fi

    printf '\n%s%s%s\n' "$C_G" "======================= setup complete =======================" "$C0"
    printf '  login:              %sproot-distro login archlinux%s\n' "$C_B" "$C0"
    printf '  sshd (optional):    %smkdir -p /run/sshd && /usr/bin/sshd%s\n' "$C_B" "$C0"
    printf '                      %sproot-distro login archlinux -P   (port 22 -> 2022)%s\n' "$C_B" "$C0"
    printf '  timezone:           %sln -sf /usr/share/zoneinfo/<Area>/<City> /etc/localtime%s\n' "$C_B" "$C0"
    printf '  full upgrade:       %supdate  (or re-run: bash /init.sh --upgrade)%s\n' "$C_B" "$C0"
    printf '  setup log:          /var/log/arch-proot-init.log\n'
    printf '  marker:             %s%s\n' "$marker" "$C0"
    if [ "$SYNC_OK" != 1 ]; then
        printf '  %sNOTE:%s repositories not synced (no network?) — run %spacman -Syu%s later\n' "$C_Y" "$C0" "$C_B" "$C0"
    fi
    printf '%s%s%s\n' "$C_G" "==============================================================" "$C0"
}

# ==============================================================================
#  container entry point
# ==============================================================================
container_main() {
    [ -f /etc/arch-release ] || die "no /etc/arch-release — this is not the Arch rootfs"
    command -v pacman >/dev/null 2>&1 || die "pacman not found — this is not the Arch rootfs"
    if [ "$DRY" != 1 ] && [ "$(id -u)" != 0 ]; then
        die "must run as root (inside proot-distro you already are)"
    fi

    if [ "$DRY" != 1 ]; then
        LOG_FILE=/var/log/arch-proot-init.log
        mkdir -p /var/log
        exec > >(tee -a "$LOG_FILE") 2>&1
    fi

    msg "proot ArchLinux ARM container initialization starting ..."
    if [ "$FORCE" != 1 ] && [ -s /root/.arch-init-complete ]; then
        msg "already initialized (marker /root/.arch-init-complete exists)"
        msg "re-run with --force to redo the setup"
        exit 0
    fi

    [ "$DRY" = 1 ] && msg "dry-run: nothing will be changed"

    SYNC_OK=0
    REMOVAL_LIST="$(mktemp /tmp/arch-init-list.XXXXXX)"
    REMOVED_COUNT=0

    configure_pacman
    configure_dns_and_misc
    remove_kernel_boot_systemd
    rm -f "$REMOVAL_LIST"

    trim_share_locale
    configure_locale
    configure_sshd
    configure_root_shell
    final_cleanup
    init_keyring
    sync_repositories
    run_upgrade_if_wanted
    write_marker_and_summary "$REMOVED_COUNT"
}

# ==============================================================================
#  main
# ==============================================================================
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
PROG="$(basename "$0")"

main() {
    parse_flags "$@"
    if is_inside_container; then
        container_main
    else
        host_main
    fi
}

main "$@"
