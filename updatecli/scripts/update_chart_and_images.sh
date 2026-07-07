#!/bin/bash

info()
{
    echo '[INFO] ' "$@"
}
warn()
{
    echo '[WARN] ' "$@" >&2
}
fatal()
{
    echo '[ERROR] ' "$@" >&2
    exit 1
}

# Returns the Kubernetes minor version RKE2 currently ships as a comparable
# integer (e.g. v1.36.2 -> 1036). This is used to pick the chart
# versionOverrides block whose semver constraint applies to this RKE2 release,
# instead of relying on hardcoded constraint strings that silently stop
# matching whenever the chart drops old Kubernetes ranges.
get_k8s_version_number() {
    local k8s_minor major minor
    k8s_minor=$(grep -E '^KUBERNETES_VERSION=' "${K8S_VERSION_FILE}" | head -n1 | sed -E 's/.*v([0-9]+\.[0-9]+).*/\1/')
    if ! [[ "${k8s_minor}" =~ ^[0-9]+\.[0-9]+$ ]]; then
        fatal "unable to determine the Kubernetes version from ${K8S_VERSION_FILE}"
    fi
    major=${k8s_minor%%.*}
    minor=${k8s_minor#*.}
    echo $((major * 1000 + minor))
}

# Prints the "start end" line numbers of the airgap image block identified by
# the given marker file name (e.g. "images-vsphere.txt"). Prints nothing when
# the block is absent, so callers can decide whether that is fatal (community
# block) or simply skipped (optional prime block). Shared sidecar images appear
# in several blocks with independent versions, so replacements must stay scoped
# to a single block rather than being applied to the whole file.
get_airgap_block_bounds() {
    local marker="${1}" start end
    start=$(grep -n "${marker}" "${CHART_AIRGAP_IMAGES_FILE}" | head -n1 | cut -d: -f1)
    if [ -z "${start}" ]; then
        return 0
    fi
    end=$(awk "NR>${start} && /^[[:space:]]*EOF[[:space:]]*\$/ {print NR; exit}" "${CHART_AIRGAP_IMAGES_FILE}")
    if [ -z "${end}" ]; then
        fatal "could not find the closing EOF of the airgap image block '${marker}'"
    fi
    echo "${start} ${end}"
}

# Maps a chart name to the airgap image component it belongs to, e.g.
# rancher-vsphere-csi / rancher-vsphere-cpi -> vsphere. Both the community
# ("images-<component>.txt") and prime ("images-<component>-prime.txt") blocks
# are derived from this.
get_airgap_component() {
    echo "${1}" | sed -E 's/^rancher-//; s/-(csi|cpi)$//'
}

# Keeps the Rancher Prime hardened image block in sync. The hardened image
# repositories and tags live in the chart's base image blocks as
# primeRepository/primeTag (not in versionOverrides, and not differentiated per
# Kubernetes version), so they are read directly from anywhere in values.yaml.
# When the chart does not (yet) expose prime images, or the prime airgap block
# does not exist, this is a no-op.
update_prime_images() {
    local chart="${1}" component="${2}" bounds start end image tag target target_tag
    bounds=$(get_airgap_block_bounds "images-${component}-prime.txt")
    if [ -z "${bounds}" ]; then
        info "no prime airgap block (images-${component}-prime.txt) found, skipping prime images"
        return 0
    fi
    start=${bounds% *}
    end=${bounds#* }
    while IFS=$'\t' read -r image tag; do
        [ -z "${image}" ] && continue
        target=$(sed -n "${start},${end}p" ${CHART_AIRGAP_IMAGES_FILE} | grep "${image}:")
        if [ -z "${target}" ]; then
            warn "prime image ${image} not found in the airgap scripts, skipping"
            continue
        fi
        target_tag=${target#*:}
        if [ "${target_tag}" != "${tag}" ]; then
            info "updating prime image ${image} in airgap script from version ${target_tag} to ${tag}"
            if test "$DRY_RUN" == "false"; then
                sed -r -i "${start},${end}s~(.*${image}:).*~\1${tag}~g" ${CHART_AIRGAP_IMAGES_FILE}
            else
                info "dry-run is enabled, no changes will occur"
            fi
        else
            info "prime image ${image} did not update from version ${tag}"
        fi
    done <<< "$(yq -r '[.. | objects | select(has("primeRepository") and has("primeTag"))] | .[] | "\(.primeRepository)\t\(.primeTag)"' ${chart}/values.yaml | sort -u)"
}

update_chart_version() {
    info "updating chart ${1} in ${CHART_VERSIONS_FILE}"
    CURRENT_VERSION=$(yq -r '.charts[] | select(.filename == "/charts/'"${1}"'.yaml") | .version' ${CHART_VERSIONS_FILE})
    NEW_VERSION=${2}
    if [ "${CURRENT_VERSION}" != "${NEW_VERSION}" ]; then
        info "found version ${CURRENT_VERSION}, updating to ${NEW_VERSION}"
        chart_updated=true
        if test "$DRY_RUN" == "false"; then
            sed -i "s/${CURRENT_VERSION}/${NEW_VERSION}/g" ${CHART_VERSIONS_FILE}
        else
            info "dry-run is enabled, no changes will occur"
        fi
    else
        info "no new version found"
    fi
}

update_chart_images() {
    info "downloading chart ${1} version ${2} to extract image versions"
    CHART_URL="https://github.com/rancher/rke2-charts/raw/main/assets/${1}/${1}-${2}.tgz"
    curl -s -L ${CHART_URL} | tar xzv ${1}/values.yaml 1> /dev/null
    if test "$chart_updated" == "true"; then
        # Select the versionOverrides block whose semver constraint contains the
        # Kubernetes version RKE2 currently ships (both ">= X < Y" range and
        # "~ X.Y" tilde forms are supported), then pull its repo/tag pairs.
        # Selecting dynamically, rather than matching hardcoded constraint
        # strings, keeps the airgap image list in sync even after the chart
        # shifts its supported Kubernetes ranges.
        K8S_VERSION_NUMBER=$(get_k8s_version_number)
        IMAGES_TAG=$(yq -y -r '
            '"${K8S_VERSION_NUMBER}"' as $kv
            | .versionOverrides[]
            | .constraint as $c
            | (
                if ($c | test("^\\s*>=\\s*[0-9]+\\.[0-9]+\\s*<\\s*[0-9]+\\.[0-9]+\\s*$"))
                then ($c | capture(">=\\s*(?<lo>[0-9]+\\.[0-9]+)\\s*<\\s*(?<hi>[0-9]+\\.[0-9]+)"))
                elif ($c | test("^\\s*~\\s*[0-9]+\\.[0-9]+\\s*$"))
                then ($c | capture("~\\s*(?<maj>[0-9]+)\\.(?<min>[0-9]+)")
                         | {lo: (.maj + "." + .min), hi: (.maj + "." + (((.min|tonumber)+1)|tostring))})
                else empty end
              ) as $r
            | (($r.lo | split(".")) | (.[0]|tonumber) * 1000 + (.[1]|tonumber)) as $lo
            | (($r.hi | split(".")) | (.[0]|tonumber) * 1000 + (.[1]|tonumber)) as $hi
            | select($lo <= $kv and $kv < $hi)
            | .values
        ' ${1}/values.yaml | grep -E "repo|tag")
        if [ -z "${IMAGES_TAG}" ]; then
            fatal "no versionOverrides constraint in chart ${1} matches the current Kubernetes version (${K8S_VERSION_NUMBER}); airgap images cannot be updated"
        fi
        COMPONENT=$(get_airgap_component "${1}")
        AIRGAP_BLOCK_BOUNDS=$(get_airgap_block_bounds "images-${COMPONENT}.txt")
        if [ -z "${AIRGAP_BLOCK_BOUNDS}" ]; then
            fatal "could not locate the airgap image block 'images-${COMPONENT}.txt' for chart ${1}"
        fi
        AIRGAP_BLOCK_START=${AIRGAP_BLOCK_BOUNDS% *}
        AIRGAP_BLOCK_END=${AIRGAP_BLOCK_BOUNDS#* }
        while IFS= read -r line ; do 
            if grep "repo" <<< ${line} &> /dev/null; then
              image=${line#*: }
              tag_line=$(echo "${IMAGES_TAG}" | grep -A1 ${image} 2>&1| sed -n '2 p' | tr -d " ")
              tag=${tag_line#*:}
              # Restrict the lookup and the edit to this chart's airgap block so
              # shared sidecar images in other blocks keep their own versions.
              target_image=$(sed -n "${AIRGAP_BLOCK_START},${AIRGAP_BLOCK_END}p" ${CHART_AIRGAP_IMAGES_FILE} | grep "${image}:")
              if [ -z "${target_image}" ]; then
                # Some chart images (e.g. the upstream csi-snapshotter) are
                # intentionally replaced in the airgap list by rancher-hardened
                # builds with independent versioning, so they legitimately have
                # no matching entry. Warn and skip rather than aborting the whole
                # update, which would otherwise leave every other image stale.
                warn "image ${image} not found in the airgap scripts, skipping"
                continue
              fi
              target_tag=${target_image#*:}
              if [ "$target_tag" != "${tag}" ]; then
                info updating image ${image} in airgap script from version ${target_tag} to ${tag}
                if test "$DRY_RUN" == "false"; then
                    sed -r -i "${AIRGAP_BLOCK_START},${AIRGAP_BLOCK_END}s~(.*${image}:).*~\1${tag}~g" ${CHART_AIRGAP_IMAGES_FILE}
                else
                    info "dry-run is enabled, no changes will occur"
                fi
              else
                info "image ${image} did not update from version ${tag}"
              fi
            else
              continue
            fi 
        done <<< "$IMAGES_TAG"
        update_prime_images "${1}" "${COMPONENT}"
    else
        info "no new version found"
    fi
    # removing downloaded artifacts
    rm -rf ${1}/
}

CHART_VERSIONS_FILE="charts/chart_versions.yaml"
CHART_AIRGAP_IMAGES_FILE="scripts/build-images"
K8S_VERSION_FILE="scripts/version.sh"


CHART_NAME=${1}
CHART_VERSION=${2}
chart_updated=false

update_chart_version ${CHART_NAME} ${CHART_VERSION}
update_chart_images ${CHART_NAME} ${CHART_VERSION}
