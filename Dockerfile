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
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        pacman-package-manager \
        curl \
        ca-certificates; \
    rm -rf /var/lib/apt/lists/*

# --- recipe files ------------------------------------------------------------
COPY rootfs.d/ /rootfs.d/
COPY build-rootfs.sh /build-rootfs.sh

# --- ALARM signing keys, from the official archlinuxarm/PKGBUILDs repo -------
RUN set -eux; \
    mkdir -p /usr/share/pacman/keyrings; \
    for f in archlinuxarm-revoked archlinuxarm-trusted archlinuxarm.gpg; do \
        curl -fsSL --retry 3 \
            "https://raw.githubusercontent.com/archlinuxarm/PKGBUILDs/master/core/archlinuxarm-keyring/${f}" \
            -o "/usr/share/pacman/keyrings/${f}"; \
    done

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
