# alarm-proot

Arch Linux ARM **aarch64** rootfs image, purpose-built for
[proot-distro](https://github.com/termux/proot-distro) on **Termux / Android**.
Built daily from the official Arch Linux ARM mirrors, smoke-tested before it is
ever published.

**One-time install, forever updated by `pacman -Syu`.** GitHub is only the
assembly line — once the container is installed on your phone, nothing in it
ever needs GitHub again.

## Why not the official tarball?

The generic ALARM tarball carries ~1.4 GB that a proot container can never use:
kernel + device trees + initramfs, SoC/Wi-Fi firmware, and systemd. A proot
container has no kernel access, so none of it can ever run — it is only wasted
download, disk churn, and delete-time. This image simply *never* fetches them.

|                            | official tarball        | this image            |
|----------------------------|-------------------------|-----------------------|
| initial download           | 791 MB                  | **~100 MB**           |
| useless bytes fetched      | ~1.4 GB                 | **0**                 |
| final installed size       | ~0.7 GB (after cleanup) | ~0.52 GB              |
| systemd                    | installed, then deleted | **never installed**   |
| freshness                  | tarball snapshot date   | rebuilt daily         |

Measured against the real ALARM sync databases (see the pipeline below):
resolved set of ~116 packages, 96 MiB compressed, 520 MiB installed.

## Install (Termux)

Requires a current proot-distro with OCI image support (it pulls `ghcr.io`
anonymously, no login, no token).

```bash
pkg install proot-distro git
proot-distro install ghcr.io/adix57/alarm-proot:latest --name archlinux

# device-side personalization (DNS, ssh host keys, machine-id, root shell):
curl -O https://raw.githubusercontent.com/adix57/alarm-proot/main/init.sh
bash init.sh

# enter it:
proot-distro login archlinux
```

Pin a build for reproducibility with a date tag instead:
`ghcr.io/adix57/alarm-proot:20261024` — every tag also matches a commit in
this repo (see `/etc/alarm-proot-build` inside the image).

**First publish only:** the package starts as private. Make it public once
(GitHub → this repo → *Packages* → alarm-proot → *Package settings* → *Change
visibility* → Public) so anonymous pulls work.

## What is inside

- ALARM's **`base` userland**, resolved by pacman itself from the `base`
  meta-package (ALARM's sync DBs carry no group data — the meta-package's
  dependency list is the definition), then filtered through `rootfs.d/drop.txt`
  — no systemd/systemd-sysvcompat/systemd-resolvconf (`systemd-libs` stays:
  half the ecosystem links it), no `mkinitcpio*`, no kernels, no
  `linux-firmware*`, no cryptsetup/iptables/nftables/dhcpcd/netctl/gpm
- honesty note: ALARM's `pacman` package itself hard-depends `systemd`; that
  one dependency is virtualized at build time (`--assume-installed`) and the
  local pacman DB is patched to match — the `update()` alias installed by
  `init.sh` keeps future full upgrades consistent
- `/etc/pacman.conf` rewritten for proot at build time: `CheckSpace` and
  `DownloadUser` off (both degrade to failure modes in rootless proot),
  `ParallelDownloads = 8`, single geo-routing mirror
- `en_US.UTF-8` locale generated at build; non-English message catalogs
  stripped
- `/etc/alarm-proot-build` — provenance: build date, commit, package count and
  package-list hash
- keyring pre-populated (`archlinuxarm`), **no private keys baked**

Deliberately **not** baked in (per-device, regenerated at runtime by
`init.sh`): DNS/resolv.conf, ssh host keys, machine-id.

## Customizing your image (no Docker knowledge needed)

Two plain text files control the build:

- `rootfs.d/drop.txt` — *exclusions*. One POSIX regex (grep -E) per line,
  matched against package names.
- `rootfs.d/add.txt` — *extras* baked on top, one package name per line, e.g.
  `openssh`, `curl`, `vim`.

Edit → commit → push, or trigger manually: GitHub → this repo → **Actions** →
*build* → *Run workflow*. About 15–40 minutes later the new image is in GHCR;
your already-installed container keeps working unaffected (updating it is
`pacman -Syu`, straight from ALARM mirrors).

## The pipeline

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

A daily build that fails anything is **never published** — you get the failure
email instead, and the registry keeps yesterday's known-good image.

## Privacy

This repo is a *recipe*, published for convenience: a Dockerfile, a workflow,
and two text lists. Your phone, your container, and everything inside it stay
on your phone — there is no upload path anywhere in this flow. The image
itself contains only stock ALARM packages, the same ones `pacman` serves
anyone.

## Repo layout

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

- **`proot-distro install` can't pull** → package visibility still private
  (see above), or old proot-distro without OCI support (`pkg upgrade proot-distro`).
- **`pacman -Syu` fails inside** → usually DNS: re-run `bash init.sh` (it
  repairs resolv.conf from the Termux side), or check your connection.
- **Daily build failed** → check the Actions tab; the previous `latest` is
  untouched and still installable.
