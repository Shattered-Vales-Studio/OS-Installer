#!/usr/bin/env bash
#
# build-iso.sh
#
# Purpose:
#   Builds a Shattered Vales OS installer ISO for writing to a USB stick with
#   balenaEtcher (or Fedora Media Writer). It takes Fedora's official network
#   installer ISO and embeds the edition's kickstart, so booting the stick
#   installs Shattered Vales OS: the NVIDIA or standard image is picked from
#   the hardware, and the image downloads during the install.
#     studio  Unattended: erases the largest internal disk and creates the IT
#             administrator from installer.env. No questions asked.
#     home    Guided: the installer asks for language, Wi-Fi and the disk;
#             no accounts are created, so first boot walks the family
#             through creating theirs.
#
# Usage:
#   ./build-iso.sh --edition studio|home [--channel latest|testing] \
#       <Fedora-Everything-netinst-x86_64-45-*.iso> [output.iso]
#   ./build-iso.sh --edition studio|home --check
#       Render and validate the kickstart only (no ISO needed; used by CI).
#
# Inputs:
#   kickstart/<edition>.ks.in  Kickstart template
#   installer.env              Studio only: personal values, git-ignored
#                              (see installer.env.example)
#
# Requirements:
#   docker (OrbStack works) or podman.
#
# Exit codes:
#   0 on success, 1 on failure, 64 on bad usage.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly HERE
readonly REGISTRY="ghcr.io/shattered-vales-studio"

# die
#   Prints an error and exits.
#   Arguments: $1 message, $2 exit code (default 1)
#   Returns: does not return
die() {
    echo "Error: $1" >&2
    exit "${2:-1}"
}

# container_cli
#   Prints the available container runtime.
#   Arguments: none
#   Output: "docker" or "podman"
#   Returns: 1 if neither is installed
container_cli() {
    if command -v docker >/dev/null; then echo docker
    elif command -v podman >/dev/null; then echo podman
    else echo "docker or podman is required" >&2; return 1
    fi
}

# main
#   Parses options, renders and validates the kickstart, and builds the ISO.
#   Arguments: see Usage
#   Returns: non-zero on any failure
main() {
    local edition="" channel=latest input="" output="" name vars env_file="" check=0
    while (( $# )); do
        case "$1" in
            --edition) edition="${2:?--edition needs studio or home}"; shift ;;
            --channel) channel="${2:?--channel needs latest or testing}"; shift ;;
            --check) check=1 ;;
            -h|--help) sed -n '/^# Usage:/,/^#$/p' "$0" | sed 's/^# \{0,3\}//'; exit 0 ;;
            -*) die "Unknown option: $1" 64 ;;
            *) if [[ -z "${input}" ]]; then input="$1"; else output="$1"; fi ;;
        esac
        shift
    done
    if (( ! check )); then
        [[ -n "${input}" ]] || die "Give the Fedora netinst ISO to build from (see --help)." 64
        [[ -f "${input}" ]] || die "Input ISO not found: ${input}"
    fi
    [[ "${channel}" == latest || "${channel}" == testing ]] || die "--channel must be latest or testing" 64

    # Only these variables are substituted, so the $variables used by the
    # kickstart's own shell scripts are left untouched. envsubst takes the
    # names literally, so they must not expand here.
    # shellcheck disable=SC2016
    case "${edition}" in
        studio)
            name=shatteredvales-os
            if (( check )); then
                # Validation only: the example values are enough.
                env_file="${HERE}/installer.env.example"
            else
                [[ -f "${HERE}/installer.env" ]] || die "Create installer.env from installer.env.example first."
                if grep -q 'REPLACE_ME\|AAAA\.\.\.' "${HERE}/installer.env"; then
                    die "installer.env still has example values; fill in the admin password hash and SSH key."
                fi
                env_file="${HERE}/installer.env"
            fi
            vars='${SV_IMAGE_REGISTRY} ${SV_IMAGE_NAME} ${SV_IMAGE_TAG} ${SV_LANG} ${SV_KEYBOARD}
${SV_TIMEZONE} ${SV_TARGET_DISK} ${SV_HOSTNAME_PREFIX} ${SV_ADMIN_USER}
${SV_ADMIN_GECOS} ${SV_ADMIN_PASSWORD_HASH} ${SV_ADMIN_SSH_PUBKEY}'
            ;;
        home)
            name=shatteredvales-os-home
            # Home builds need no personal values; an empty file keeps the
            # container command the same for both editions.
            env_file="${HERE}/build/empty.env"
            mkdir -p "${HERE}/build" && : > "${env_file}"
            vars='${SV_IMAGE_REGISTRY} ${SV_IMAGE_NAME} ${SV_IMAGE_TAG}'
            ;;
        *) die "--edition must be studio or home" 64 ;;
    esac
    output="${output:-shatteredvales-${edition}-installer.iso}"

    local iso_name="" cli
    local -a mounts=(-v "${HERE}:/work:Z" -v "${env_file}:/installer.env:ro,Z")
    if (( ! check )); then
        iso_name="$(basename "${input}")"
        mounts+=(-v "$(cd "$(dirname "${input}")" && pwd):/iso:ro,Z")
    fi
    cli="$(container_cli)"
    mkdir -p "${HERE}/build"

    # mkksiso rewrites the ISO's boot configuration, which needs loop/device
    # access, hence --privileged. The env file is mounted rather than copied
    # so personal values never land in the build folder.
    "${cli}" run --rm --privileged --platform linux/amd64 \
        "${mounts[@]}" -w /work \
        -e SUBST_VARS="${vars}" -e SV_IMAGE_REGISTRY="${REGISTRY}" \
        -e SV_IMAGE_NAME="${name}" -e SV_IMAGE_TAG="${channel}" -e CHECK_ONLY="${check}" \
        registry.fedoraproject.org/fedora:latest bash -euo pipefail -c "
            dnf -y -q install lorax gettext pykickstart >/dev/null
            set -a; source /installer.env; set +a
            # mkksiso stores the kickstart under its own file name, so it
            # is rendered as ks.cfg for a recognisable name on the stick.
            ks=/tmp/ks.cfg
            envsubst \"\${SUBST_VARS}\" < kickstart/${edition}.ks.in > \"\${ks}\"
            # The %include files are written by %pre at install time; give
            # the validator representative stand-ins so it can check the
            # whole kickstart, including the included commands.
            printf '%s\\n' 'ostreecontainer --url=registry.example/os:latest --transport=registry --no-signature-verification' > /tmp/sv-source.ks
            printf '%s\\n' 'ignoredisk --only-use=nvme0n1' 'zerombr' 'clearpart --all --initlabel --drives=nvme0n1 --disklabel=gpt' 'bootloader --boot-drive=nvme0n1' > /tmp/sv-disk.ks
            printf '%s\\n' 'network --hostname=sv-test' > /tmp/sv-host.ks
            printf '%s\\n' '%post' 'true' '%end' > /tmp/sv-post.ks
            ksvalidator -v F45 \"\${ks}\"
            echo \"Kickstart OK: ${edition}\"
            if [ \"\${CHECK_ONLY}\" = 1 ]; then exit 0; fi
            # Removing the media check makes the default boot entry start
            # installing immediately instead of verifying the USB first.
            # mkksiso refuses to overwrite, so a rebuild replaces the old ISO.
            rm -f 'build/${output}' 'build/${output}.sha256'
            mkksiso --ks \"\${ks}\" -r 'rd.live.check' \
                '/iso/${iso_name}' 'build/${output}'
            rm -f \"\${ks}\"
            cd build && sha256sum '${output}' > '${output}.sha256'
        "
    if (( check )); then
        echo "The ${edition} kickstart is valid."
        return 0
    fi
    echo "Built ${HERE}/build/${output} (${edition} edition, ${channel} channel)"
    echo "Write it to a USB stick with balenaEtcher: Flash from file > ${output} > Select target > Flash."
}

main "$@"
