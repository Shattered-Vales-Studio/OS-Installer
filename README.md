# Shattered Vales OS Installer

Builds USB installers for every edition of Shattered Vales OS:

| Edition | Image | For |
|---|---|---|
| **Core** | [`shatteredvales-os-core`](https://github.com/Shattered-Vales-Studio/OS-Linux-FedoraSB-ShatteredValesOS_CoreEdition) | The plain Shattered Vales desktop every edition builds on |
| **Studio** | [`shatteredvales-os`](https://github.com/Shattered-Vales-Studio/OS-Linux-FedoraSB-ShatteredValesOS) | Developer workstations |
| **Home** | [`shatteredvales-os-home`](https://github.com/Shattered-Vales-Studio/OS-Linux-FedoraSB-ShatteredValesOS_HomeEdition) | Family computers |

**Just want a USB stick?** Download a network installer from the
[latest release](https://github.com/Shattered-Vales-Studio/OS-Installer/releases/latest)
and write it with balenaEtcher (see [Write the stick](#write-the-stick)).

Every edition installs the same guided way with Fedora's installer (Anaconda): it asks
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

## Released network installers

Network ISOs for every edition are published as
[GitHub releases](https://github.com/Shattered-Vales-Studio/OS-Installer/releases)
with their `.sha256` files. They always install the newest signed image, so
a release only needs replacing when the installer changes or Fedora moves to
a new release. To publish one: **Actions** > **release-network-isos** >
**Run workflow** (pick the channel, optionally add a note; tick *draft* to
try the workflow without publishing). It downloads and checks Fedora's
netinst ISO, builds the Core, Studio and Home network ISOs and creates a
release tagged `f<release>-<date>`, marked Latest.

## Build USB installers yourself

Offline ISOs are not released (each is several GB, over GitHub's 2 GiB
limit); whoever needs one builds it with `build-all.sh`. Nothing is uploaded
anywhere: finished ISOs and their checksums land in a folder you can open,
`~/ShatteredValesOS-ISOs/` by default, named like
`ShatteredValesOS-Home-Base-F45-Offline.iso` or
`ShatteredValesOS-Core-F45-Network.iso`. A newer build replaces the older
file of the same name.

You need a USB stick of 4 GB (network) or 8 GB (offline) or more.

**One command** (Linux; Docker or Podman; offline ISOs need about 25 GB free
each while building): run it as your normal account; it asks for your sudo
password once, downloads and checks Fedora's netinst ISO itself
(`fetch-netinst.sh`), and builds two ISOs at a time:

```bash
./build-all.sh                                             # everything: 3 network + 6 offline
./build-all.sh --network-only                              # the three network ISOs
./build-all.sh --edition home --offline-only --variant base   # just the one you need
./build-all.sh --edition studio --edition core --offline-only
./build-all.sh --channel testing --out /path/to/folder
```

`--variant base` is for AMD and Intel graphics, `--variant nvidia` for NVIDIA
cards; `--edition` and `--variant` can be repeated. Each ISO has its own log
in `build/`. A build that fails is listed at the end and its ISO is not moved
to the folder; the others still are. Ctrl+C stops every build it started.
`./build-all.sh --help` lists every option.

**A single ISO by hand**, if you prefer:

```bash
./build-iso.sh --edition core "$(./fetch-netinst.sh)"          # network (macOS or Linux)
sudo ./build-iso.sh --edition home --offline --variant base     # offline (Linux, root, Podman)
```

These leave the ISO and its `.sha256` in `build/`. Add `--channel testing`
to either kind for a canary machine.

### Write the stick

With [balenaEtcher](https://etcher.balena.io): **Flash from file** (the ISO),
**Select target** (the USB stick), **Flash!** Fedora Media Writer and `dd`
work too. To check a download or build first, run
`sha256sum -c <name>.iso.sha256` in the folder that holds both files.

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

No USB stick needed: Core Edition's `sv-migrate.sh` moves a Silverblue
machine onto any edition (`--edition core|home|studio`); see the
[Core Edition README](https://github.com/Shattered-Vales-Studio/OS-Linux-FedoraSB-ShatteredValesOS_CoreEdition#installing).

## Checks

`./build-iso.sh --edition core|studio|home --check` renders the kickstart and
runs Fedora's `ksvalidator` without building an ISO; CI runs it for every
edition (network and offline) on every pull request.

## Keeping up with Fedora

- **Network ISOs** always install the newest image, so they only need a new
  release when the installer changes or for a new Fedora release (run the
  *release-network-isos* workflow).
- **Offline ISOs** hold the image from the day they were built; installed
  machines download everything newer right after first boot. Rebuild them
  whenever you hand out new sticks.
- **New Fedora releases:** the *fedora-release* workflow checks every
  Monday. When Fedora N+1 is out and its tool and bootc images are
  published, it pushes a `fedora-<N+1>` branch with the version bumps and
  opens an issue with the pull request link and a test checklist, which ends
  with publishing new network installers.
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
