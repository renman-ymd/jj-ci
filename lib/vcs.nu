# Which version control system the user drives, and the two roots that follow
# from it.
#
# Under jj the two are one path. Under git they differ: `.jj-ci.toml` and
# anything running with `workspace = true` belong to the git working tree,
# while every jj command runs in the repository jj-ci keeps inside .git. Once a
# command holds this record, nothing below it has to know which is which.

use jj.nu
use git.nu

export def detect [override: string = ""]: nothing -> record {
  if (choose $override) == "jj" { jj-repo } else { git-repo }
}

# Where .jj-ci.toml lives, for the commands that only read it. Deliberately
# stops short of preparing the git-side repository: listing a policy, or
# writing one, should not create anything else.
export def workspace-root [override: string = ""]: nothing -> string {
  if (choose $override) == "jj" { jj root } else { git root }
}

export def backend [override: string = ""]: nothing -> string {
  choose $override
}

# What a command has to do before it can trust what jj reports.
export def sync [repo: record]: nothing -> nothing {
  if $repo.backend == "git" {
    git import $repo.jj_root $repo.root
    git maybe-gc $repo.jj_root $repo.root
  } else {
    jj snapshot
  }
}

# Unpushed work, in both cases.
export def default-revset [repo: record]: nothing -> string {
  if $repo.backend == "jj" { return "reachable(@, mutable())" }

  let head = (git head $repo.root)
  if ($head | is-empty) {
    error make --unspanned { msg: "this git repository has no commits yet" }
  }
  "(remote_bookmarks().." + $head + ") ~ root()"
}

# `jj fix` rewrites the commits it formats. Under git the rewritten ones would
# exist only in jj-ci's own repository: no branch would move, the working tree
# would not change, and the next run would format the originals over again.
export def require-fix [repo: record]: nothing -> nothing {
  if $repo.backend == "git" {
    error make --unspanned {
      msg: ("--fix rewrites the commits it formats, and a rewrite made here would be invisible to git: "
        + "no branch would move and the work would be lost.\n"
        + "Run your formatters yourself, or drive this repository with jj.")
    }
  }
}

# The revision standing for the working copy, which git alone cannot name.
export def here-revset [repo: record]: nothing -> string {
  if $repo.backend == "jj" {
    "@"
  } else {
    git worktree-commit $repo.jj_root $repo.root $repo.git_dir
  }
}

# What the remote is about to receive, per ref git named on the hook's stdin. A
# ref the remote does not have yet carries no `before` to subtract, and neither
# does one whose `before` this repository has never fetched, so in both cases
# everything already published stands in for it.
export def push-revset [targets: table]: nothing -> string {
  let parts = ($targets | each { |t|
    if (git is-zero $t.remote) or ((jj resolve $t.remote) | is-empty) {
      "remote_bookmarks().." + $t.local
    } else {
      $t.remote + ".." + $t.local
    }
  })
  "(" + ($parts | str join " | ") + ") ~ root()"
}

def choose [override: string]: nothing -> string {
  let want = (
    if ($override | is-not-empty) { $override } else { $env | get -o JJ_CI_VCS | default "" }
  )
  if $want not-in ["" "jj" "git"] {
    error make --unspanned { msg: $"unknown vcs ($want): expected jj or git" }
  }
  if $want != "" { return $want }

  let found = (try { jj root } catch { null })
  if $found != null and not (inside-git-dir $found) { "jj" } else { "git" }
}

def jj-repo []: nothing -> record {
  let root = (jj root)
  { backend: "jj", root: $root, jj_root: $root, git_dir: "" }
}

def git-repo []: nothing -> record {
  let root = (git root)
  let git_dir = (git common-dir)
  { backend: "git", root: $root, git_dir: $git_dir, jj_root: (git ensure-shadow $git_dir $root) }
}

# jj-ci's own repository lives under .git, so standing inside it must not look
# like a jj repository the user asked about.
def inside-git-dir [p: string]: nothing -> bool {
  ".git" in ($p | path split)
}
