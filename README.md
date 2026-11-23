# Shattered Vales OS Installer

Builds USB installers for both editions of Shattered Vales OS:

| Edition | Image | Install |
|---|---|---|
| **Studio** | [`shatteredvales-os`](https://github.com/Shattered-Vales-Studio/OS-Linux-FedoraSB-ShatteredValesOS) | Unattended: erases the largest internal disk, names the machine from its serial number, creates your IT administrator account. No questions asked. |
| **Home** | [`shatteredvales-os-home`](https://github.com/Shattered-Vales-Studio/OS-Linux-FedoraSB-ShatteredValesOS_HomeEdition) | Guided: the installer asks for language, Wi-Fi and which disk to use. No accounts are made here; on first boot the computer walks the family through creating theirs. |

Both pick the NVIDIA or standard image from the computer's graphics card,
download the newest image during the install, and switch to the
signature-verified image so every later update is checked.

Nothing personal lives in this repository. The Studio administrator account
comes from a local `installer.env` that git ignores, and no Tailscale or other
network keys are ever added: whoever sets up a machine signs in to their own
accounts afterwards.

## Build a USB stick

You need Docker (OrbStack works on a Mac) or Podman, about 3 GB of free space
and a USB stick of 4 GB or more.

1. Download Fedora's network installer, **Fedora Everything netinst x86_64**,
   for the same Fedora release as the images (currently 45) from
   <https://fedoraproject.org/misc/#everything>, and check it against the
   CHECKSUM file next to it.
2. **Studio only:** `cp installer.env.example installer.env` and fill it in.
   Make the password hash with `openssl passwd -6` on Linux; macOS's own
   `openssl` lacks `-6`, so on a Mac use
   `docker run --rm -it fedora openssl passwd -6`.
3. Build:
   ```bash
   ./build-iso.sh --edition home   ~/Downloads/Fedora-Everything-netinst-x86_64-45-1.4.iso
   ./build-iso.sh --edition studio ~/Downloads/Fedora-Everything-netinst-x86_64-45-1.4.iso
   ```
   Add `--channel testing` for a canary machine. The ISO and its `.sha256`
   land in `build/`.
4. Write it with [balenaEtcher](https://etcher.balena.io): **Flash from file**
   (pick the ISO in `build/`), **Select target** (the USB stick), **Flash!**
   Fedora Media Writer and `dd` work too.

## Install

1. Plug the computer into **wired network** if you can; the image (about
   5 GB) downloads during the install. Home installs can also use Wi-Fi,
   chosen on the installer's network screen.
2. Boot from the USB stick (usually F12, F11, F7 or Esc at power-on picks the
   boot device; on many mini PCs it is F7).
3. **Studio:** walk away; it erases the disk, installs and restarts on its own.
   **Home:** choose language, network and the disk, press *Begin
   Installation*, and restart when it says so.
4. On first boot the computer finishes setting itself up in the background
   (apps download for a while). Home Edition starts by creating the family's
   accounts.

**Studio sticks erase the internal disk without asking.** Label them, and
keep them away from machines you do not mean to reinstall.

## Moving an existing Fedora Silverblue machine instead

No USB stick needed; see `sv-migrate.sh` in each edition's README.

## Checks

`./build-iso.sh --edition studio|home --check` renders the kickstart and runs
Fedora's `ksvalidator` without building an ISO; CI runs it for both editions
on every pull request.

## How it works

`build-iso.sh` renders `kickstart/<edition>.ks.in` and embeds it in Fedora's
netinst ISO with `mkksiso`, removing the media check so the default boot entry
installs straight away. The kickstart's `%pre` script picks the image from the
graphics card (and, for Studio, the disk and host name), installs it with
`ostreecontainer`, and `%post` switches it to the signed image with
`bootc switch --enforce-container-sigpolicy`.

An offline variant that embeds the image in the ISO (no network needed during
the install) is being evaluated with Fedora's `image-builder`; until it is
proven on real hardware, the network installer above is the supported way.
