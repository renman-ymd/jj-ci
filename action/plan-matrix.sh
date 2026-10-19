#!/usr/bin/env bash
# Emit the checks of a stage as a GitHub Actions matrix.
#
# `requires` and `skip-if` are not evaluated here on purpose: this runner is not
# the one that will run the checks, so a tool missing here says nothing.
set -euo pipefail

cd "${WORKDIR:-.}"

matrix=$(nu "$JJ_CI_ENTRY" checks "${STAGE:-push}" --json --vcs git)

count=$(printf '%s' "$matrix" | grep -o '"check":' | wc -l | tr -d ' ')

{
  printf 'matrix=%s\n' "$matrix"
  printf 'count=%s\n' "$count"
} >>"$GITHUB_OUTPUT"

printf 'stage %s: %s check(s)\n%s\n' "${STAGE:-push}" "$count" "$matrix"
