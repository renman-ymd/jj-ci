# The `.jj-ci.toml` file

Every repository using [jj-ci](../README.md) declares its own policy in
`.jj-ci.toml` at the repository root (or `.jj-ci/config.toml`). It is versioned,
so the policy travels with the code and is reviewed with it.

One run uses one policy: the file is read once, from your working copy, and
applies to every revision in scope — checking a stack does not mean running each
commit against whatever policy it happened to carry.

`jj-ci init` writes a commented starting point; `jj-ci init --detect` starts from
a pre-commit, lefthook, hk or prek config already in the repository.

```toml
[jj-ci]
version = 1
autodetect = false     # with no [checks], detect pre-commit/lefthook/hk/prek

[filesets]             # rendered into jj's [fileset-aliases]
SRC = 'root-glob:"src/**/*.ts" ~ root-glob:"**/node_modules/**"'

[bootstrap]            # run inside the isolated copy before any check
command = ["bun", "install", "--frozen-lockfile"]
fingerprint = ["bun.lock"]

[format.prettier]      # rendered into jj's [fix.tools], driving `jj fix`
command = ["bunx", "prettier", "--stdin-filepath=$path"]
patterns = ["SRC"]

[checks.typecheck]
command = ["bun", "run", "typecheck"]
```

Two worked examples ship beside this file: [a Bun and Turbo
monorepo](../examples/bun-monorepo.jj-ci.toml) and [a Rust
crate](../examples/rust.jj-ci.toml).

## Check keys

| Key | Default | Meaning |
| --- | --- | --- |
| `command` | required | argv. `$files` marks where matched paths go; otherwise they are appended |
| `stages` | `["push"]` | `push` (the gate), `ci` (`jj ci --stage ci`), or any name you invent |
| `scope` | `"tip"` | `tip`: the commit being published. `each`: every published commit |
| `input` | `"files"` | `description`: the commit description arrives on stdin, no checkout |
| `paths` | `[]` | filesets; the check is skipped when the revision changed nothing matching |
| `pass-files` | `true` | append the matched paths to `command` (`false` = use `paths` only to decide) |
| `requires` | `[]` | binary names; the check is skipped, with a reason, when one is not on `PATH` |
| `skip-if` | `[]` | argv; exit 0 means skip |
| `skip-reason` | `"skip-if matched"` | what the skipped line says |
| `cache` | `true` | remember that this commit passed this check |
| `workspace` | `false` | run in the real working copy instead of an isolated one |
| `enabled` | `true` | |
| `doc` | `""` | a note to your future self |

`scope` defaults to `each` when `input = "description"`: a description belongs
to one commit, so checking only the tip would leave the commits underneath
unvalidated.

**`scope` is not a statement about history.** It says how many of the revisions
*already in scope* a check visits, and the revset decides what is in scope. Over
a single revision, `each` and `tip` do the same work — which is why a
`scope = "each"` check costs nothing in a CI job that checks one commit. See
[github-actions.md](./github-actions.md).

## Stages

A stage is just a name. `push` is what the [`jj push`](./commands.md) gate runs;
everything else you invoke with `jj ci --stage <name>`, and the GitHub action
defaults to `ci`.

Splitting them is the point: the gate can hold checks written for a laptop —
`skip-if` on a missing docker daemon, a fast subset — while `ci` holds what a
build must enforce. A check can sit in several stages at once.

## Formatters

`[format.<name>]` is jj's own `fix.tools` schema — `command`, `patterns`,
`enabled`, `line-range-arg`, `run-tool-if-zero-line-ranges` — declared where it
can be versioned. jj-ci renders it into the repo-level jj config, so `jj fix`
works natively: jj's fileset matching, its deduplication across revisions, its
line ranges, none of jj-ci in the hot path.

Since jj 0.44 the repo-level config lives *outside* the repository
(`~/.config/jj/repos/<hash>/config.toml`), unversioned and per-machine, and jj
has no `include` mechanism. Rendering is how a versioned declaration reaches it.
The block is written between markers and refreshed whenever `.jj-ci.toml`
changes; anything outside the markers is left alone, and jj-ci refuses to render
if the file declares `[fix.tools]` or `[fileset-aliases]` of its own rather than
silently producing TOML that means something else.

## The same file under git

Nothing in `.jj-ci.toml` names a version control system, and nothing here has a
git-only spelling: filesets stay jj filesets, because jj is what matches them
either way. Two keys mean slightly more under git than under jj:

- `[format.*]` is still read and still rendered, but `--fix` is refused there,
  since a rewritten commit would exist only inside jj-ci's own repository.
- `workspace = true` runs the check in a real git working copy, with an index
  and a `.git`. The runners that cannot work under jj — pre-commit, lefthook,
  hk — work under it.

[git.md](./git.md) has the rest.

## Filesets: use `root-glob:`, not `glob:`

`glob:` is resolved against the directory you are standing in. `glob:"**/*.ts"`
from `apps/backend/` matches only that subtree, and an exclusion written for the
repository root does not apply. `root-glob:` and `root-file:` are
workspace-relative and mean the same thing everywhere.

Filesets support `{a,b}` alternation, `|`, `&`, `~` and parentheses, and aliases
may refer to other aliases.
