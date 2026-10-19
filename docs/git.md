# jj-ci for git users

[jj-ci](../README.md) runs in a plain git repository — one with a `.git` and no
`.jj` anywhere, not colocated, with nobody on the team using jj. The gate is
the `pre-push` hook, the policy is the same `.jj-ci.toml`, and the same file
works for a colleague who does drive the repository with jj.

jj is still required as a program. It is not required as your version control
system.

```bash
cd some-git-repo
jj-ci init            # writes a commented .jj-ci.toml
$EDITOR .jj-ci.toml
jj-ci ci              # run the push stage now
jj-ci install         # write the two hooks
git push              # runs the gate, then publishes
jj-ci doctor          # what works here, and what does not
```

## How it works

jj-ci keeps **a jj repository of its own** in `.git/jj-ci/shadow`, created the
first time it needs one, backed by the object store your git repository already
has:

```bash
jj git init .git/jj-ci/shadow --git-repo <your .git>
jj new 'root()'
```

The second line is what makes it cheap: its working-copy commit is empty, so
the working copy holds no files at all. Nothing ever reads them — checks run
either in the copies `jj run` makes or in your own working tree — so the whole
thing is metadata and nothing else.

Not `jj sparse set --clear`, which empties the working copy just as well and is
wrong one step further on. Since jj 0.46, `jj run` copies the workspace's
sparse patterns into the copies it checks out, so an emptied workspace would
hand every check an empty tree. A check that globs for its inputs passes on an
empty tree, silently — a gate that reports green having examined nothing. An
empty *commit* has no such effect: the patterns stay at their default, and the
copies are complete.

Your working tree never learns about it. There is no `.jj` beside your files,
nothing to add to `.gitignore`, and `git status` is unchanged. Because it lives
inside `.git`, it is not cloned, not pushed, and disappears with the repository.

Everything below that point is the ordinary jj-ci: `jj run` checks each
revision out into a private copy, filesets match, results are cached by commit
id. The checks never know which of the two you drive.

A consequence worth knowing: jj only sees the refs it has been shown, so every
invocation runs `jj git import` first. Commits you made a second ago are
visible; the shadow is never authoritative on its own.

## The two hooks

`jj-ci install` writes both into `.git/hooks` (or wherever `core.hooksPath`
points). It refuses to overwrite a hook it did not write, and prints the lines
to add instead, so a repository already running husky or lefthook is yours to
wire up by hand.

**`pre-push`** is the gate, and the direct equivalent of `jj push`. git hands
it the refs it is about to send, and jj-ci runs the `push` stage over exactly
the commits that would arrive at the remote: `<remote sha>..<local sha>` per
ref, or everything not yet published when the branch is new. Deleting a branch
publishes no code, so it is not checked. A failure stops the push; `git push
--no-verify` goes anyway.

Tags go through the same path. An annotated tag names a tag object rather than
a commit, so it is followed to the commit underneath first; a tag on something
already published then has nothing left to check, and one on a commit you have
not pushed is checked like any other.

**`commit-msg`** runs every check with `input = "description"`, whatever stage
it belongs to, against the message you just wrote — after git's comment block
and any scissors section are stripped, so the check sees what will actually be
recorded. It needs no checkout, so it costs a process and nothing more.

Those description checks **also run again at push**, and that is deliberate.
`commit-msg` is leaky by construction:

| Operation | `commit-msg` runs |
| --- | --- |
| `git commit` | yes |
| `git commit --amend` | yes |
| `rebase -i` → `reword` | yes |
| `rebase -i` → `squash` | **no** |
| `cherry-pick` | **no** |

A squash invents a message no hook ever saw. So does a commit from a colleague
who has not installed anything, and so does `--no-verify`. `commit-msg` is the
fast feedback, while `git commit --amend` is still a one-liner; `pre-push` is
the gate.

The interpreter is written into each hook by absolute path. Git hooks inherit
whatever environment spawned them, and a GUI client usually has none of your
`PATH`; a gate that quietly does not run is worse than no gate.

## What differs from the jj side

**`--fix` is refused.** `jj fix` rewrites the commits it formats. Here those
rewrites would exist only inside `.git/jj-ci/shadow`: no branch would move,
your working tree would not change, and the next run would format the originals
over again. `[format.*]` is still read and still rendered, so a colleague
running `jj fix` in the same repository gets it.

**`jj push` is not available**, and says so. `git push` is the publication, and
the hook is what gates it.

**`--here` means the working tree**, uncommitted and untracked files included.
Since the working tree is not a commit, and nothing in jj can match a fileset
against files that exist in no commit, jj-ci builds one: a scratch index filled
from the working tree — `git add` honours `.gitignore`, so what lands in it is
what a commit would contain — written out with `git write-tree` and
`git commit-tree`. Your real index, your working tree and every branch are left
exactly as they were. `paths` then matches exactly, new files and all.

**`workspace = true` is stronger here than under jj.** That flag runs a check in
the real working copy instead of an isolated one, and under git the real
working copy is a genuine git repository with an index. The hook runners that
cannot work under jj at all — pre-commit, lefthook, hk — work here.

**The default revset is `remote_bookmarks()..HEAD`**: your unpushed commits,
the same set the pre-push hook will look at. Your git branches reach jj as
bookmarks and your `refs/remotes/*` as remote bookmarks, so this means what it
looks like it means.

## What it leaves in your repository

jj pins every commit it imports with a ref under `refs/jj/keep/`. They are real
refs in your real repository: `git for-each-ref` shows them, and they keep the
objects they name alive. They are not pushed, and git otherwise ignores them.

They accumulate at roughly one per commit. Past a hundred, jj-ci tidies them:
it abandons the shadow's operation log — the undo history of a repository
nobody drives by hand — and runs `jj util gc`. The default two-week expiry is
kept deliberately, so the pass never reaches past jj's own objects into
unreachable objects of yours.

`jj-ci doctor` reports the count, among the rest.

## Mixed teams

`.jj-ci.toml` is versioned and says nothing about which VCS you use, which is
the point. The jj user gets `jj push`; the git user gets the hooks; CI runs the
same file through the GitHub action. Whoever is reviewing the policy reviews
one file.

Detection follows the repository: a `.jj` directory means jj, otherwise `.git`
means git. In a colocated repository jj wins. Pass `--vcs git` or `--vcs jj`,
or set `JJ_CI_VCS`, to say so yourself — useful mainly for trying the other
path from a colocated repository.
