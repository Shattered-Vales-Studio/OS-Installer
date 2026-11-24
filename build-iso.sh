#!/usr/bin/env bash
#
# build-iso.sh
#
# Purpose:
#   Builds a Shattered Vales OS installer ISO for writing to a USB stick with
#   balenaEtcher (or Fedora Media Writer). Both editions install the same
#   guided way: Anaconda asks for the language, network and computer name,
#   the disk and the first (administrator) account, and nothing in the ISO is
#   tied to a particular site or organization. The edition only picks which
#   image is installed:
#     studio  shatteredvales-os       developer workstation
#     home    shatteredvales-os-home  family computer
#   Two kinds of ISO:
#     network  Fedora's netinst ISO with the kickstart embedded (mkksiso).
#              Picks the NVIDIA or standard image from the graphics card and
#              downloads it during the install. Builds on macOS or Linux.
#     offline  A Fedora 45 Anaconda environment with one OS image embedded
#              (image-builder generic-iso), so installing needs no network.
#              One ISO per graphics variant. Needs Linux, root and podman,
#              for example a Shattered Vales workstation.
#
# Usage:
#   ./build-iso.sh --edition studio|home [--channel latest|testing] \
#       <Fedora-Everything-netinst-x86_64-45-*.iso> [output.iso]
#   sudo ./build-iso.sh --edition studio|home --offline --variant base|nvidia \
#       [--channel latest|testing]
#   ./build-iso.sh --edition studio|home [--offline] --check
#       Render and validate the kickstart only (no ISO; used by CI).
#
# Inputs:
#   kickstart/installer.ks.in  Kickstart template
#   offline/Containerfile      Installer environment for offline ISOs
#
# Requirements:
#   docker (OrbStack works) or podman; offline ISOs need podman as root on
#   Linux and about 25 GB free.
#
# Exit codes:
#   0 on success, 1 on failure, 64 on bad usage.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly HERE
readonly REGISTRY="ghcr.io/shattered-vales-studio"
readonly OFFLINE_DIR="${HERE}/build/offline"
readonly FEDORA_TOOLS="registry.fedoraproject.org/fedora:45"
# Fedora mirrors sometimes time out mid-build; retry patiently rather than
# fail a build that has already downloaded several GB.
readonly DNF_RETRY="--setopt=retries=10 --setopt=timeout=120 --setopt=minrate=1"
# Only these variables are substituted, so the $variables used by the
# kickstart's own shell script are left untouched. envsubst takes the names
# literally, so they must not expand here.
# shellcheck disable=SC2016
readonly SUBST_VARS='${SV_IMAGE_REGISTRY} ${SV_IMAGE_NAME} ${SV_IMAGE_TAG} ${SV_OFFLINE_IMAGE}'

# die
#   Prints an error and exits.
#   Arguments: $1 message, $2 exit code (default 1)
#   Returns: does not return
die() {
    echo "Error: $1" >&2
    exit "${2:-1}"
}

# say
#   Prints a progress line.
#   Arguments: message words
#   Returns: 0 always
say() {
    printf '\n==> %s\n' "$*"
}

# container_cli
#   Prints the available container runtime; offline builds need podman,
#   because image-builder reads the payload from podman's storage.
#   Arguments: $1 "podman" to require podman
#   Output: "docker" or "podman"
#   Returns: 1 if no suitable runtime is installed
container_cli() {
    if [[ "${1:-}" != podman ]] && command -v docker >/dev/null; then echo docker
    elif command -v podman >/dev/null; then echo podman
    else echo "${1:-docker or podman} is required" >&2; return 1
    fi
}

# render_kickstart
#   Renders and validates the kickstart in a Fedora container. For a network
#   ISO it then embeds it into the netinst ISO; for an offline ISO it writes
#   it to build/offline/ks.cfg for the installer environment.
#   Arguments: $1 image name, $2 channel, $3 mode (check, network or
#              offline), $4 offline payload ref (offline and check modes),
#              $5 input netinst ISO and $6 output name (network mode only)
#   Returns: non-zero on any failure
render_kickstart() {
    local name="$1" channel="$2" mode="$3" payload="${4:-}" input="${5:-}" output="${6:-}"
    local iso_name="" cli
    local -a mounts=(-v "${HERE}:/work:Z")
    if [[ "${mode}" == network ]]; then
        iso_name="$(basename "${input}")"
        mounts+=(-v "$(cd "$(dirname "${input}")" && pwd):/iso:ro,Z")
    fi
    if [[ "${mode}" == offline ]]; then cli="$(container_cli podman)"; else cli="$(container_cli)"; fi

    # mkksiso rewrites the ISO's boot configuration, which needs loop/device
    # access, hence --privileged. Host networking makes the container resolve
    # names exactly like the machine: root's bridged container network
    # cannot reach some host DNS setups (Tailscale's 100.100.100.100), which
    # failed builds with "could not resolve host".
    "${cli}" run --rm --privileged --network host --platform linux/amd64 \
        "${mounts[@]}" -w /work \
        -e SUBST_VARS="${SUBST_VARS}" -e SV_IMAGE_REGISTRY="${REGISTRY}" \
        -e SV_IMAGE_NAME="${name}" -e SV_IMAGE_TAG="${channel}" \
        -e SV_OFFLINE_IMAGE="${payload}" -e MODE="${mode}" \
        "${FEDORA_TOOLS}" bash -euo pipefail -c "
            dnf -y -q ${DNF_RETRY} install lorax gettext pykickstart >/dev/null
            # mkksiso stores the kickstart under its own file name, so it
            # is rendered as ks.cfg for a recognisable name on the stick.
            ks=/tmp/ks.cfg
            envsubst \"\${SUBST_VARS}\" < kickstart/installer.ks.in > \"\${ks}\"
            # The %include files are written by %pre at install time; give
            # the validator representative stand-ins so it can check the
            # whole kickstart, including the included commands.
            if [ -n \"\${SV_OFFLINE_IMAGE}\" ]; then
                printf '%s\\n' \"bootc --source-imgref containers-storage:\${SV_OFFLINE_IMAGE} --target-imgref \${SV_OFFLINE_IMAGE}\" > /tmp/sv-source.ks
            else
                printf '%s\\n' 'ostreecontainer --url=registry.example/os:latest --transport=registry --no-signature-verification' > /tmp/sv-source.ks
            fi
            printf '%s\\n' '%post' 'true' '%end' > /tmp/sv-post.ks
            ksvalidator -v F45 \"\${ks}\"
            echo \"Kickstart OK: \${SV_IMAGE_NAME}\"
            case \"\${MODE}\" in
                check) exit 0 ;;
                offline)
                    mkdir -p build/offline
                    cp \"\${ks}\" build/offline/ks.cfg
                    exit 0 ;;
            esac
            # Removing the media check makes the default boot entry start
            # the installer immediately instead of verifying the USB first.
            # mkksiso refuses to overwrite, so a rebuild replaces the old ISO.
            rm -f 'build/${output}' 'build/${output}.sha256'
            mkksiso --ks \"\${ks}\" -r 'rd.live.check' \
                '/iso/${iso_name}' 'build/${output}'
            cd build && sha256sum '${output}' > '${output}.sha256'
        "
}

# write_iso_yaml
#   Writes image-builder's boot menu and volume label for an offline ISO:
#   one entry that starts Anaconda's graphical installer with the kickstart
#   as its defaults.
#   Arguments: $1 edition, $2 volume label
#   Returns: 0 on success
write_iso_yaml() {
    local edition="$1" label="$2"
    cat > "${OFFLINE_DIR}/iso.yaml" <<YAML
label: "${label}"
grub2:
  timeout: 10
  entries:
    - name: "Install Shattered Vales OS (${edition^})"
      linux: "/images/pxeboot/vmlinuz inst.stage2=hd:LABEL=${label} console=tty0 rhgb quiet inst.graphical"
      initrd: "/images/pxeboot/initrd.img"
YAML
}

# build_offline
#   Builds the offline ISO: pulls the payload into root's container storage,
#   builds the installer environment with the rendered kickstart, and runs
#   image-builder's generic-iso in a privileged Fedora container that shares
#   that storage.
#   Arguments: $1 edition, $2 payload image ref, $3 output ISO name
#   Returns: non-zero on any failure
build_offline() {
    local edition="$1" payload="$2" output="$3" label env_tag work iso
    label="SVOS-${edition^^}"
    env_tag="localhost/shatteredvales-installer-${edition}:latest"
    work="${OFFLINE_DIR}/output"

    write_iso_yaml "${edition}" "${label}"
    say "Downloading ${payload} into root's container storage"
    podman pull "${payload}"
    say "Building the installer environment (${env_tag})"
    podman build --network host -t "${env_tag}" -f "${HERE}/offline/Containerfile" "${OFFLINE_DIR}"

    say "Building the ISO with image-builder"
    rm -rf "${work}" && mkdir -p "${work}"
    podman run --rm --privileged --network host --security-opt label=type:unconfined_t \
        -v /var/lib/containers/storage:/var/lib/containers/storage \
        -v /dev:/dev -v "${work}:/output" "${FEDORA_TOOLS}" bash -euo pipefail -c "
            dnf -y -q ${DNF_RETRY} install image-builder osbuild osbuild-depsolve-dnf podman >/dev/null
            image-builder build --bootc-ref '${env_tag}' \
                --bootc-installer-payload-ref '${payload}' \
                --bootc-default-fs ext4 --output-dir /output generic-iso
        "
    iso="$(find "${work}" -name '*.iso' -print -quit)"
    [[ -n "${iso}" ]] || die "image-builder finished without producing an ISO; see the output above."
    mv "${iso}" "${HERE}/build/${output}"
    rm -rf "${work}"
    (cd "${HERE}/build" && sha256sum "${output}" > "${output}.sha256")
    if [[ -n "${SUDO_UID:-}" ]]; then
        # Built with sudo: hand the result back to the person who ran it.
        chown "${SUDO_UID}:${SUDO_GID:-${SUDO_UID}}" "${HERE}/build/${output}" "${HERE}/build/${output}.sha256"
    fi
}

# main
#   Parses options, renders and validates the kickstart, and builds the ISO.
#   Arguments: see Usage
#   Returns: non-zero on any failure
main() {
    local edition="" channel=latest input="" output="" name
    local check=0 offline=0 variant="" payload="" mode
    while (( $# )); do
        case "$1" in
            --edition) edition="${2:?--edition needs studio or home}"; shift ;;
            --channel) channel="${2:?--channel needs latest or testing}"; shift ;;
            --variant) variant="${2:?--variant needs base or nvidia}"; shift ;;
            --offline) offline=1 ;;
            --check) check=1 ;;
            -h|--help) sed -n '/^# Usage:/,/^#$/p' "$0" | sed 's/^# \{0,3\}//'; exit 0 ;;
            -*) die "Unknown option: $1" 64 ;;
            *) if [[ -z "${input}" ]]; then input="$1"; else output="$1"; fi ;;
        esac
        shift
    done
    [[ "${channel}" == latest || "${channel}" == testing ]] || die "--channel must be latest or testing" 64
    case "${edition}" in
        studio) name=shatteredvales-os ;;
        home) name=shatteredvales-os-home ;;
        *) die "--edition must be studio or home" 64 ;;
    esac
    mkdir -p "${HERE}/build"

    if (( offline )); then
        if (( check )); then
            variant="${variant:-base}"
        fi
        case "${variant}" in
            base) payload="${REGISTRY}/${name}:${channel}" ;;
            nvidia) payload="${REGISTRY}/${name}-nvidia:${channel}" ;;
            *) die "--offline needs --variant base or nvidia" 64 ;;
        esac
        output="${output:-shatteredvales-${edition}-${variant}-offline.iso}"
    else
        output="${output:-shatteredvales-${edition}-installer.iso}"
    fi

    if (( check )); then
        render_kickstart "${name}" "${channel}" check "${payload}"
        if (( offline )); then
            echo "The ${edition} offline kickstart is valid."
        else
            echo "The ${edition} kickstart is valid."
        fi
        return 0
    fi

    if (( offline )); then
        [[ "$(uname -s)" == Linux ]] || die "Offline ISOs build on Linux; use a Shattered Vales or Fedora machine." 64
        (( EUID == 0 )) || die "Offline ISOs need root: run with sudo." 64
        command -v podman >/dev/null || die "Offline ISOs need podman."
        render_kickstart "${name}" "${channel}" offline "${payload}"
        build_offline "${edition}" "${payload}" "${output}"
        mode="offline, ${variant} graphics"
    else
        [[ -n "${input}" ]] || die "Give the Fedora netinst ISO to build from (see --help)." 64
        [[ -f "${input}" ]] || die "Input ISO not found: ${input}"
        render_kickstart "${name}" "${channel}" network "" "${input}" "${output}"
        mode="network"
    fi
    echo "Built ${HERE}/build/${output} (${edition} edition, ${channel} channel, ${mode})"
    echo "Write it to a USB stick with balenaEtcher: Flash from file > ${output} > Select target > Flash."
}

main "$@"
