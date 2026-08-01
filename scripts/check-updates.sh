#!/usr/bin/env bash
# Resolve the upstream (and NSS) commit, decide whether a rebuild is needed, and
# emit the result for the `build` job.
#
# A build is needed when:
#   - the event is anything other than `schedule` — a push means the builder config changed
#     and workflow_dispatch is an explicit request, so both always rebuild; OR
#   - on a scheduled tick, the upstream kernel version (qualcommax KERNEL_PATCHVER plus
#     the point release in target/linux/generic/kernel-<patch>) differs from the version
#     recorded in the latest release. Non-kernel upstream changes (drivers, packages,
#     feeds) do not trigger a scheduled build — use workflow_dispatch to force one.
#
# Required tools: git, gh, curl.
#
# Input env:
#   UPSTREAM_REPO   OpenWrt source repo (owner/name)
#   UPSTREAM_REF    branch, tag, or SHA to build
#   NSS_REPO        NSS packages repo (owner/name); empty if the build tracks no NSS feed
#   NSS_REF         NSS ref (only used when NSS_REPO is set)
#   RELEASE_PREFIX  release tag prefix (tags are <prefix>-<ts>-<run id>)
#   EVENT_NAME      github.event_name
#   REPO            this builder repo (owner/name); defaults to $GITHUB_REPOSITORY
#   GH_TOKEN        forwarded to gh
#   GITHUB_OUTPUT   Actions outputs file (when in CI)
#
# Outputs:
#   upstream_sha  resolved upstream commit
#   nss_sha       resolved NSS commit (empty when NSS_REPO is unset)
#   need          "true" if a build is needed, else "false"

set -euo pipefail

# shellcheck source=scripts/lib/log.sh
source "$(dirname -- "$0")/lib/log.sh"

: "${UPSTREAM_REPO:?UPSTREAM_REPO required}"
: "${UPSTREAM_REF:?UPSTREAM_REF required}"
: "${RELEASE_PREFIX:?RELEASE_PREFIX required}"
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

# Resolve the qualcommax kernel version (e.g. "6.18.39") at a given upstream
# commit: KERNEL_PATCHVER from the target Makefile plus the point release from
# target/linux/generic/kernel-<patch>. Fails (non-zero) when unresolvable.
resolve_kernel() {
  local sha="$1" patch point
  patch="$(curl -fsSL "https://raw.githubusercontent.com/$UPSTREAM_REPO/$sha/target/linux/qualcommax/Makefile" \
    | sed -n 's/^KERNEL_PATCHVER[^0-9]*\([0-9][0-9.]*\).*/\1/p' | head -1)"
  [[ -n "$patch" ]] || return 1
  point="$(curl -fsSL "https://raw.githubusercontent.com/$UPSTREAM_REPO/$sha/target/linux/generic/kernel-${patch}" \
    | sed -n "s/^LINUX_VERSION-${patch}[^0-9]*\([0-9][0-9.]*\).*/\1/p" | head -1)"
  printf '%s%s\n' "$patch" "${point:+.$point}"
}

up_sha="$(resolve_sha "$UPSTREAM_REPO" "$UPSTREAM_REF")"
nss_sha=""
[[ -n "$NSS_REPO" ]] && nss_sha="$(resolve_sha "$NSS_REPO" "$NSS_REF")"

cur_kernel=""
rec_kernel=""
if [[ "$EVENT_NAME" != "schedule" ]]; then
  # push (builder config changed) or manual dispatch (explicit) -> always rebuild.
  need=true
else
  # scheduled tick -> only rebuild when the upstream kernel bumped since the
  # last release.
  body=""
  if [[ -n "$REPO" ]]; then
    body="$(gh api "repos/$REPO/releases" --jq \
      "[.[] | select(.draft|not) | select(.tag_name | startswith(\"${RELEASE_PREFIX}-\"))] | sort_by(.created_at) | reverse | .[0].body // \"\"" \
      2>/dev/null || printf '%s' "")"
  fi
  cur_kernel="$(resolve_kernel "$up_sha" || true)"
  rec_kernel="$(sed -n 's/^[-*] \*\*Kernel\*\*: *\([^ ]*\).*/\1/p' <<<"$body" | head -1 | tr -d '`')"
  # Fail-open: build when the kernel cannot be resolved or no release exists yet.
  if [[ -n "$cur_kernel" && -n "$rec_kernel" && "$cur_kernel" == "$rec_kernel" ]]; then
    need=false
  else
    need=true
  fi
fi

log::info "$UPSTREAM_REPO@$UPSTREAM_REF -> ${up_sha:0:12}${nss_sha:+  nss ${nss_sha:0:12}}${cur_kernel:+  kernel ${cur_kernel}}${rec_kernel:+  last ${rec_kernel}}  build=$need"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## Upstream check"
    echo "- \`$UPSTREAM_REPO\` -> \`${up_sha:0:12}\`"
    [[ -n "$nss_sha" ]] && echo "- nss -> \`${nss_sha:0:12}\`"
    [[ -n "$cur_kernel" ]] && echo "- kernel -> \`$cur_kernel\`"
    [[ -n "$rec_kernel" ]] && echo "- last release kernel -> \`$rec_kernel\`"
    echo "- need: **$need**"
  } >>"$GITHUB_STEP_SUMMARY"
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "upstream_sha=$up_sha"
    echo "nss_sha=$nss_sha"
    echo "need=$need"
  } >>"$GITHUB_OUTPUT"
fi
