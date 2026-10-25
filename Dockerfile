# syntax=docker/dockerfile:1
# alarm-proot — Arch Linux ARM aarch64 rootfs image for proot-distro.
#
# Stage "bootstrap" (Debian + pacman) assembles /rootfs from the official ALARM
# mirrors; the keyring comes from the official archlinuxarm/PKGBUILDs repo.
# Stage "final" is FROM scratch and contains only the assembled rootfs.
# https://github.com/adix57/alarm-proot

FROM debian:sid AS bootstrap

ARG GIT_SHA=unknown
ARG BUILD_DATE=unknown
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C \
    LC_ALL=C

# --- tooling on the builder (never reaches the final image) ------------------
# makepkg is a SEPARATE binary package in Debian (same source as
# pacman-package-manager) but pacman-key hard-sources its util/*.sh library
# files, so it must be installed explicitly. gnupg is added explicitly too:
# the slim default install only guarantees gpgv (apt's verifier), not a full
# gpg command, and pacman-key needs gpg/gpgconf/dirmngr.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        pacman-package-manager \
        makepkg \
        gnupg \
        curl \
        ca-certificates; \
    rm -rf /var/lib/apt/lists/*

# --- recipe files ------------------------------------------------------------
COPY rootfs.d/ /rootfs.d/
COPY build-rootfs.sh /build-rootfs.sh

# --- ALARM signing keys, from the official archlinuxarm/PKGBUILDs repo -------
# pacman-key's keyring search path differs by build: Debian sid's pacman
# reads /usr/share/keyrings/, while ALARM's keyring package (and older
# pacman builds) install under /usr/share/pacman/keyrings/. Fetch once,
# then make both locations hold identical copies.
RUN set -eux; \
    mkdir -p /usr/share/pacman/keyrings /usr/share/keyrings; \
    for f in archlinuxarm-revoked archlinuxarm-trusted archlinuxarm.gpg; do \
        curl -fsSL --retry 3 \
            "https://raw.githubusercontent.com/archlinuxarm/PKGBUILDs/master/core/archlinuxarm-keyring/${f}" \
            -o "/usr/share/pacman/keyrings/${f}"; \
    done; \
    cp -a /usr/share/pacman/keyrings/archlinuxarm* /usr/share/keyrings/

# --- assemble the rootfs -----------------------------------------------------
RUN bash /build-rootfs.sh

# =============================================================================
# final stage: pure rootfs only
# =============================================================================
FROM scratch

COPY --from=bootstrap /rootfs/ /

LABEL org.opencontainers.image.title="alarm-proot" \
      org.opencontainers.image.description="Arch Linux ARM aarch64 rootfs for proot-distro (Termux/Android): no kernel, no firmware, no systemd; pacman.conf proot-tuned; en_US.UTF-8 pre-generated" \
      org.opencontainers.image.url="https://github.com/adix57/alarm-proot" \
      org.opencontainers.image.source="https://github.com/adix57/alarm-proot" \
      org.opencontainers.image.authors="adix57"
