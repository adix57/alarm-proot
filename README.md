# alarm-proot

Arch Linux ARM **aarch64** rootfs image, purpose-built for
[proot-distro](https://github.com/termux/proot-distro) on **Termux / Android**.
Built daily from the official Arch Linux ARM mirrors and smoke-tested before
every publish.

**Install once, update forever with `pacman -Syu`.** GitHub is only the
assembly line: once the container is installed on your device, nothing inside
it ever needs GitHub again.

## Why not the official tarball?

The generic ALARM tarball ships roughly **1.4 GB** that a proot container can
never use — kernel, device trees, initramfs, SoC/Wi-Fi firmware, and systemd.
A proot container has no kernel access, so none of it can ever run; it is pure
wasted download, disk churn, and delete time. This image simply never fetches
any of it.

|                          | Official tarball        | This image          |
| ------------------------ | ----------------------- | ------------------- |
| Initial download         | 791 MB                  | **~100 MB**         |
| Unusable bytes fetched   | ~1.4 GB                 | **0**               |
| Final installed size     | ~0.7 GB (after cleanup) | ~0.52 GB            |
| systemd                  | Installed, then deleted | **Never installed** |
| Freshness                | Tarball snapshot date   | Rebuilt daily       |

Measured against the live ALARM sync databases (see [Build pipeline](#build-pipeline)):
a resolved set of ~116 packages, 96 MiB compressed, 520 MiB installed.

## Installation

Requires a current proot-distro with OCI image support. It pulls from
`ghcr.io` anonymously — no login, no token.

```bash
pkg install proot-distro git

# pull and unpack the image
proot-distro install ghcr.io/adix57/alarm-proot:latest --name archlinux

# device-side personalization (DNS, SSH host keys, machine-id, root shell)
curl -O https://raw.githubusercontent.com/adix57/alarm-proot/main/init.sh
bash init.sh

# enter the container
proot-distro login archlinux
```

To pin a build for reproducibility, use a date tag instead:
`ghcr.io/adix57/alarm-proot:20261024`. Every tag also matches a commit in this
repo (see `/etc/alarm-proot-build` inside the image).

### First publish only

The package starts out private. Make it public once so anonymous pulls work:
GitHub → this repo → *Packages* → alarm-proot → *Package settings* → *Change
visibility* → Public.

## What is inside

- ALARM's **`base` userland**, resolved by pacman itself from the `base`
  meta-package (ALARM's sync DBs carry no group data, so the meta-package's
  dependency list is the definition), then filtered through
  `rootfs.d/drop.txt`:
  - no `systemd` / `systemd-sysvcompat` / `systemd-resolvconf`
    (`systemd-libs` stays — half the ecosystem links it)
  - no `mkinitcpio*`
  - no kernels
  - no `linux-firmware*`
  - no `cryptsetup` / `iptables` / `nftables` / `dhcpcd` / `netctl` / `gpm`
- `/etc/pacman.conf` rewritten for proot at build time: `CheckSpace` and
  `DownloadUser` disabled (both degrade to failure modes in rootless proot),
  `ParallelDownloads = 8`, and a single geo-routing mirror
- `en_US.UTF-8` locale generated at build; non-English message catalogs
  stripped
- `/etc/alarm-proot-build` — provenance file: build date, commit, package
  count, and package-list hash
- `archlinuxarm` keyring pre-populated; **no private keys baked in**

> **Note on pacman's systemd dependency:** ALARM's `pacman` package itself
> hard-depends on `systemd`. That single dependency is virtualized at build
> time (`--assume-installed`) and the local pacman database is patched to
> match. The `update` alias installed by `init.sh` keeps future full upgrades
> consistent.

Deliberately **not** baked in — these are per-device and regenerated at
runtime by `init.sh`: DNS (`resolv.conf`), SSH host keys, and `machine-id`.

## Customization

Two plain text files control the build — no Docker knowledge required:

| File                  | Purpose                            | Format                                  |
| --------------------- | ---------------------------------- | --------------------------------------- |
| `rootfs.d/drop.txt`   | Package exclusions                 | One POSIX regex (`grep -E`) per line, matched against package names |
| `rootfs.d/add.txt`    | Extra packages baked on top        | One package name per line, e.g. `openssh`, `curl`, `vim` |

To apply changes: edit → commit → push, or trigger manually via GitHub → this
repo → **Actions** → *build* → *Run workflow*. The new image reaches GHCR in
about 15–40 minutes. An already-installed container keeps working unaffected;
to update it, run `update` (the alias installed by `init.sh`, which keeps
systemd virtualized) — packages come straight from the ALARM mirrors.

## Build pipeline

```
cron / manual / push
 └─ build arm64 rootfs on amd64 runner (QEMU)
     ├─ Debian builder + pacman (official ALARM mirrors + keyring)
     ├─ resolved transaction: pacman -Sp base − drop.txt + add.txt
     └─ hard asserts: no systemd, no kernel, no firmware, sane package count
 └─ smoke test inside the built arm64 image:
     pacman -Q sanity · no systemd · no /boot · no firmware ·
     locale present · pacman.conf proot-tuned · machine-id empty ·
     keyring populate · live pacman -Sy
 └─ green → push ghcr.io/adix57/alarm-proot:{latest,YYYYMMDD,gitsha}
```

A daily build that fails any check is **never published**. You receive the
failure notification instead, and the registry keeps the previous
known-good image.

## Privacy

This repo is a *recipe*, published for convenience: a Dockerfile, a workflow,
and two text lists. Your device, your container, and everything inside them
stay on your device — there is no upload path anywhere in this flow. The image
itself contains only stock ALARM packages, the same ones `pacman` serves to
anyone.

## Repository layout

```
├── Dockerfile                    # bootstrap stage → FROM scratch final
├── build-rootfs.sh               # rootfs assembler (runs in the builder)
├── rootfs.d/
│   ├── pacman.conf               # proot-tuned config (builder + image)
│   ├── drop.txt                  # excluded packages (your edit point)
│   └── add.txt                   # extra packages (your edit point)
├── tests/smoke.sh                # pre-publish assertions (run in CI)
├── .github/workflows/build.yml   # cron + manual builds, smoke gate, GHCR push
└── init.sh                       # device-side first-run setup (Termux side)
```

## Troubleshooting

- **`proot-distro install` cannot pull** — the package is still private (see
  [First publish only](#first-publish-only)), or the installed proot-distro
  lacks OCI support (`pkg upgrade proot-distro`).
- **`pacman -Syu` fails inside the container** — usually DNS: re-run
  `bash init.sh` (it repairs `resolv.conf` from the Termux side), or check
  your connection.
- **Daily build failed** — check the Actions tab. The previous `latest` tag is
  untouched and remains installable.
