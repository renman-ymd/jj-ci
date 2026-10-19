# jj-ci

Local checks for [jujutsu](https://docs.jj-vcs.dev) repositories: a pre-push
gate and an on-demand CI runner, driven by a versioned `.jj-ci.toml` in each
repository — and the same file, unchanged, running on GitHub Actions.

The tool knows nothing about any language, formatter or test runner. A check is
a command; jj-ci decides which revisions to run it on, materialises them, and
reports what happened.

It also runs in a **plain git repository**, with no `.jj` anywhere and nobody on
the team using jj. The gate is then the `pre-push` hook and the policy is the
same file: [git.md](docs/git.md).

## The gate is `jj push`, not `jj commit`

jj has no hooks, and a pre-commit hook would not fit it if it did. A commit
exists the moment a file is saved, `jj describe` and `jj squash` rewrite commits
afterwards, and intermediate commits are allowed to be broken — that freedom is
the point of the tool.

The moment that really corresponds to a git pre-commit hook is **publication**.
So the gate is `jj push`, and it checks exactly what `jj git push` is about to
send. The [reasoning, in full](docs/design.md).

Driving git, the same argument lands on `pre-push`, which is a hook git already
has. `commit-msg` is there too, since a message is worth catching while
`--amend` is still a one-liner — but it is the fast feedback, not the gate.

## Quick start

```bash
cd some-jj-repo
jj-ci init          # writes a commented .jj-ci.toml
jj-ci init --detect # …or starts from a pre-commit / lefthook / hk config
$EDITOR .jj-ci.toml
jj ci               # run the push stage now
jj push             # run it, then publish
jj-ci doctor        # what works here, and what does not
```

A repository with no `.jj-ci.toml` is untouched: `jj push` there tugs the
nearest bookmark forward and calls `jj git push`, much like the common alias it
replaces.

In a git repository the shape is the same, with `git push` as the gate:

```bash
cd some-git-repo
jj-ci init
jj-ci install       # writes the pre-push and commit-msg hooks
git push            # runs the push stage, then publishes
```

## A policy, in miniature

```toml
[jj-ci]
version = 1

[filesets]
SRC = 'root-glob:"src/**/*.ts" ~ root-glob:"**/node_modules/**"'

[checks.typecheck]
command = ["bun", "run", "typecheck"]
paths = ["SRC"]
stages = ["push", "ci"]

[checks.message]
command = ["bunx", "commitlint"]
input = "description"      # the description on stdin, no checkout
```

Every key, and two worked examples: [the config file](docs/config.md).

## On GitHub Actions

```yaml
- uses: actions/checkout@v5
- uses: renman-ymd/jj-ci@v1
```

That runs the `ci` stage over what the event added. There is no install step —
the action *is* the tool. A second action, `renman-ymd/jj-ci/plan@v1`, reads the
same file and emits the stage as a job matrix, so you can run one GitHub job per
check without the list existing twice. See [the GitHub
action](docs/github-actions.md).

## Documentation

| Page | Covers |
| --- | --- |
| [install.md](docs/install.md) | the module, the two jj aliases, nushell completions |
| [config.md](docs/config.md) | `.jj-ci.toml`: checks, stages, filesets, formatters |
| [commands.md](docs/commands.md) | `jj push`, `jj ci`, `jj-ci checks`, tugging |
| [git.md](docs/git.md) | driving a git repository: the hooks, and what differs |
| [github-actions.md](docs/github-actions.md) | the action, the matrix, checkout depth |
| [design.md](docs/design.md) | why it is shaped this way, how it runs things, prior art |

## Requirements

jj **0.44+** (`jj run --ignore-changes`, `--passthrough`) and nushell. Developed
and tested against jj 0.45.1 and nushell 0.115.1. No colocated git repository is
needed, unlike the git-worktree approaches this replaces.

jj is required as a program, not as your version control system: in a git
repository jj-ci keeps a jj repository of its own inside `.git`, and your
working tree never sees it.

## Prior art

[`jj run`](https://docs.jj-vcs.dev/latest/design/run/) is the primitive this is
built on. [jj-hooks](https://github.com/mattwilkinsonn/jj-hooks),
[jj-pre-push](https://github.com/acarapetis/jj-pre-push) and
[aazuspan's write-up](https://www.aazuspan.dev/blog/automating-pre-push-checks-with-jujutsu/)
reach the same conclusion about *when* to check, by other means —
[compared here](docs/design.md#prior-art).

## License

MIT. See [LICENSE](LICENSE).
