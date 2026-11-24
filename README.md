# Shattered Vales OS Installer

Builds USB installers for both editions of Shattered Vales OS:

| Edition | Image | For |
|---|---|---|
| **Studio** | [`shatteredvales-os`](https://github.com/Shattered-Vales-Studio/OS-Linux-FedoraSB-ShatteredValesOS) | Developer workstations |
| **Home** | [`shatteredvales-os-home`](https://github.com/Shattered-Vales-Studio/OS-Linux-FedoraSB-ShatteredValesOS_HomeEdition) | Family computers |

Both install the same guided way with Fedora's installer (Anaconda): it asks
for the language, the network and the computer's name, which disk to use,
and the first account, which becomes the administrator. If that account
screen is skipped, the first boot asks instead (Home Edition then continues
into Family Setup). Each installer picks the NVIDIA or standard image and
switches the installed system to the signature-verified image, so every
later update is checked.

Nothing in this repository or on a built stick is tied to a particular
studio, office or person: no accounts, passwords, keys or naming rules.
Anyone can build these sticks and hand them on; whoever installs a machine
sets those things up on the installer's screens.

**Network or offline?**

| | Network ISO (~1.3 GB) | Offline ISO (~6 GB) |
|---|---|---|
| Installs | The newest image, downloaded during the install | The image built into the ISO on the day it was built |
| Graphics | Picks NVIDIA or standard by itself | One ISO per graphics type (`--variant`) |
| Needs | Internet during the install | Nothing; updates download afterwards |
| Builds on | macOS or Linux, with Docker or Podman | Linux as root, with Podman |

## Build a USB stick

You need a USB stick of 4 GB (network) or 8 GB (offline) or more.

**Everything at once** (Linux; about 60 GB free): one command builds all
six ISOs (network for Studio and Home, offline for each edition in base and
NVIDIA), and publishes them to the team drive when the machine is connected
to it (see below; without that, the ISOs simply stay in `build/`). Run it as
your normal account; it asks for your sudo password once, downloads and
checks Fedora's netinst ISO itself, and builds the two editions side by
side:

```bash
./build-all.sh                 # build all six and publish
./build-all.sh --no-publish    # build only
./build-all.sh --channel testing
```

Each ISO has its own log in `build/`. A build that fails is listed at the
end and is not published; the others still are.

To build a single ISO instead:

**Network ISO** (Docker or Podman, macOS or Linux):

1. Download Fedora's network installer, **Fedora Everything netinst x86_64**,
   for the same Fedora release as the images (currently 45) from
   <https://fedoraproject.org/misc/#everything>, and check it against the
   CHECKSUM file next to it.
2. Build:
   ```bash
   ./build-iso.sh --edition studio ~/Downloads/Fedora-Everything-netinst-x86_64-45-1.4.iso
   ./build-iso.sh --edition home   ~/Downloads/Fedora-Everything-netinst-x86_64-45-1.4.iso
   ```

**Offline ISO** (Linux, root, Podman; about 25 GB free):

```bash
sudo ./build-iso.sh --edition home   --offline --variant base
sudo ./build-iso.sh --edition studio --offline --variant nvidia
```

`--variant base` is for AMD and Intel graphics, `--variant nvidia` for NVIDIA
cards. Add `--channel testing` to either kind for a canary machine. The ISO
and its `.sha256` land in `build/`.

**Write the stick** with [balenaEtcher](https://etcher.balena.io): **Flash
from file** (the ISO in `build/`), **Select target** (the USB stick),
**Flash!** Fedora Media Writer and `dd` work too.

## Publishing to the team drive

`publish-iso.sh` uploads ISOs to the internal Shared Drive, one file per
Fedora release, edition and variant (a newer build of the same one replaces
it):

```
OS/Studio/ShatteredValesOS-Studio-NVIDIA-F45-Offline.iso   (+ .sha256)
OS/Studio/ShatteredValesOS-Studio-F45-Network.iso
OS/Home/ShatteredValesOS-Home-Base-F45-Offline.iso
```

It runs rclone from its container image, as your normal account (not sudo):

```bash
./publish-iso.sh --setup "Team Drive Name"   # once per machine: one Google sign-in
./publish-iso.sh              # upload every ISO in build/
./publish-iso.sh --dry-run    # show what would be uploaded
```

Setup is one Google sign-in in the browser, like Google Drive for desktop:
the script uses rclone's built-in Google app, so there is no Google Cloud
project, client ID or token to create. The sign-in is stored in
`~/.config/rclone` on that machine only.

## Install

1. Boot from the USB stick (usually F12, F11, F7 or Esc at power-on picks the
   boot device; on many mini PCs it is F7).
2. In the installer, choose the language and keyboard, connect to the
   network (and set the computer's name there if you like), pick the disk,
   and create the first account with **Make this user administrator**
   ticked. A network ISO needs internet here; an offline ISO does not.
3. Press **Begin Installation**; the computer restarts when it is done.
4. On first boot the computer finishes setting itself up in the background
   (apps download for a while once it is online).

### Machines installed from an older offline ISO

Offline ISOs built before the SELinux fix (November 2026) installed systems
with SELinux switched off (`selinux=0` on the kernel command line), and the
files the install wrote, such as the first account's home folder, have no
SELinux labels. Network ISOs are not affected. To check a machine, run
`getenforce`: `Disabled` means it needs this repair. In a terminal, as an
administrator:

```bash
sudo rpm-ostree kargs --delete=selinux=0 --append=enforcing=0
systemctl reboot
# after the restart (SELinux on, but only reporting):
sudo restorecon -RF /etc /var
sudo rpm-ostree kargs --delete=enforcing=0
systemctl reboot
```

After the second restart `getenforce` says `Enforcing`. The relabel takes
seconds; a "Could not open … No such file" line for a file that vanished
while it ran is harmless.

## Moving an existing Fedora Silverblue machine instead

No USB stick needed; see `sv-migrate.sh` in each edition's README.

## Checks

`./build-iso.sh --edition studio|home --check` renders the kickstart and runs
Fedora's `ksvalidator` without building an ISO; CI runs it for both editions
on every pull request.

## Keeping up with Fedora

- **Network ISOs** always install the newest image, so they only need
  rebuilding for a new Fedora release.
- **Offline ISOs** hold the image from the day they were built; installed
  machines download everything newer right after first boot. Rebuild them
  whenever you hand out new sticks.
- **New Fedora releases:** the *fedora-release* workflow checks every
  Monday. When Fedora N+1 is out and its tool and bootc images are
  published, it pushes a `fedora-<N+1>` branch with the version bumps and
  opens an issue with the pull request link and a test checklist.
- **GitHub Actions** are kept current by Dependabot.

## How it works

`build-iso.sh` renders `kickstart/installer.ks.in` (the edition only sets
the image name) and validates it with Fedora's `ksvalidator`. The
kickstart's `%pre` script picks the image from the graphics card and
installs it with `ostreecontainer` (network) or `bootc --source-imgref
containers-storage:` (offline), and `%post` switches it to the signed image
with `bootc switch --enforce-container-sigpolicy`. Disk, network and accounts
are left to the installer's screens.

- **Network ISO:** the kickstart is embedded in Fedora's netinst ISO with
  `mkksiso`, and the media check is removed so the installer starts
  straight away.
- **Offline ISO:** `offline/Containerfile` builds a Fedora 45 Anaconda
  environment holding the kickstart, and Fedora's `image-builder`
  (`generic-iso`) turns it into an ISO with the OS image embedded in its
  container storage.
