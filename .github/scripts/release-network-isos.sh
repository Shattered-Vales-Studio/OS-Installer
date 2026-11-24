#!/usr/bin/env bash
#
# release-network-isos.sh
#
# Purpose:
#   Publishes the network installer ISOs built in build/ as a GitHub release
#   for anyone to download: renames them to their friendly names
#   (ShatteredValesOS-<Edition>-F<release>-Network.iso), rewrites their
#   checksum files for those names, checks every file fits GitHub's 2 GiB
#   per-file limit, picks a tag f<release>-<YYYYMMDD> (with -2, -3, ... when
#   that day already has a release) and creates the release with the ISOs
#   and checksums attached, marked Latest. Network ISOs suit a public
#   release because they always install the newest signed image, so a
#   release only goes stale when the installer itself or the Fedora release
#   changes.
#
# Inputs (environment):
#   GH_TOKEN, GITHUB_REPOSITORY, GITHUB_SHA  set by GitHub Actions
#   CHANNEL   image tag the ISOs install (latest or testing)
#   NOTE      optional text placed at the top of the release notes
#   DRAFT     "true" creates a draft release (for testing the workflow)
#
# Usage:
#   Run by .github/workflows/release-network-isos.yml after build-iso.sh
#   built the network ISO of every edition into build/.
#
# Exit codes:
#   0 on success, 1 if an ISO is missing, too large or the release fails.

set -euo pipefail

readonly EDITIONS=(core studio home)
# GitHub rejects release assets of 2 GiB or more.
readonly MAX_ASSET_BYTES=$(( 2 * 1024 * 1024 * 1024 - 1 ))
FEDORA_RELEASE="$(sed -n 's/^readonly FEDORA_TOOLS=".*:\([0-9][0-9]*\)"$/\1/p' build-iso.sh)"
readonly FEDORA_RELEASE

# release_exists
#   Tells whether the repository already has a release (draft or published)
#   with this tag.
#   Arguments: $1 tag
#   Returns: 0 if it exists, 1 otherwise
release_exists() {
    gh release view "$1" --repo "${GITHUB_REPOSITORY}" >/dev/null 2>&1 \
        || git ls-remote --exit-code --tags origin "refs/tags/$1" >/dev/null 2>&1
}

# pick_tag
#   Picks today's release tag, adding -2, -3, ... when today already has one.
#   Arguments: none
#   Output: the tag
#   Returns: 0 always
pick_tag() {
    local base n=1 tag
    base="f${FEDORA_RELEASE}-$(date -u +%Y%m%d)"
    tag="${base}"
    while release_exists "${tag}"; do
        n=$(( n + 1 ))
        tag="${base}-${n}"
    done
    echo "${tag}"
}

# stage_assets
#   Moves each edition's network ISO to its friendly name in dist/, writes a
#   matching checksum file and checks the size limit.
#   Arguments: none
#   Output: the asset paths, one per line
#   Returns: 1 if an ISO is missing or too large
stage_assets() {
    local edition src name size sum
    mkdir -p dist
    for edition in "${EDITIONS[@]}"; do
        src="build/shatteredvales-${edition}-f${FEDORA_RELEASE}-installer.iso"
        [[ -f "${src}" ]] || { echo "Missing ${src}" >&2; return 1; }
        name="ShatteredValesOS-${edition^}-F${FEDORA_RELEASE}-Network.iso"
        size="$(stat -c %s "${src}")"
        if (( size > MAX_ASSET_BYTES )); then
            echo "${name} is ${size} bytes, over GitHub's 2 GiB release asset limit" >&2
            return 1
        fi
        sum="$(sha256sum "${src}" | cut -d' ' -f1)"
        mv "${src}" "dist/${name}"
        printf '%s  %s\n' "${sum}" "${name}" > "dist/${name}.sha256"
        echo "dist/${name}"
        echo "dist/${name}.sha256"
    done
}

# release_notes
#   Writes the release notes.
#   Arguments: $1 tag
#   Output: Markdown on stdout
#   Returns: 0 always
release_notes() {
    local tag="$1"
    if [[ -n "${NOTE:-}" ]]; then
        printf '%s\n\n' "${NOTE}"
    fi
    cat <<NOTES
Network installers for Shattered Vales OS on Fedora ${FEDORA_RELEASE}, built $(date -u '+%Y-%m-%d') from \`${GITHUB_SHA:0:7}\`. They install the \`:${CHANNEL}\` images.

| File | Installs | For |
|---|---|---|
| \`ShatteredValesOS-Core-F${FEDORA_RELEASE}-Network.iso\` | Core Edition | The plain Shattered Vales desktop |
| \`ShatteredValesOS-Studio-F${FEDORA_RELEASE}-Network.iso\` | Studio Edition | Developer workstations |
| \`ShatteredValesOS-Home-F${FEDORA_RELEASE}-Network.iso\` | Home Edition | Family computers |

Each one downloads the **newest signed image** while it installs, so this release stays current until the installer itself changes; it picks the NVIDIA or standard image from the computer's graphics card. The computer needs internet during the install. For an installer that works without internet, build an offline ISO with \`./build-all.sh --offline-only\` (see the README).

**Write a USB stick** (4 GB or more) with [balenaEtcher](https://etcher.balena.io): *Flash from file* (the ISO), *Select target* (the stick), *Flash!*. Fedora Media Writer and \`dd\` work too.

**Check the download** before writing it: put the \`.sha256\` file next to the ISO and run \`sha256sum -c ShatteredValesOS-<Edition>-F${FEDORA_RELEASE}-Network.iso.sha256\` (Linux), or compare \`shasum -a 256\` (macOS) / \`Get-FileHash\` (Windows) with the value in the file.

Install steps and everything else: [README](https://github.com/${GITHUB_REPOSITORY}/blob/${tag}/README.md).
NOTES
}

# main
#   Stages the assets, picks the tag and creates the release.
#   Arguments: none
#   Returns: non-zero on any failure
main() {
    local tag
    local -a assets flags=()
    [[ -n "${FEDORA_RELEASE}" ]] || { echo "Could not read the Fedora release from build-iso.sh" >&2; exit 1; }
    mapfile -t assets < <(stage_assets)
    (( ${#assets[@]} == ${#EDITIONS[@]} * 2 )) || { echo "Not every ISO could be staged" >&2; exit 1; }
    tag="$(pick_tag)"
    if [[ "${DRAFT:-false}" == true ]]; then
        flags+=(--draft)
    else
        flags+=(--latest)
    fi
    release_notes "${tag}" > dist/notes.md
    gh release create "${tag}" "${assets[@]}" --repo "${GITHUB_REPOSITORY}" \
        --target "${GITHUB_SHA}" \
        --title "Shattered Vales OS F${FEDORA_RELEASE} network installers ($(date -u '+%Y-%m-%d'))" \
        --notes-file dist/notes.md "${flags[@]}"
    echo "Released ${tag}${DRAFT:+ (draft: ${DRAFT})}"
}

main "$@"
