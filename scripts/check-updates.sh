#!/usr/bin/env bash
# Resolve the upstream (and NSS) commit, decide whether a rebuild is needed, and
# emit the result for the `build` job.
#
# A build is needed when:
#   - the event is anything other than `schedule` — a push means the builder config changed
#     and workflow_dispatch is an explicit request, so both always rebuild; OR
#   - on a scheduled tick, the latest release for RELEASE_PREFIX does not already record the
#     current kernel version.
#
# Required tools: git, curl, gh.
#
# Input env:
#   UPSTREAM_REPO   OpenWrt source repo (owner/name)
#   UPSTREAM_REF    branch, tag, or SHA to build
#   TARGET_DIR      OpenWrt target dir carrying KERNEL_PATCHVER (default: qualcommax)
#   NSS_REPO        NSS packages repo (owner/name); empty if the build tracks no NSS feed
#   NSS_REF         NSS ref (only used when NSS_REPO is set)
#   RELEASE_PREFIX  release tag prefix (tags are <prefix>-<ts>-<run id>)
#   EVENT_NAME      github.event_name
#   REPO            this builder repo (owner/name); defaults to $GITHUB_REPOSITORY
#   GH_TOKEN        forwarded to gh
#   GITHUB_OUTPUT   Actions outputs file (when in CI)
#
# Outputs:
#   upstream_sha    resolved upstream commit
#   nss_sha         resolved NSS commit (empty when NSS_REPO is unset)
#   kernel_version  kernel the tree would build, e.g. 6.18.55
#   need            "true" if a build is needed, else "false"

set -euo pipefail

# shellcheck source=scripts/lib/log.sh
source "$(dirname -- "$0")/lib/log.sh"

: "${UPSTREAM_REPO:?UPSTREAM_REPO required}"
: "${UPSTREAM_REF:?UPSTREAM_REF required}"
: "${RELEASE_PREFIX:?RELEASE_PREFIX required}"
TARGET_DIR="${TARGET_DIR:-qualcommax}"
NSS_REPO="${NSS_REPO:-}"
NSS_REF="${NSS_REF:-}"
EVENT_NAME="${EVENT_NAME:-}"
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
command -v git >/dev/null || log::die "git is required"
command -v curl >/dev/null || log::die "curl is required"

# Resolve a ref to a commit SHA via the remote.
resolve_sha() {
  local repo="$1" ref="$2" sha
  sha="$(git ls-remote "https://github.com/$repo" "$ref" | awk 'NR==1{print $1}')"
  [[ -n "$sha" ]] || log::die "could not resolve $repo@$ref"
  printf '%s\n' "$sha"
}

fetch_upstream_file() {
  curl -fsSL --retry 3 --retry-delay 2 \
    "https://raw.githubusercontent.com/$UPSTREAM_REPO/$UPSTREAM_REF/$1"
}

resolve_kernel_version() {
  local patchver pointver
  patchver="$(fetch_upstream_file "target/linux/$TARGET_DIR/Makefile" |
    sed -n 's/^KERNEL_PATCHVER[^0-9]*\([0-9][0-9.]*\).*/\1/p' | head -1)"
  [[ -n "$patchver" ]] ||
    log::die "no KERNEL_PATCHVER in $UPSTREAM_REPO@$UPSTREAM_REF target/linux/$TARGET_DIR/Makefile"

  pointver="$(fetch_upstream_file "target/linux/generic/kernel-$patchver" |
    sed -n "s/^LINUX_VERSION-${patchver//./\\.}[^0-9]*\([0-9][0-9.]*\).*/\1/p" | head -1)"
  [[ -n "$pointver" ]] ||
    log::die "no LINUX_VERSION-$patchver in target/linux/generic/kernel-$patchver of $UPSTREAM_REPO@$UPSTREAM_REF"

  printf '%s\n' "${patchver}${pointver:+.$pointver}"
}

up_sha="$(resolve_sha "$UPSTREAM_REPO" "$UPSTREAM_REF")"
nss_sha=""
[[ -n "$NSS_REPO" ]] && nss_sha="$(resolve_sha "$NSS_REPO" "$NSS_REF")"
kernel_version="$(resolve_kernel_version)"

# Latest published release body for a prefix; empty when there is none.
latest_body() {
  local prefix="$1"
  [[ -n "$REPO" ]] || return 0
  # Anchored on the tag's timestamp field, so the prefix of one flavour does
  # not also match another's (edma-nss vs edma-nss-mesh).
  gh api "repos/$REPO/releases" --jq \
    "[.[] | select(.draft|not) | select(.tag_name | test(\"^${prefix}-[0-9]{8}T[0-9]{6}Z-\"))] | sort_by(.created_at) | reverse | .[0].body // \"\"" \
    2>/dev/null || printf '%s' ""
}

if [[ "$EVENT_NAME" != "schedule" ]]; then
  # push (builder config changed) or manual dispatch (explicit) -> always rebuild.
  need=true
else
  # scheduled tick -> only rebuild when the kernel moved since the last release
  # of the flavour built from it.
  body="$(latest_body "$RELEASE_PREFIX")"
  needle='`'"${kernel_version}"'`'
  if [[ "$body" == *"$needle"* ]]; then
    need=false
  else
    need=true
  fi
fi

log::info "$UPSTREAM_REPO@$UPSTREAM_REF -> ${up_sha:0:12}  kernel ${kernel_version}${nss_sha:+  nss ${nss_sha:0:12}}  build=$need"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## Upstream check"
    echo "- \`$UPSTREAM_REPO\` -> \`${up_sha:0:12}\`"
    echo "- kernel: **${kernel_version}**"
    [[ -n "$nss_sha" ]] && echo "- nss -> \`${nss_sha:0:12}\`"
    echo "- need: **$need**"
  } >>"$GITHUB_STEP_SUMMARY"
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "upstream_sha=$up_sha"
    echo "nss_sha=$nss_sha"
    echo "kernel_version=$kernel_version"
    echo "need=$need"
  } >>"$GITHUB_OUTPUT"
fi
