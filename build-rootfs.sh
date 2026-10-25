#!/usr/bin/env bash
# build-rootfs.sh — assemble the alarm-proot aarch64 rootfs.
#
# Runs as root inside the builder container (Debian + pacman); /rootfs becomes
# the image's only content (final stage: FROM scratch).
#
# Steps: keyring init/populate -> pacman -Sy -> resolve ALARM `base`
# metapackage (rule out drop.txt, add add.txt) -> install via pacman --root
# -> bake pacman.conf/keyring -> locale -> identity placeholders -> clean.
# Verified content is written to /etc/alarm-proot-build.
#
# Note: ALARM sync DBs carry no group data, so the `base` meta-package's
# dependency closure is used instead of a group callback. ALARM's pacman
# hard-depends systemd; the install virtualizes that with --assume-installed.
# =============================================================================
set -Eeuo pipefail

ROOTFS=/rootfs
SRC=/rootfs.d
: "${GIT_SHA:=unknown}"
: "${BUILD_DATE:=unknown}"
: "${IMAGE_REF:=ghcr.io/adix57/alarm-proot}"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '     %s\n' "$*"; }
die()  { printf '\033[1;31m[error] %s\033[0m\n' "$*" >&2; exit 1; }

# -------------------------------------------------------------------- 0 sane
log "0/10 sanity checks ..."
[ "$(id -u)" = 0 ]        || die "must run as root inside the builder"
[ -x /usr/bin/pacman ]    || die "pacman missing in builder"
[ -f "$SRC/pacman.conf" ] || die "missing $SRC/pacman.conf"
# pacman-key sources makepkg's util/*.sh libraries; without the Debian
# 'makepkg' binary package installed they are absent and it dies instantly
for sh in /usr/share/makepkg/util/message.sh /usr/share/makepkg/util/parseopts.sh; do
    [ -f "$sh" ] || die "missing $sh — install the 'makepkg' package in the builder"
done
# QEMU proof of life: under BuildKit, RUN containers get a fresh /proc mount
# that often cannot see /proc/sys/fs/binfmt_misc, so probing that path
# false-negatives in CI even when emulation works. The builder itself already
# runs aarch64 binaries (this very script, bash, curl...), and qemu-user fakes
# `uname -m` to the target arch; a native arm64 runner reports it natively —
# so uname holds as the reliable signal in both cases.
ARCH_FMT="$(uname -m 2>/dev/null || echo unknown)"
[ "$ARCH_FMT" = aarch64 ] \
    || die "builder userland is '$ARCH_FMT', not aarch64 — arm64 emulation (qemu binfmt) or a native arm64 runner is missing"
if [ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
    info "qemu-aarch64 binfmt visible"
else
    info "binfmt_misc not visible from this RUN container (normal under BuildKit) — aarch64 userland confirmed via uname"
fi

# the same tuned config serves the builder AND the image
cp "$SRC/pacman.conf" /etc/pacman.conf
info "pacman.conf installed (tuned for proot)"

# --------------------------------------------------------- 1 builder keyring
log "1/10 builder keyring ..."
if [ ! -s /etc/pacman.d/gnupg/trustdb.gpg ]; then
    pacman-key --init \
        || die "pacman-key --init failed — read the gpg error lines printed just above"
fi
pacman-key --populate archlinuxarm \
    || die "pacman-key --populate archlinuxarm failed — read the gpg error lines printed just above"
info "builder trusts archlinuxarm keys"

# ------------------------------------------------------- 2 builder repo sync
log "2/10 syncing ALARM repositories on the builder ..."
# fail fast with a precise reason if the mirror is unreachable from this runner
curl -fsS --retry 3 --max-time 60 -o /dev/null \
    'http://mirror.archlinuxarm.org/aarch64/core/core.db' \
    || die "cannot fetch aarch64 core.db from mirror.archlinuxarm.org (network/DNS/mirror outage) — see curl error above"
pacman --noconfirm -Sy \
    || die "pacman -Sy failed — read the pacman error lines printed just above"
info "repos synced"

# ------------------------------------------------------- 3 resolve packages
log "3/10 resolving the package list ..."
# pacman resolves the transaction itself; -Sp prints it without installing.
LIST=/tmp/alarm-proot.packages
if ! pacman -Sp --print-format %n --noconfirm base 2>/tmp/alarm-sp.err >"$LIST"; then
    cat /tmp/alarm-sp.err >&2
    die "could not resolve the base set — builder mirror/keyring problem"
fi
info "resolved transaction: $(wc -l < "$LIST") packages"

mapfile -t DROP < <(grep -vE '^[[:space:]]*(#|$)' "$SRC/drop.txt" || true)
mapfile -t ADD < <(grep -vE '^[[:space:]]*(#|$)' "$SRC/add.txt" 2>/dev/null |
                   sed 's/[[:space:]]//g' | grep -v '^$' || true)

if [ "${#DROP[@]}" -gt 0 ]; then
    printf '%s\n' "${DROP[@]}" | sort -u > /tmp/alarm-proot.drop
    grep -vEf /tmp/alarm-proot.drop "$LIST" > "$LIST.new" || true
    mv "$LIST.new" "$LIST"
    info "drop.txt filtered out via ${#DROP[@]} patterns"
fi
if [ "${#ADD[@]}" -gt 0 ]; then
    printf '%s\n' "${ADD[@]}" >> "$LIST"
    info "add.txt contributed ${#ADD[@]} packages"
fi
sort -u "$LIST" -o "$LIST"

mapfile -t PKGS < "$LIST"
N=${#PKGS[@]}
[ "$N" -ge 90 ] || die "only $N packages resolved — refusing to build (drop.txt too aggressive?)"
if printf '%s\n' "${PKGS[@]}" | grep -qx 'systemd'; then
    die "systemd still in the resolved list — drop.txt is broken"
fi
info "final list: $N packages"

# ---------------------------------------------------------------- 4 install
log "4/10 installing $N packages into $ROOTFS via pacman --root (emulated arm64) ..."
rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"/{etc,dev,proc,sys,run,tmp,var/lib/pacman}
chmod 1777 "$ROOTFS/tmp"
# install hooks (e.g. glibc's ldconfig) run via chroot into $ROOTFS; seed
# /dev with basic nodes so they succeed (Docker grants MKNOD)
for spec in "null 1 3 666" "zero 1 5 666" "full 1 7 666" "random 1 8 666" "urandom 1 9 666"; do
    set -- $spec
    mknod -m "$4" "$ROOTFS/dev/$1" c "$2" "$3" 2>/dev/null ||
        info "mknod for $1 skipped (cap missing — usually harmless)"
done
# Direct pacman instead of pacstrap: pacstrap would silently re-pull systemd
# (ALARM pacman hard-depends it) while --assume-installed keeps it virtualized;
# the builder keyring does all signature verification.
CACHE=$(mktemp -d)
pacman \
    --config   /etc/pacman.conf \
    --root     "$ROOTFS" \
    --gpgdir   /etc/pacman.d/gnupg \
    --cachedir "$CACHE" \
    -Sy --needed \
    --assume-installed systemd \
    --assume-installed systemd-sysvcompat \
    --noconfirm "${PKGS[@]}" \
    || die "package transaction failed — read the pacman error lines printed just above"
rm -rf "$CACHE"

# pacman's local DB entry claims systemd, which is virtualized; drop the line
# so local dependency checks stay truthful (see the `update` alias in init.sh)
for d in "$ROOTFS"/var/lib/pacman/local/pacman-*/depends; do
    if [ -f "$d" ]; then
        sed -i -E '/^systemd([[:space:]]|$)/d' "$d"
        info "local DB patched: pacman no longer references systemd"
    fi
done
info "install finished"

# -------------------------------------------------- 5 overlay the final conf
log "5/10 baking the proot-tuned pacman.conf into the image ..."
cp "$SRC/pacman.conf" "$ROOTFS/etc/pacman.conf"

# ---------------------------------------------------------- 6 target keyring
log "6/10 installing the target keyring (no private keys baked) ..."
# archlinuxarm-keyring files, in case they were not part of the filtered list
mkdir -p "$ROOTFS/usr/share/pacman/keyrings"
for f in archlinuxarm-revoked archlinuxarm-trusted archlinuxarm.gpg; do
    cp -a "/usr/share/pacman/keyrings/$f" "$ROOTFS/usr/share/pacman/keyrings/$f"
done
# pacman>=7.1 reads /usr/share/keyrings; older builds and ALARM's keyring
# package use /usr/share/pacman/keyrings — bake both so any pacman build works
mkdir -p "$ROOTFS/usr/share/keyrings"
cp -a "$ROOTFS/usr/share/pacman/keyrings"/archlinuxarm* "$ROOTFS/usr/share/keyrings/"

# Initialize and populate the gnupg home INSIDE the target with the target's
# own gpg, instead of copying the builder's home over — cross-version gnupg
# state (trustdb/keybox bytecode) has bitten populate runs in the image.
# Afterwards drop all private material: the image must bake public keys and
# the trust db only; devices re-derive the synthetic local master on demand.
rm -rf "$ROOTFS/etc/pacman.d/gnupg"
mkdir -p "$ROOTFS/etc/pacman.d"
chroot "$ROOTFS" pacman-key --init \
    || die "target pacman-key --init failed — see the gpg output above"
chroot "$ROOTFS" pacman-key --populate archlinuxarm \
    || die "target pacman-key --populate failed — see the gpg output above"
GPG_ROOT="$ROOTFS/etc/pacman.d/gnupg"
find "$GPG_ROOT" -maxdepth 1 \( -name '*.lock' -o -name 'S.*' \) -delete 2>/dev/null || true
rm -rf "$GPG_ROOT/private-keys-v1.d" "$GPG_ROOT/openpgp-revocs.d"
chmod 700 "$GPG_ROOT"
[ -s "$GPG_ROOT/trustdb.gpg" ] || die "target keyring missing trustdb"
info "target keyring ready (public keys + trust db only, no private material)"

# ---------------------------------------------------------------- 7 language
log "7/10 generating the en_US.UTF-8 locale ..."
sed -i 's/^#en_US\.UTF-8[[:space:]]*UTF-8.*/en_US.UTF-8 UTF-8/' "$ROOTFS/etc/locale.gen"
chroot "$ROOTFS" locale-gen
printf 'LANG=en_US.UTF-8\n' > "$ROOTFS/etc/locale.conf"
chroot "$ROOTFS" locale -a 2>/dev/null | grep -qi '^en_US\.utf8$' \
    || die "en_US.UTF-8 missing after locale-gen"

# message catalogs: keep en*/C only — same rule init.sh enforces on-device
LOCALE_DIR="$ROOTFS/usr/share/locale"
if [ -d "$LOCALE_DIR" ]; then
    LSIZE=$(du -sk "$LOCALE_DIR" | cut -f1)
    LSIZE=${LSIZE:-0}
    T=0
    for d in "$LOCALE_DIR"/*; do
        case "${d##*/}" in
            en|en_*|C|C.*) continue ;;
            *) rm -rf "$d"; T=$((T + 1)) ;;
        esac
    done
    ASIZE=$(du -sk "$LOCALE_DIR" | cut -f1)
    info "trimmed $T message catalogs: $((LSIZE / 1024)) MiB -> $((ASIZE / 1024)) MiB"
fi

# --------------------------------------------------------------- 8 identity
log "8/10 identity files ..."
cat > "$ROOTFS/etc/resolv.conf" <<'EOF'
# fallback resolv.conf — init.sh (on-device) writes a proper one
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF
printf 'alarm-proot\n' > "$ROOTFS/etc/hostname"
: > "$ROOTFS/etc/machine-id"   # MUST be empty: per-device value, init.sh writes it

# ---------------------------------------------------------------- 9 cleaning
log "9/10 caches and logs ..."
rm -rf "$ROOTFS/var/cache/pacman/pkg"/* || true
find "$ROOTFS/var/log" -type f -size +0 -exec truncate -s 0 {} + 2>/dev/null || true
rm -rf "$ROOTFS/var/log/journal"

# ---------------------------------------------------------- 10 self-checks
log "10/10 self-checks ..."
if chroot "$ROOTFS" pacman -Q systemd >/dev/null 2>&1; then die "systemd present in rootfs"; fi
[ -x "$ROOTFS/usr/bin/pacman" ] || die "no pacman in rootfs"
[ -x "$ROOTFS/usr/bin/bash" ]   || die "no bash in rootfs"
if [ -d "$ROOTFS/boot" ] && [ -n "$(ls -A "$ROOTFS/boot" 2>/dev/null)" ]; then
    die "/boot is not empty — a kernel slipped in"
fi
if [ -d "$ROOTFS/usr/lib/firmware" ] && [ -n "$(ls -A "$ROOTFS/usr/lib/firmware" 2>/dev/null)" ]; then
    die "/usr/lib/firmware is not empty — firmware slipped in"
fi
info "all self-checks passed"

# ------------------------------------------------------------- provenance ---
LIST_SHA=$(sha256sum "$LIST" | cut -d' ' -f1)
cat > "$ROOTFS/etc/alarm-proot-build" <<EOF
image      = $IMAGE_REF
built      = $BUILD_DATE (UTC)
commit     = $GIT_SHA
packages   = $N
list-sha   = $LIST_SHA
mirror     = http://mirror.archlinuxarm.org/\$arch/\$repo
recipe     = ALARM base metapkg closure - drop.txt + add.txt (https://github.com/adix57/alarm-proot)
per-device = machine-id, ssh host keys and DNS are generated at runtime by init.sh
EOF
chmod 644 "$ROOTFS/etc/alarm-proot-build"

# ---------------------------------------------------------------- summary ---
SIZE=$(du -sh "$ROOTFS" | cut -f1)
HLINKS=$(find "$ROOTFS" -type f -links +1 2>/dev/null | wc -l || echo 0)
log "rootfs assembled: $SIZE total, $N packages, $HLINKS hardlinked files"
if [ "$HLINKS" -gt 200 ]; then
    info "note: many hardlinks — plain COPY into scratch may bloat; inspect image size in CI"
fi
info "builder stage done — final FROM scratch stage takes over"
