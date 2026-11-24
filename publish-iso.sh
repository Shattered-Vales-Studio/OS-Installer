#!/usr/bin/env bash
#
# publish-iso.sh
#
# Purpose:
#   Uploads built installer ISOs (and their .sha256 files) to the team's
#   Google Shared Drive, keeping exactly one copy per Fedora release, edition
#   and variant:
#     OS/Studio/ShatteredValesOS-Studio-NVIDIA-F45-Offline.iso
#     OS/Studio/ShatteredValesOS-Studio-F45-Network.iso
#     OS/Home/ShatteredValesOS-Home-Base-F45-Offline.iso
#   Uploading a newer build of the same release, edition and variant
#   replaces the file of that name; other releases are left alone.
#   rclone runs from its official container image, so nothing is installed
#   on the machine. Run as your normal account (not sudo).
#
# Usage:
#   ./publish-iso.sh [--dry-run] [build/<iso> ...]
#     With no files, publishes every ISO in build/.
#   One-time setup of the Drive connection (see README, "Publishing"):
#   ./publish-iso.sh --setup
#
# Environment:
#   SV_DRIVE_REMOTE  rclone remote for the Shared Drive (default svos-drive)
#
# Exit codes:
#   0 on success, 1 on failure, 64 on bad usage.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly HERE
readonly RCLONE_IMAGE="docker.io/rclone/rclone:1.76.0"
readonly REMOTE="${SV_DRIVE_REMOTE:-svos-drive}"
readonly CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/rclone"
readonly DRIVE_ROOT="OS"

# die
#   Prints an error and exits.
#   Arguments: $1 message, $2 exit code (default 1)
#   Returns: does not return
die() {
    echo "Error: $1" >&2
    exit "${2:-1}"
}

# rclone
#   Runs rclone in its container with the Drive configuration and the build
#   folder mounted. Host networking lets the one-time browser sign-in reach
#   rclone's local callback. SELinux separation is off for this container
#   rather than relabelling the folders, because build/ belongs to root
#   after sudo builds and a normal user cannot relabel it.
#   Arguments: rclone arguments
#   Returns: rclone's exit status
rclone() {
    local -a terminal=(-i)
    # A terminal only when there is one: uploads that stream the checksum
    # through stdin must not ask for a TTY.
    if [[ -t 0 && -t 1 ]]; then
        terminal+=(-t)
    fi
    mkdir -p "${CONFIG_DIR}"
    podman run --rm "${terminal[@]}" --network host --userns keep-id \
        --security-opt label=disable \
        -v "${CONFIG_DIR}:/config/rclone" -v "${HERE}/build:/data:ro" \
        "${RCLONE_IMAGE}" "$@"
}

# drive_name
#   Maps a build file name to its Drive folder and file name.
#     shatteredvales-studio-nvidia-f45-offline.iso
#       -> Studio/ShatteredValesOS-Studio-NVIDIA-F45-Offline.iso
#     shatteredvales-home-f45-installer.iso
#       -> Home/ShatteredValesOS-Home-F45-Network.iso
#   Arguments: $1 ISO file name (no folder)
#   Output: "<Edition>/<name>"
#   Returns: 1 if the name does not follow build-iso.sh's naming
drive_name() {
    local file="$1" edition variant release kind
    if [[ "${file}" =~ ^shatteredvales-(studio|home)-(base|nvidia)-f([0-9]+)-offline\.iso$ ]]; then
        edition="${BASH_REMATCH[1]}" variant="${BASH_REMATCH[2]}" release="${BASH_REMATCH[3]}" kind=Offline
    elif [[ "${file}" =~ ^shatteredvales-(studio|home)-f([0-9]+)-installer\.iso$ ]]; then
        edition="${BASH_REMATCH[1]}" variant="" release="${BASH_REMATCH[2]}" kind=Network
    else
        return 1
    fi
    edition="${edition^}"
    case "${variant}" in
        nvidia) variant="NVIDIA-" ;;
        base) variant="Base-" ;;
    esac
    printf '%s/ShatteredValesOS-%s-%sF%s-%s.iso' "${edition}" "${edition}" "${variant}" "${release}" "${kind}"
}

# setup
#   Creates the Shared Drive connection with rclone's guided setup.
#   Arguments: none
#   Returns: rclone's exit status
setup() {
    cat <<EOF
rclone's setup asks a few questions. Answer:
  n               new remote
  ${REMOTE}       name (type exactly this)
  drive           storage type (Google Drive)
  <Enter>         client_id and client_secret (leave empty)
  1               scope: full access
  <Enter>         service_account_file (leave empty)
  n               edit advanced config
  y               use web browser to authenticate: open the link it prints,
                  sign in with your studio Google account and allow access
  y               configure this as a Shared Drive, then pick the internal
                  shared drive from the list by its number
  y               keep this remote, then q to quit
EOF
    rclone config
}

# main
#   Publishes the given ISOs, or every ISO in build/.
#   Arguments: see Usage
#   Returns: non-zero if an upload fails
main() {
    local dry_run=0 iso file target
    local -a isos=() flags=()
    (( EUID != 0 )) || die "Run as your normal account, not with sudo." 64
    command -v podman >/dev/null || die "podman is required."
    while (( $# )); do
        case "$1" in
            --setup) setup; exit ;;
            --dry-run) dry_run=1 ;;
            -h|--help) sed -n '/^# Usage:/,/^#$/p' "$0" | sed 's/^# \{0,3\}//'; exit 0 ;;
            -*) die "Unknown option: $1" 64 ;;
            *) isos+=("$1") ;;
        esac
        shift
    done
    if (( ${#isos[@]} == 0 )); then
        shopt -s nullglob
        isos=("${HERE}"/build/*.iso)
        shopt -u nullglob
    fi
    (( ${#isos[@]} > 0 )) || die "No ISOs in build/ to publish."
    if ! grep -qs "^\[${REMOTE}\]" "${CONFIG_DIR}/rclone.conf"; then
        die "No Drive connection yet. Run once: ./publish-iso.sh --setup"
    fi
    (( dry_run )) && flags+=(--dry-run)

    for iso in "${isos[@]}"; do
        file="$(basename "${iso}")"
        [[ -f "${HERE}/build/${file}" ]] || die "${iso} is not in build/."
        target="$(drive_name "${file}")" || die "${file} is not named like a build-iso.sh ISO."
        [[ -f "${HERE}/build/${file}.sha256" ]] || die "${file}.sha256 is missing; rebuild the ISO."
        echo "==> ${file} -> ${REMOTE}:${DRIVE_ROOT}/${target}"
        # copyto replaces a file of the same name, which keeps one copy per
        # release, edition and variant.
        rclone copyto "${flags[@]}" --progress "/data/${file}" "${REMOTE}:${DRIVE_ROOT}/${target}"
        # The checksum file names the build's own file; rewrite it for the
        # Drive name so `sha256sum -c` works on a downloaded copy.
        rclone rcat "${flags[@]}" "${REMOTE}:${DRIVE_ROOT}/${target}.sha256" \
            < <(sed "s|  ${file}\$|  ${target#*/}|" "${HERE}/build/${file}.sha256")
    done
    echo "Published to the Shared Drive under ${DRIVE_ROOT}/."
}

main "$@"
