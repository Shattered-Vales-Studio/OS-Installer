#!/usr/bin/env bash
#
# fetch-netinst.sh
#
# Purpose:
#   Downloads Fedora's Everything netinst ISO for the release the installers
#   are built from, checks it against Fedora's published CHECKSUM file, and
#   prints its path. A verified copy already in the cache is reused, so
#   repeated builds download it once. Network installer ISOs are built from
#   this ISO, both by build-all.sh and by the release-network-isos workflow.
#
# Inputs:
#   The Fedora release, read from FEDORA_TOOLS in build-iso.sh.
#   SV_NETINST_CACHE (optional environment variable): cache folder, default
#   ~/.cache/shatteredvales.
#
# Usage:
#   ./fetch-netinst.sh            prints the verified ISO's path on stdout;
#                                 progress goes to stderr
#
# Exit codes:
#   0 on success, 1 if the ISO cannot be found, downloaded or verified.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly HERE
FEDORA_RELEASE="$(sed -n 's/^readonly FEDORA_TOOLS=".*:\([0-9][0-9]*\)"$/\1/p' "${HERE}/build-iso.sh")"
readonly FEDORA_RELEASE
readonly CACHE_DIR="${SV_NETINST_CACHE:-${XDG_CACHE_HOME:-${HOME}/.cache}/shatteredvales}"
readonly FEDORA_ISO_URL="https://dl.fedoraproject.org/pub/fedora/linux/releases/${FEDORA_RELEASE}/Everything/x86_64/iso"

# verify_netinst
#   Checks a downloaded netinst ISO against Fedora's CHECKSUM file.
#   Arguments: $1 ISO file name, $2 CHECKSUM file name (both in CACHE_DIR)
#   Returns: 0 if the checksum matches, 1 otherwise
verify_netinst() {
    # The CHECKSUM file also holds its PGP signature lines; sha256sum warns
    # about them and checks only the listed ISO.
    (cd "${CACHE_DIR}" && grep -F "(${1})" "${2}" | sha256sum -c --quiet - >/dev/null 2>&1)
}

# main
#   Finds the newest netinst ISO of the release, downloads it unless a
#   verified copy is cached, and checks it.
#   Arguments: none
#   Output: the ISO's path on stdout
#   Returns: 1 if the ISO cannot be found, downloaded or verified
main() {
    local listing name checksum
    [[ -n "${FEDORA_RELEASE}" ]] || { echo "Could not read the Fedora release from build-iso.sh." >&2; return 1; }
    mkdir -p "${CACHE_DIR}"
    listing="$(curl -fsSL --retry 5 "${FEDORA_ISO_URL}/")" || { echo "Could not list ${FEDORA_ISO_URL}" >&2; return 1; }
    name="$(grep -oE "Fedora-Everything-netinst-x86_64-${FEDORA_RELEASE}-[0-9.]+\.iso" <<<"${listing}" | sort -uV | tail -n1)"
    checksum="$(grep -oE "Fedora-Everything-${FEDORA_RELEASE}-[0-9.]+-x86_64-CHECKSUM" <<<"${listing}" | sort -uV | tail -n1)"
    [[ -n "${name}" && -n "${checksum}" ]] || { echo "No Fedora ${FEDORA_RELEASE} netinst ISO at ${FEDORA_ISO_URL}" >&2; return 1; }
    curl -fsSL --retry 5 -o "${CACHE_DIR}/${checksum}" "${FEDORA_ISO_URL}/${checksum}" || return 1
    if [[ -f "${CACHE_DIR}/${name}" ]] && verify_netinst "${name}" "${checksum}"; then
        echo "${CACHE_DIR}/${name}"
        return 0
    fi
    echo "Downloading ${name}" >&2
    curl -fL --retry 5 --progress-bar -o "${CACHE_DIR}/${name}.part" "${FEDORA_ISO_URL}/${name}" || return 1
    mv "${CACHE_DIR}/${name}.part" "${CACHE_DIR}/${name}"
    if ! verify_netinst "${name}" "${checksum}"; then
        rm -f "${CACHE_DIR}/${name}"
        echo "${name} does not match Fedora's checksum; deleted." >&2
        return 1
    fi
    echo "${CACHE_DIR}/${name}"
}

main "$@"
