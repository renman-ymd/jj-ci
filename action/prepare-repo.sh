#!/usr/bin/env bash
# Work out which revisions to check in the checkout actions/checkout made.
#
# Nothing is written into the checkout: jj-ci keeps its own jj repository
# inside .git and creates it on first use, so this script only has to name a
# range that both git and jj understand.
#
# Writes `revisions` to $GITHUB_OUTPUT and JJ_CI_ENTRY to $GITHUB_ENV.
set -euo pipefail

WORKDIR=${WORKDIR:-.}
INPUT_REVISIONS=${INPUT_REVISIONS:-}
EVENT_NAME=${EVENT_NAME:-}
ZERO=0000000000000000000000000000000000000000

die() {
  printf '::error::%s\n' "$*" >&2
  exit 1
}

warn() { printf '::warning::%s\n' "$*"; }

cd "$WORKDIR" || die "working-directory does not exist: $WORKDIR"

git rev-parse --git-dir >/dev/null 2>&1 ||
  die "$PWD is not a git checkout — this action runs after actions/checkout"

shallow=$(git rev-parse --is-shallow-repository)

# Number of commits a range names, or nothing at all when either end is a
# commit this checkout does not have.
revision_count() {
  git rev-list --count "$1" 2>/dev/null
}

derive_range() {
  case "$EVENT_NAME" in
    pull_request | pull_request_target)
      # The checkout is the merge commit; the pull request's own commits are
      # the range between its base and its head.
      if [ -n "${PR_BASE_SHA:-}" ] && [ -n "${PR_HEAD_SHA:-}" ]; then
        printf '%s..%s' "$PR_BASE_SHA" "$PR_HEAD_SHA"
      fi
      ;;
    merge_group)
      if [ -n "${MERGE_BASE_SHA:-}" ] && [ -n "${MERGE_HEAD_SHA:-}" ]; then
        printf '%s..%s' "$MERGE_BASE_SHA" "$MERGE_HEAD_SHA"
      fi
      ;;
    push)
      # `before` is all zeroes when the branch is new, and names a commit that
      # no longer exists after a force push.
      if [ -n "${PUSH_BEFORE:-}" ] && [ "$PUSH_BEFORE" != "$ZERO" ] && [ -n "${PUSH_AFTER:-}" ]; then
        printf '%s..%s' "$PUSH_BEFORE" "$PUSH_AFTER"
      fi
      ;;
  esac
}

head_sha=$(git rev-parse HEAD 2>/dev/null) ||
  die "this checkout has no commits to check"

if [ -n "$INPUT_REVISIONS" ]; then
  # A revset the caller wrote by hand is passed through: it may use anything
  # jj understands, which git cannot be asked about.
  revset=$INPUT_REVISIONS
  count=unknown
elif [ "$shallow" = true ]; then
  # actions/checkout fetches one commit unless told otherwise, and a checkout
  # with no history has no range to reason about. Checking the state that was
  # checked out is what such a job means, so this is normal, not a problem.
  revset=$head_sha
  count=1
  printf 'shallow checkout: checking the checked-out state only\n'
else
  range=$(derive_range)
  if [ -n "$range" ]; then
    count=$(revision_count "$range" || true)
    if [ -z "$count" ]; then
      warn "$EVENT_NAME gave a range this checkout cannot resolve ($range); falling back to the checked-out commit. A force push is the usual cause."
      range=
    fi
  fi
  if [ -n "$range" ]; then
    revset=$range
  else
    revset=$head_sha
    count=1
  fi
fi

# mod.nu, never the bin/jj-ci symlink beside it. Whatever fetches an action
# materialises that symlink as a *copy*, and a copy resolves `path self` to
# bin/, where there are no modules to import. The copy is executable, so testing
# for that proves nothing; the file that is always right is the real one.
entry=$ACTION_ROOT/mod.nu
[ -f "$entry" ] || die "$entry is missing — the action was not fetched whole"

printf 'revisions=%s\n' "$revset" >>"$GITHUB_OUTPUT"
printf 'JJ_CI_ENTRY=%s\n' "$entry" >>"$GITHUB_ENV"
printf 'checking %s revision(s) in %s\n' "$count" "$revset"
