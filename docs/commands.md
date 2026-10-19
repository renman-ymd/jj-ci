# Commands

What [jj-ci](../README.md) exposes, as two jj aliases (`jj push`, `jj ci`) and a
handful of `jj-ci …` subcommands. Installing the aliases is covered in
[install.md](./install.md); what the checks themselves are is
[config.md](./config.md).

Driving a git repository, `jj push` is replaced by the `pre-push` hook and
everything else below still applies, with the differences collected in
[git.md](./git.md). Every command takes `--vcs jj|git` to override what the
repository would otherwise say.

## `jj push [jj git push arguments…]`

Runs the `push` stage over exactly what would be published, then publishes it.

What is about to be published is resolved by asking jj: `jj git push --dry-run`
with your own arguments, whose `bookmark: name [… to <commit>]` lines are
parsed. That honours every flag combination (`-b`, `--all`, `--named`,
`--remote`, `--tracked`) and needs no network. If a future jj rewords it, jj-ci
says so loudly and falls back to `remote_bookmarks()..@` — widening rather than
silently checking nothing.

| Flag | |
| --- | --- |
| `--no-verify` | publish without running anything |
| `--no-tug` | do not move the nearest bookmark forward (see [Tugging](#tugging)) |
| `--fix` | run `jj fix` over the published range first |
| `--stage S`, `--only A,B`, `--no-cache`, `--jobs N`, `--verbose` | as for `jj ci` |
| `--dry-run` | forwarded to jj: asks what would be pushed, runs no checks |

Deletions are not checked: removing a bookmark publishes no code.

### Tugging

Before resolving anything, `jj push` moves the nearest bookmark forward, the way
the common `tug` alias does — but onto **the most recent commit at or under `@`
that carries a description**, not onto `@-` whatever it happens to be.

`@-` is very often an empty, undescribed commit: one `jj new` too many, or a
scratch change left on top. Tugging onto it hands `jj git push` a commit it
refuses to publish — *Won't push commit … since it has no description* — so the
bookmark ends up parked somewhere nothing can be pushed from. Skipping the
undescribed commits puts it on the last thing you actually wrote.

The revset is `heads(::@ & ~description(exact:""))`. `@` is in it because
nothing guarantees `@` sits *above* the work — very often it **is** the work,
described and ready to publish. When `@` has no description it drops out of the
set on its own, so the common "empty working copy on top" case behaves exactly
as if the revset had excluded it.

Two consequences worth knowing:

- **Whether the bookmark then follows `@` depends on your `immutable_heads()`.**
  Editing a file rewrites the working-copy commit, and jj moves bookmarks onto
  rewritten commits. But if the push makes that commit immutable — because the
  bookmark is `trunk()`, or because your `immutable_heads()` includes
  `remote_bookmarks()` — jj says *the working-copy commit became immutable* and
  puts you on a fresh empty commit as the push finishes, so nothing follows.
  Where it stays mutable, the bookmark does track your later edits and the
  remote falls behind until you push again. Either way this is jj's own
  behaviour, not something jj-ci adds.
- **Under a merge, the target can be ambiguous.** With described commits on both
  sides and an undescribed `@`, the revset has no single answer. Rather than
  pick one and silently publish a branch you did not name, jj-ci moves nothing
  and says which commits were ambiguous. A described `@` is never ambiguous: it
  is the only head of its own ancestry.

Backward moves are refused by jj, so a bookmark that already sits ahead of the
target stays where it is.

## `jj ci`

Runs a stage on demand. Defaults to the `push` stage over
`reachable(@, mutable())` — with the usual `immutable_heads()` that includes
remote bookmarks, that is your unpushed work, the same set `jj fix` and `jj run`
default to. In a git repository the default is `remote_bookmarks()..HEAD`, which
is the same idea said in the terms available there, and the command is spelled
`jj-ci ci`.

`--stage S`, `-r REVSET`, `--here`, `--fix`, `--only A,B`, `--no-cache`,
`--jobs N`, `--verbose`, `--strict`.

`--strict` turns a check that *cannot run here* into a failure instead of a
skip, and makes an empty stage an error. `requires` and `skip-if` exist so a
laptop without docker still gets a useful gate; somewhere that is supposed to
have everything, the same skip is a hole. A `paths` skip is left alone — that
one means the check ran and found nothing of its own to do.

`--here` checks the working copy as it is, with no checkout and no bootstrap —
the tight loop, where your `node_modules` already exists. It is weaker than the
default by construction: it describes your disk, not a commit. Under git it
means the working tree, untracked files included; see
[git.md](./git.md#what-differs-from-the-jj-side) for how `paths` is matched
against files that are in no commit yet.

## `jj-ci checks [stage] [--json]`

The checks a stage holds, without running any of them. A table by default, and
in nushell a real one you can filter. `--json` gives one line, which is what the
[GitHub action's](./github-actions.md) matrix is built from.

`requires` and `skip-if` are deliberately *not* evaluated: the machine asking
for the list is usually not the one that will run them.

## `jj-ci init [--detect] [--force]`, `jj-ci doctor`, `jj-ci install`, `jj-ci completions nushell`

`init` writes a starting `.jj-ci.toml`; `--detect` starts from a hook runner
already configured in the repository.

`doctor` reports the jj and nushell versions, which of the two version control
systems this repository is driven with, which checks exist in which stage,
whether the rendered jj config is in sync, and which required tools are
missing. Under jj it adds whether the aliases are installed and whether the
repository is colocated (which decides whether a git-based runner can work at
all); under git, where jj-ci's own jj repository sits, how many refs it has
left behind, and whether each hook is in place.

`install` writes whichever of the two this repository needs: the jj aliases, or
the git hooks. Both are covered in [install.md](./install.md).
