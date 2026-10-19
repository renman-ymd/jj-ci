# The GitHub action

[jj-ci](../README.md) ships as a GitHub action, so the same `.jj-ci.toml` drives
the remote build and the list of things that must be green stops existing in two
places. The action works out which revisions the event added and runs a stage
over them. The checkout is left as `actions/checkout` made it — a git checkout,
with no `.jj` written into it: jj-ci keeps its own jj repository inside `.git`,
the same way it does on a [git user's machine](./git.md).

```yaml
- uses: actions/checkout@v5
- uses: renman-ymd/jj-ci@v1
```

There is no separate install step: the action *is* the tool, so the checkout
GitHub makes of this repository is what runs. jj and nushell are fetched from
their own release tarballs.

**The stage is `ci`, not `push`.** The push stage is your local gate, and what
it holds routinely differs from what a build should enforce — it is the one that
carries the `skip-if`s written for a laptop. With `strict` on, a stage selecting
no checks is an error, so a repository with no `ci` stage is told so rather than
quietly handed the wrong one.

**Strict by default.** With every check skipped for a missing tool, jj-ci would
otherwise print `ok — 0 passed, 5 skipped` and exit 0 — a green build that ran
nothing. The action passes `--strict`, so a check that cannot run on the runner
fails there. Give the runner the tool, or set `strict: false`.

## Depth, and which revisions get checked

The example above takes `actions/checkout`'s default of one commit, and that is
usually right: a check with the default `scope = "tip"` judges a tree, not a
history. On a shallow checkout the action checks the state that was checked out,
says so, and does not pretend to reason about a range.

Reach for `fetch-depth: 0` only when a stage contains something that needs more
than the tip — `input = "description"`, or a `scope = "each"` check you actually
want run over every commit. That is normally a job of its own, and the split is
the usual one: build and test shallow, the history-shaped checks separately.
This repository's own [workflow](../.github/workflows/ci.yml) is built that way.

Note that `scope = "each"` does not itself pull in history. Over the single
revision a depth-1 job checks, it runs exactly once; the revset decides how much
is in scope, never the scope key.

Given history, the range comes from the event: a pull request's own commits
(`base..head`, so the merge commit GitHub checks out is not itself judged), the
pushed range on a `push`, `base_sha..head_sha` in a merge queue. A new branch, a
force push and `workflow_dispatch` have no usable range and fall back to the
commit that was checked out. `revisions:` overrides all of that, and is passed
through untouched: it may use anything jj understands, which is more than git
could be asked about. With `strict` on, as it is by default, a revset naming
nothing is still an error rather than a quiet pass — jj-ci reports it instead
of the action.

## One job per check

`jj ci` runs a stage in one process. GitHub would rather run several jobs at
once, and a separate required status check per gate is worth having, so the
matrix can be read out of the same file by the `plan` action:

```yaml
jobs:
  plan:
    runs-on: ubuntu-latest
    outputs:
      matrix: ${{ steps.plan.outputs.matrix }}
      count: ${{ steps.plan.outputs.count }}
      revisions: ${{ steps.plan.outputs.revisions }}
    steps:
      - uses: actions/checkout@v5
      - id: plan
        uses: renman-ymd/jj-ci/plan@v1

  check:
    needs: plan
    if: needs.plan.outputs.count != '0'
    name: ${{ matrix.check }}
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        include: ${{ fromJson(needs.plan.outputs.matrix) }}
    steps:
      - uses: actions/checkout@v5
      - uses: oven-sh/setup-bun@v2
      - uses: renman-ymd/jj-ci@v1
        with:
          only: ${{ matrix.check }}
          revisions: ${{ needs.plan.outputs.revisions }}
```

`plan` emits `[{check, doc}]`, so `matrix.check` names both the job and the one
check it runs. Passing `revisions` through is what keeps every job judging the
same commits instead of each deriving its own. The `if:` guard is not optional:
a matrix with no entries is an error, not an empty run.

The cost is one extra job plus a jj and nushell install in each of the others.
Below a handful of slow checks, the single job is cheaper.

## What stays in the workflow, on purpose

Toolchains (`setup-bun`, `setup-node`), `services:`, anything wanting runner
privileges, concurrency, draft-skipping, permissions. `.jj-ci.toml` says *what*
runs; the workflow says *where*. Putting toolchain setup in the TOML would be a
workflow DSL rebuilt inside a config file.

`[bootstrap]` covers the one piece of setup that really is just a command, and
it runs *inside* the copy `jj run` checks out — which has no `node_modules`. A
workflow that also installs at the repository root therefore pays for it twice;
either let `bootstrap` do it, or mark the checks `workspace = true`.

## Inputs

| Input | Default | Meaning |
| --- | --- | --- |
| `stage` | `ci` | stage to run |
| `revisions` | derived | revset to check |
| `only` | all | comma-separated check names |
| `strict` | `true` | a check that cannot run here fails |
| `no-cache` | `false` | ignore remembered results |
| `jobs` | `1` | revisions checked in parallel |
| `verbose` | `false` | stream check output |
| `working-directory` | `.` | where the checkout is |
| `jj-version`, `nu-version` | `latest` | a version, `latest`, or `preinstalled` |
| `token` | `github.token` | reads the release tags, to dodge the anonymous API limit |

Both tools are installed from their own release tarballs, so nothing is compiled
and no other action is involved. Pin them if you would rather a jj release could
not change your build. Linux and macOS runners only: the checks are nushell, and
`bin/jj-ci` is a symlink, neither of which survives a Windows runner intact.

The action outputs `revisions`, the revset it settled on.
