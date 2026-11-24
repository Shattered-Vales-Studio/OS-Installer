#!/usr/bin/env bash
#
# fedora-release.sh
#
# Purpose:
#   Prepares the installers' move to the next Fedora release. Run weekly by
#   the fedora-release workflow. When Fedora N+1 is released (Bodhi state
#   "current") and Fedora publishes the N+1 tool and bootc images the
#   builds use, it pushes a branch fedora-<N+1> that bumps every Fedora
#   version reference in this repo and opens an issue with a one-click link
#   to open the pull request and a test checklist. It never merges anything:
#   a person opens the PR (which starts CI), rebuilds and tests the ISOs and
#   merges. Issues rather than PRs because the organization does not let
#   GitHub Actions create pull requests.
#
# Usage:
#   .github/scripts/fedora-release.sh [--dry-run]
#   Needs GH_TOKEN (contents and issues write) and GITHUB_REPOSITORY in CI.
#
# Exit codes:
#   0 when nothing is due, the branch already exists or the bump was
#   prepared; 1 on failure.

set -euo pipefail

readonly BASE_IMAGES=(
    registry.fedoraproject.org/fedora
    quay.io/fedora/fedora-bootc
)

# current_version
#   Prints the Fedora release the installers are built from.
#   Arguments: none
#   Output: the release number
#   Returns: 1 if it cannot be read
current_version() {
    sed -n 's|^readonly FEDORA_TOOLS="registry.fedoraproject.org/fedora:\([0-9][0-9]*\)"$|\1|p' build-iso.sh | head -n1 | grep .
}

# released
#   Tells whether Bodhi lists a Fedora release as released ("current").
#   Arguments: $1 release number
#   Returns: 0 when released, 1 otherwise
released() {
    local state
    state="$(curl -fsSL --retry 3 "https://bodhi.fedoraproject.org/releases/F$1" \
        | jq -r '.state // empty')" || return 1
    echo "Fedora $1 in Bodhi: ${state:-unknown}"
    [[ "${state}" == current ]]
}

# images_ready
#   Tells whether the Fedora tool and bootc images publish the release.
#   Arguments: $1 release number
#   Returns: 0 when all exist, 1 otherwise
images_ready() {
    local image
    for image in "${BASE_IMAGES[@]}"; do
        if ! skopeo inspect --raw "docker://${image}:$1" >/dev/null 2>&1; then
            echo "Not published yet: ${image}:$1"
            return 1
        fi
    done
}

# bump
#   Rewrites every Fedora version reference from one release to the next.
#   Arguments: $1 current release, $2 next release
#   Returns: non-zero if a file is missing
bump() {
    local from="$1" to="$2"
    sed -i -e "s|fedora:${from}\"|fedora:${to}\"|" -e "s|-v F${from} |-v F${to} |" \
        -e "s|Fedora ${from} Anaconda|Fedora ${to} Anaconda|" \
        -e "s|netinst-x86_64-${from}-|netinst-x86_64-${to}-|" build-iso.sh
    sed -i "s|fedora-bootc:${from}$|fedora-bootc:${to}|" offline/Containerfile
    sed -i -e "s|(currently ${from})|(currently ${to})|" \
        -e "s|netinst-x86_64-${from}-[0-9.]*\.iso|netinst-x86_64-${to}-*.iso|g" \
        -e "s|Fedora ${from} Anaconda|Fedora ${to} Anaconda|" README.md
}

# open_issue
#   Opens the tracking issue with the PR link and the release checklist.
#   Arguments: $1 current release, $2 next release, $3 branch
#   Returns: gh's exit status
open_issue() {
    local from="$1" to="$2" branch="$3"
    # The body goes through stdin: a heredoc inside $( ) trips bash's parser
    # on apostrophes.
    gh issue create --title "Fedora ${to} is out: move the installers to Fedora ${to}" --body-file - <<BODY
Fedora ${to} is released and its tool and bootc images are published. Branch \`${branch}\` bumps every Fedora ${from} reference to ${to}.

**[Open the pull request](https://github.com/${GITHUB_REPOSITORY}/compare/main...${branch}?expand=1)** (that also runs the kickstart checks).

Before merging:
- [ ] The Studio and Home image repos have moved to Fedora ${to} (their own issues), so installers and images match
- [ ] CI validates the kickstarts with the Fedora ${to} validator
- [ ] Download Fedora Everything netinst ${to} and build both network ISOs
- [ ] Build an offline ISO on a Linux machine (\`sudo ./build-iso.sh --edition home --offline --variant base\`)
- [ ] Install from a network ISO and from the offline ISO (networking off) in VMs
BODY
}

# main
#   Checks for the next release and prepares the bump when it is due.
#   Arguments: $1 optional --dry-run
#   Returns: 0 unless a step fails
main() {
    local from to branch dry_run=0
    [[ "${1:-}" == --dry-run ]] && dry_run=1
    from="$(current_version)" || { echo "Could not read image-version from recipes/recipe-base.yml" >&2; exit 1; }
    to=$(( from + 1 ))
    branch="fedora-${to}"
    echo "Building on Fedora ${from}; checking Fedora ${to}."
    released "${to}" || { echo "Nothing to do yet."; exit 0; }
    images_ready "${to}" || { echo "Nothing to do yet."; exit 0; }
    if git ls-remote --exit-code --heads origin "${branch}" >/dev/null; then
        echo "Branch ${branch} already exists; nothing to do."
        exit 0
    fi
    git checkout -q -b "${branch}"
    bump "${from}" "${to}"
    git diff --stat
    if (( dry_run )); then
        echo "Dry run: not pushing ${branch} or opening an issue."
        exit 0
    fi
    git -c user.name="github-actions[bot]" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
        commit -q -am "Move to Fedora ${to}"
    git push -q origin "${branch}"
    open_issue "${from}" "${to}" "${branch}"
}

main "$@"
