#!/usr/bin/env bash
#
# build-all.sh
#
# Purpose:
#   Builds every installer ISO for the current Fedora release and publishes
#   them to the team Shared Drive in one run:
#     - network installers for Studio and Home (each picks base or NVIDIA
#       graphics when it installs)
#     - offline installers for Studio and Home, base and NVIDIA
#   Fedora's netinst ISO is downloaded once, checked against Fedora's
#   published checksum, and kept in ~/.cache/shatteredvales for next time.
#   The two editions build side by side, one ISO at a time each, which keeps
#   memory and disk use reasonable. Every ISO keeps its own log in build/.
#   An ISO whose build fails is reported and never published, so an older
#   copy left in build/ cannot reach the Drive; the rest still publish.
#
# Usage:
#   ./build-all.sh [--channel latest|testing] [--no-publish] [--keep-cache]
#     --channel     image tag the installers install (default latest)
#     --no-publish  build only; publish later with ./publish-iso.sh
#     --keep-cache  keep each offline build's caches for a quicker rebuild
#   Run as your normal account (not with sudo). It asks for your password
#   once and keeps sudo active until the builds finish. Publishing happens
#   only on a machine where the Drive connection has been set up
#   (./publish-iso.sh --setup "<Shared Drive name>"); otherwise the ISOs stay in build/.
#
# Exit codes:
#   0 when every ISO built (and published), 1 if any build or upload
#   failed, 64 on bad usage.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly HERE
FEDORA_RELEASE="$(sed -n 's/^readonly FEDORA_TOOLS=".*:\([0-9][0-9]*\)"$/\1/p' "${HERE}/build-iso.sh")"
readonly FEDORA_RELEASE
readonly CACHE_DIR="${XDG_CACHE_HOME:-${HOME}/.cache}/shatteredvales"
readonly FEDORA_ISO_URL="https://dl.fedoraproject.org/pub/fedora/linux/releases/${FEDORA_RELEASE}/Everything/x86_64/iso"
readonly REMOTE="${SV_DRIVE_REMOTE:-svos-drive}"
readonly RCLONE_CONF="${XDG_CONFIG_HOME:-${HOME}/.config}/rclone/rclone.conf"

# Build options passed through to build-iso.sh, and the folder where each
# build records its exit status (subshells cannot update the parent's
# variables).
BUILD_OPTS=()
RESULTS=""

# die
#   Prints an error and exits.
#   Arguments: $1 message, $2 exit code (default 1)
#   Returns: does not return
die() {
    echo "Error: $1" >&2
    exit "${2:-1}"
}

# say
#   Prints a progress line with the time, so a long run can be followed.
#   Arguments: message words
#   Returns: 0 always
say() {
    printf '[%s] %s\n' "$(date +%H:%M)" "$*"
}

# drive_ready
#   Tells whether the Shared Drive connection has been set up.
#   Arguments: none
#   Returns: 0 if the rclone remote exists, 1 otherwise
drive_ready() {
    # Setup records the Shared Drive last, so a sign-in that was interrupted
    # (a section with no team_drive) does not count as connected.
    awk -v section="[${REMOTE}]" '
        $0 == section { current = 1; next }
        /^\[/ { current = 0 }
        current && /^team_drive = ./ { found = 1 }
        END { exit !found }' "${RCLONE_CONF}" 2>/dev/null
}

# verify_netinst
#   Checks a downloaded netinst ISO against Fedora's CHECKSUM file.
#   Arguments: $1 ISO file name, $2 CHECKSUM file name (both in CACHE_DIR)
#   Returns: 0 if the checksum matches, 1 otherwise
verify_netinst() {
    # The CHECKSUM file also holds its PGP signature lines; sha256sum warns
    # about them and checks only the listed ISO.
    (cd "${CACHE_DIR}" && grep -F "(${1})" "${2}" | sha256sum -c --quiet - >/dev/null 2>&1)
}

# fetch_netinst
#   Downloads Fedora's Everything netinst ISO for this release unless a
#   verified copy is already cached, and checks it.
#   Arguments: none
#   Output: the ISO's path on stdout
#   Returns: 1 if the ISO cannot be found, downloaded or verified
fetch_netinst() {
    local listing name checksum
    mkdir -p "${CACHE_DIR}"
    listing="$(curl -fsSL --retry 5 "${FEDORA_ISO_URL}/")" || return 1
    name="$(grep -oE "Fedora-Everything-netinst-x86_64-${FEDORA_RELEASE}-[0-9.]+\.iso" <<<"${listing}" | sort -uV | tail -n1)"
    checksum="$(grep -oE "Fedora-Everything-${FEDORA_RELEASE}-[0-9.]+-x86_64-CHECKSUM" <<<"${listing}" | sort -uV | tail -n1)"
    [[ -n "${name}" && -n "${checksum}" ]] || return 1
    curl -fsSL --retry 5 -o "${CACHE_DIR}/${checksum}" "${FEDORA_ISO_URL}/${checksum}" || return 1
    if [[ -f "${CACHE_DIR}/${name}" ]] && verify_netinst "${name}" "${checksum}"; then
        echo "${CACHE_DIR}/${name}"
        return 0
    fi
    say "Downloading ${name}" >&2
    curl -fL --retry 5 --progress-bar -o "${CACHE_DIR}/${name}.part" "${FEDORA_ISO_URL}/${name}" || return 1
    mv "${CACHE_DIR}/${name}.part" "${CACHE_DIR}/${name}"
    verify_netinst "${name}" "${checksum}" || { rm -f "${CACHE_DIR}/${name}"; return 1; }
    echo "${CACHE_DIR}/${name}"
}

# build
#   Builds one ISO with build-iso.sh (under sudo), keeping the terminal to
#   one line per start and finish; the full output is in the ISO's log.
#   Arguments: $1 ISO file name, then build-iso.sh arguments
#   Returns: 0 always; the outcome is recorded in RESULTS
build() {
    local iso="$1" started=${SECONDS} rc=0
    shift
    say "Started  ${iso}"
    sudo -n "${HERE}/build-iso.sh" "$@" "${BUILD_OPTS[@]}" >/dev/null 2>&1 || rc=$?
    echo "${rc}" > "${RESULTS}/${iso}"
    if (( rc == 0 )); then
        say "Finished ${iso} in $(( (SECONDS - started) / 60 )) min"
    else
        say "FAILED   ${iso}; see build/${iso%.iso}.log"
    fi
}

# lane
#   Builds one edition's three ISOs in turn: network, then both offline.
#   Arguments: $1 edition, $2 netinst ISO path, $3 and $4 offline variants
#              in build order
#   Returns: 0 always
lane() {
    local edition="$1" netinst="$2" variant
    build "shatteredvales-${edition}-f${FEDORA_RELEASE}-installer.iso" --edition "${edition}" "${netinst}"
    for variant in "$3" "$4"; do
        build "shatteredvales-${edition}-${variant}-f${FEDORA_RELEASE}-offline.iso" \
            --edition "${edition}" --offline --variant "${variant}"
    done
}

# Background build lanes, stopped by stop_builds on Ctrl+C.
LANES=()

# descendants
#   Prints every process started under a process, deepest first, so they can
#   be stopped children before parents.
#   Arguments: $1 process ID
#   Output: one process ID per line
#   Returns: 0 always
descendants() {
    local child
    for child in $(pgrep -P "$1"); do
        descendants "${child}"
        echo "${child}"
    done
}

# stop_builds
#   Ctrl+C reaches only this script: bash starts background jobs with Ctrl+C
#   ignored, and the builds run as root under sudo, so without this they
#   would carry on after the terminal returns and keep holding their build
#   locks. Stops both lanes and everything they started (build-iso.sh, and
#   through it podman, which stops and removes its container on TERM), then
#   exits.
#   Arguments: none
#   Returns: does not return; exits 130
stop_builds() {
    local lane
    local -a pids=()
    trap - INT TERM
    say "Stopping the builds"
    for lane in "${LANES[@]}"; do
        mapfile -t -O "${#pids[@]}" pids < <(descendants "${lane}")
        pids+=("${lane}")
    done
    if (( ${#pids[@]} > 0 )); then
        sudo -n kill -TERM "${pids[@]}" 2>/dev/null || kill -TERM "${pids[@]}" 2>/dev/null || true
    fi
    # Only the lanes: the sudo keep-alive loop runs until this script exits.
    wait "${LANES[@]}" 2>/dev/null || true
    echo "Stopped. Nothing was published; ISOs that finished are still in build/."
    exit 130
}

# keep_sudo_alive
#   Refreshes the sudo timestamp in the background until this script ends,
#   because offline builds run longer than sudo's default five minutes. The
#   loop is stopped on exit so it never outlives the script.
#   Arguments: none
#   Returns: 0 always
keep_sudo_alive() {
    local parent=$$
    ( while kill -0 "${parent}" 2>/dev/null; do sudo -n -v 2>/dev/null; sleep 50; done ) &
    # shellcheck disable=SC2064 # the loop's PID is fixed now, on purpose
    trap "kill $! 2>/dev/null" EXIT
}

# main
#   Parses options, prepares sudo, the Drive and the netinst ISO, builds
#   every ISO and publishes the ones that built.
#   Arguments: see Usage
#   Returns: see Exit codes
main() {
    local publish=1 channel=latest netinst iso rc failed=0 started=${SECONDS}
    local -a built=()
    while (( $# )); do
        case "$1" in
            --channel) channel="${2:?--channel needs latest or testing}"; shift ;;
            --no-publish) publish=0 ;;
            --keep-cache) BUILD_OPTS+=(--keep-cache) ;;
            -h|--help) sed -n '/^# Usage:/,/^#$/p' "$0" | sed 's/^# \{0,3\}//'; exit 0 ;;
            *) die "Unknown option: $1 (see --help)" 64 ;;
        esac
        shift
    done
    [[ "${channel}" == latest || "${channel}" == testing ]] || die "--channel must be latest or testing" 64
    BUILD_OPTS+=(--channel "${channel}")
    (( EUID != 0 )) || die "Run as your normal account; the script asks for sudo itself." 64
    [[ -n "${FEDORA_RELEASE}" ]] || die "Could not read the Fedora release from build-iso.sh."
    [[ "$(uname -s)" == Linux ]] || die "Offline ISOs build on Linux; use a Shattered Vales or Fedora machine." 64

    if (( publish )) && ! drive_ready; then
        say "This machine is not connected to the Shared Drive, so the ISOs will stay in build/."
        publish=0
    fi

    say "Building all Fedora ${FEDORA_RELEASE} ISOs from the ${channel} images. Your sudo password:"
    sudo -v || die "sudo is needed for the builds."
    keep_sudo_alive
    netinst="$(fetch_netinst)" || die "Could not download and verify Fedora's netinst ISO from ${FEDORA_ISO_URL}."
    say "Fedora netinst ready: ${netinst}"

    RESULTS="$(mktemp -d)"
    # One lane per edition: each machine builds two ISOs at once at most.
    trap stop_builds INT TERM
    lane studio "${netinst}" nvidia base &
    LANES+=($!)
    lane home "${netinst}" base nvidia &
    LANES+=($!)
    # Only the build lanes: a bare `wait` would also wait for the sudo
    # keep-alive loop, which runs until this script ends.
    wait "${LANES[@]}"
    trap - INT TERM

    for iso in "${RESULTS}"/*; do
        rc="$(cat "${iso}")"
        if (( rc == 0 )); then
            built+=("${HERE}/build/$(basename "${iso}")")
        else
            failed=1
        fi
    done
    rm -rf "${RESULTS}"
    say "Built ${#built[@]} of 6 ISOs in $(( (SECONDS - started) / 60 )) min; they are in ${HERE}/build."

    if (( publish && ${#built[@]} > 0 )); then
        say "Publishing to the Shared Drive"
        "${HERE}/publish-iso.sh" "${built[@]}" || failed=1
    fi
    if (( failed )); then
        say "Some ISOs failed; their logs are in build/. Fix and re-run, or build one with build-iso.sh."
        return 1
    fi
    say "All done."
}

main "$@"
