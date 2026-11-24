#!/usr/bin/env bash
#
# build-all.sh
#
# Purpose:
#   Builds the installer ISOs for the current Fedora release in one run and
#   puts the finished ones, with their checksums, in a folder you can open:
#     - network installers for Core, Studio and Home (each picks base or
#       NVIDIA graphics when it installs)
#     - offline installers for each edition, base and NVIDIA
#   By default it builds all nine; options pick a subset, so offline ISOs
#   are only built when someone needs them. Nothing is uploaded anywhere.
#   Fedora's netinst ISO is downloaded once by fetch-netinst.sh, checked
#   against Fedora's published checksum, and cached for next time. At most
#   two ISOs build at once, which keeps memory and disk use reasonable.
#   Every ISO keeps its own log in build/. An ISO whose build fails is
#   reported and not moved, so an older copy can never stand in for it.
#
# Usage:
#   ./build-all.sh [--edition core|studio|home]... [--variant base|nvidia]...
#                  [--network-only | --offline-only] [--channel latest|testing]
#                  [--out DIR] [--keep-cache]
#     --edition       build only this edition (repeat for more; default all)
#     --variant       offline graphics variants (repeat; default base and nvidia)
#     --network-only  only the network installers (quick, ~1.3 GB each)
#     --offline-only  only the offline installers (~4-8 GB each)
#     --channel       image tag the installers install (default latest)
#     --out           folder for the finished ISOs
#                     (default ~/ShatteredValesOS-ISOs)
#     --keep-cache    keep each offline build's caches for a quicker rebuild
#   Examples:
#     ./build-all.sh                                    everything
#     ./build-all.sh --edition home --offline-only --variant base
#   Run as your normal account (not with sudo). It asks for your password
#   once and keeps sudo active until the builds finish.
#
# Exit codes:
#   0 when every requested ISO built, 1 if any build failed, 64 on bad usage.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly HERE
FEDORA_RELEASE="$(sed -n 's/^readonly FEDORA_TOOLS=".*:\([0-9][0-9]*\)"$/\1/p' "${HERE}/build-iso.sh")"
readonly FEDORA_RELEASE
readonly ALL_EDITIONS=(core studio home)
readonly ALL_VARIANTS=(base nvidia)

# Build options passed through to build-iso.sh, the folder where each
# build records its exit status (subshells cannot update the parent's
# variables), and the verified netinst ISO network builds start from.
BUILD_OPTS=()
RESULTS=""
NETINST=""

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

# friendly_name
#   Maps a build's ISO file name to the name it gets in the output folder,
#   e.g. shatteredvales-home-nvidia-f45-offline.iso ->
#   ShatteredValesOS-Home-NVIDIA-F45-Offline.iso.
#   Arguments: $1 build ISO file name
#   Output: the friendly file name
#   Returns: 0 always
friendly_name() {
    local iso="${1%.iso}" edition variant
    edition="$(cut -d- -f2 <<<"${iso}")"
    edition="${edition^}"
    if [[ "${iso}" == *-offline ]]; then
        variant="$(cut -d- -f3 <<<"${iso}")"
        [[ "${variant}" == nvidia ]] && variant=NVIDIA || variant=Base
        echo "ShatteredValesOS-${edition}-${variant}-F${FEDORA_RELEASE}-Offline.iso"
    else
        echo "ShatteredValesOS-${edition}-F${FEDORA_RELEASE}-Network.iso"
    fi
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
#   Runs a list of builds one after another.
#   Arguments: jobs, each "<iso name>|<build-iso.sh arguments separated by
#              spaces>"; the argument @NETINST@ stands for the netinst ISO,
#              whose path may contain spaces, so it is filled in only after
#              the job is split
#   Returns: 0 always
lane() {
    local job iso i
    local -a args
    for job in "$@"; do
        iso="${job%%|*}"
        read -r -a args <<<"${job#*|}"
        for i in "${!args[@]}"; do
            [[ "${args[i]}" == @NETINST@ ]] && args[i]="${NETINST}"
        done
        build "${iso}" "${args[@]}"
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
    echo "Stopped. ISOs that finished are still in build/."
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

# deliver
#   Moves a finished ISO and its checksum from build/ into the output folder
#   under its friendly name, replacing an older copy of the same name. The
#   checksum file is rewritten for the new name so `sha256sum -c` works in
#   the output folder. Moving rather than copying avoids holding two copies
#   of several GB each.
#   Arguments: $1 build ISO file name, $2 output folder
#   Output: the delivered file name
#   Returns: non-zero if the move fails
deliver() {
    local iso="$1" out="$2" name sum
    name="$(friendly_name "${iso}")"
    sum="$(cut -d' ' -f1 "${HERE}/build/${iso}.sha256")"
    mv -f "${HERE}/build/${iso}" "${out}/${name}"
    printf '%s  %s\n' "${sum}" "${name}" > "${out}/${name}.sha256"
    rm -f "${HERE}/build/${iso}.sha256"
    echo "${name}"
}

# main
#   Parses options, prepares sudo and the netinst ISO, builds the requested
#   ISOs two at a time and moves the ones that built into the output folder.
#   Arguments: see Usage
#   Returns: see Exit codes
main() {
    local channel=latest out="${HOME}/ShatteredValesOS-ISOs" network=1 offline=1
    local iso rc failed=0 started=${SECONDS} edition variant i name
    local -a editions=() variants=() jobs=() lane_a=() lane_b=() delivered=()
    while (( $# )); do
        case "$1" in
            --edition)
                case "${2:-}" in core|studio|home) editions+=("$2") ;; *) die "--edition needs core, studio or home" 64 ;; esac
                shift ;;
            --variant)
                case "${2:-}" in base|nvidia) variants+=("$2") ;; *) die "--variant needs base or nvidia" 64 ;; esac
                shift ;;
            --network-only) offline=0 ;;
            --offline-only) network=0 ;;
            --channel) channel="${2:?--channel needs latest or testing}"; shift ;;
            --out) out="${2:?--out needs a folder}"; shift ;;
            --keep-cache) BUILD_OPTS+=(--keep-cache) ;;
            -h|--help) sed -n '/^# Usage:/,/^#$/p' "$0" | sed 's/^# \{0,3\}//'; exit 0 ;;
            *) die "Unknown option: $1 (see --help)" 64 ;;
        esac
        shift
    done
    (( network || offline )) || die "--network-only and --offline-only together build nothing." 64
    [[ "${channel}" == latest || "${channel}" == testing ]] || die "--channel must be latest or testing" 64
    (( ${#editions[@]} )) || editions=("${ALL_EDITIONS[@]}")
    (( ${#variants[@]} )) || variants=("${ALL_VARIANTS[@]}")
    BUILD_OPTS+=(--channel "${channel}")
    (( EUID != 0 )) || die "Run as your normal account; the script asks for sudo itself." 64
    [[ -n "${FEDORA_RELEASE}" ]] || die "Could not read the Fedora release from build-iso.sh."
    if (( offline )); then
        [[ "$(uname -s)" == Linux ]] || die "Offline ISOs build on Linux; use a Shattered Vales or Fedora machine, or --network-only." 64
    fi
    mkdir -p "${out}" || die "Cannot create the output folder ${out}." 64
    out="$(cd "${out}" && pwd)"

    # Network ISOs first: they take a few minutes each, so they are ready
    # early even when the offline ones take an hour.
    for edition in "${editions[@]}"; do
        if (( network )); then
            jobs+=("shatteredvales-${edition}-f${FEDORA_RELEASE}-installer.iso|--edition ${edition} @NETINST@")
        fi
    done
    for edition in "${editions[@]}"; do
        for variant in "${variants[@]}"; do
            if (( offline )); then
                jobs+=("shatteredvales-${edition}-${variant}-f${FEDORA_RELEASE}-offline.iso|--edition ${edition} --offline --variant ${variant}")
            fi
        done
    done

    say "Building ${#jobs[@]} Fedora ${FEDORA_RELEASE} ISO(s) from the ${channel} images into ${out}. Your sudo password:"
    sudo -v || die "sudo is needed for the builds."
    keep_sudo_alive
    if (( network )); then
        NETINST="$("${HERE}/fetch-netinst.sh")" || die "Could not download and verify Fedora's netinst ISO."
        say "Fedora netinst ready: ${NETINST}"
    fi

    # Two lanes, jobs dealt alternately, so at most two builds run at once
    # and each lane gets a fair share of the long offline builds.
    for i in "${!jobs[@]}"; do
        if (( i % 2 == 0 )); then lane_a+=("${jobs[i]}"); else lane_b+=("${jobs[i]}"); fi
    done

    RESULTS="$(mktemp -d)"
    trap stop_builds INT TERM
    lane "${lane_a[@]}" &
    LANES+=($!)
    if (( ${#lane_b[@]} )); then
        lane "${lane_b[@]}" &
        LANES+=($!)
    fi
    # Only the build lanes: a bare `wait` would also wait for the sudo
    # keep-alive loop, which runs until this script ends.
    wait "${LANES[@]}"
    trap - INT TERM

    for iso in "${RESULTS}"/*; do
        rc="$(cat "${iso}")"
        if (( rc == 0 )); then
            name="$(deliver "$(basename "${iso}")" "${out}")" || { failed=1; continue; }
            delivered+=("${name}")
        else
            failed=1
        fi
    done
    rm -rf "${RESULTS}"

    say "Built ${#delivered[@]} of ${#jobs[@]} ISO(s) in $(( (SECONDS - started) / 60 )) min."
    if (( ${#delivered[@]} )); then
        echo "They are in ${out}:"
        printf '  %s\n' "${delivered[@]}"
        echo "Open the folder in Files, or run: xdg-open '${out}'"
        echo "Check a copy with: (cd '${out}' && sha256sum -c <name>.iso.sha256)"
        echo "Write one to a USB stick with balenaEtcher: Flash from file > the ISO > Select target > Flash."
    fi
    if (( failed )); then
        say "Some ISOs failed; their logs are in ${HERE}/build. Fix and re-run, or build one with build-iso.sh."
        return 1
    fi
    say "All done."
}

main "$@"
