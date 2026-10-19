# A git repository gets a jj repository of its own, kept inside .git where
# neither the working tree nor `git status` will ever show it. Everything below
# this layer — jj run, filesets, the cache — then works unchanged, because what
# it is looking at is a jj repository like any other.

use log.nu [info]

# Past this many, the refs jj leaves in the git repository are tidied.
const KEEP_REF_LIMIT = 100
const ZERO = '^0{40,64}$'
const ZERO_SHA = "0000000000000000000000000000000000000000"

# jj imports refs/heads, refs/tags and refs/remotes and nothing else, so a
# commit that has to reach it arrives as a branch, for as long as that takes.
const WORKTREE_REF = "refs/heads/jj-ci-worktree"

export def root []: nothing -> string {
  let r = (^git rev-parse --show-toplevel | complete)
  if $r.exit_code != 0 { error make { msg: "not inside a git repository" } }
  $r.stdout | str trim
}

# Every worktree of one repository shares a single shadow: --git-common-dir
# resolves to the main .git from inside any of them.
export def common-dir []: nothing -> string {
  let r = (^git rev-parse --path-format=absolute --git-common-dir | complete)
  if $r.exit_code != 0 { error make { msg: "not inside a git repository" } }
  $r.stdout | str trim
}

export def shadow-path [common_dir: string]: nothing -> string {
  $common_dir | path join "jj-ci" "shadow"
}

export def ensure-shadow [common_dir: string, root: string]: nothing -> string {
  let shadow = (shadow-path $common_dir)
  if ($shadow | path join ".jj" | path exists) { return $shadow }

  # jj creates the destination, but not the directory above it.
  mkdir $shadow
  let r = (with-env (identity $root) { ^jj git init $shadow --git-repo $common_dir | complete })
  if $r.exit_code != 0 {
    rm -rf ($shadow | path join ".jj")
    error make {
      msg: $"could not create the jj repository jj-ci keeps for this git repository:\n($r.stderr | str trim)"
    }
  }

  # Nothing reads the files of this working copy: checks run either in the
  # copies jj run makes or in the git working tree. Emptying it keeps the whole
  # thing to a few hundred kilobytes of metadata.
  let s = (with-env (identity $root) { ^jj -R $shadow sparse set --clear | complete })
  if $s.exit_code != 0 {
    rm -rf ($shadow | path join ".jj")
    error make { msg: $"could not empty the working copy of ($shadow):\n($s.stderr | str trim)" }
  }

  info $"prepared ($shadow)"
  $shadow
}

# jj reads the git repository's refs once; commits git has made since are
# invisible until it is asked again.
export def import [shadow: string, root: string]: nothing -> nothing {
  let r = (with-env (identity $root) { ^jj -R $shadow --quiet git import | complete })
  if $r.exit_code != 0 {
    error make { msg: $"could not read this repository's git refs:\n($r.stderr | str trim)" }
  }
}

export def keep-refs [root: string]: nothing -> int {
  let r = (^git -C $root for-each-ref --format '%(refname)' 'refs/jj/**' | complete)
  if $r.exit_code != 0 { return 0 }
  $r.stdout | lines | where { |l| ($l | str trim) != "" } | length
}

# jj pins every commit it imports with a ref under refs/jj/, and the operation
# log holds the only other reference to them. That log is the undo history of a
# repository nobody drives by hand, so abandoning it is what makes the refs
# collectable. The default expiry stays: `--expire=now` would reach past jj's
# own objects into the git repository's unreachable ones.
export def maybe-gc [shadow: string, root: string]: nothing -> nothing {
  if (keep-refs $root) < $KEEP_REF_LIMIT { return }
  info "tidying the refs jj-ci has left in this repository"
  with-env (identity $root) {
    ^jj -R $shadow --quiet op abandon ..@- | complete | ignore
    ^jj -R $shadow --quiet util gc | complete | ignore
  }
}

export def head [root: string]: nothing -> string {
  let r = (^git -C $root rev-parse HEAD | complete)
  if $r.exit_code != 0 { "" } else { $r.stdout | str trim }
}

# core.hooksPath may be absolute, or relative to the working tree root, which
# is where git runs a hook from.
export def hooks-dir [root: string, git_dir: string]: nothing -> string {
  let r = (^git -C $root config --get core.hooksPath | complete)
  let configured = ($r.stdout | str trim)
  if $r.exit_code != 0 or ($configured | is-empty) {
    $git_dir | path join "hooks"
  } else if ($configured | str starts-with "/") {
    $configured
  } else {
    $root | path join $configured
  }
}

# The working tree is not a commit, so nothing in jj can match a fileset
# against it. This makes one: a scratch index filled from the working tree —
# `git add` honours .gitignore, so what lands in it is what a commit would
# contain — written out as a tree and committed onto HEAD. The real index, the
# working tree and every branch are left exactly as they were.
export def worktree-commit [shadow: string, root: string, git_dir: string]: nothing -> string {
  let head = (head $root)
  if ($head | is-empty) {
    error make --unspanned {
      msg: "this git repository has no commits yet, so there is no working tree to describe"
    }
  }

  let index = ($git_dir | path join "jj-ci" "index")
  mkdir ($index | path dirname)
  rm -f $index

  let name = (git-config $root "user.name" "jj-ci")
  let email = (git-config $root "user.email" "jj-ci@localhost")
  let commit = (with-env {
    GIT_INDEX_FILE: $index
    GIT_AUTHOR_NAME: $name, GIT_AUTHOR_EMAIL: $email
    GIT_COMMITTER_NAME: $name, GIT_COMMITTER_EMAIL: $email
  } {
    plumb $root [read-tree $head] "read HEAD into a scratch index"
    plumb $root [add --all] "stage the working tree into a scratch index"
    let tree = (plumb $root [write-tree] "write a tree for the working tree")
    plumb $root [commit-tree $tree -p $head -m "jj-ci: the working tree"] "commit the working tree"
  })
  rm -f $index

  # The branch exists only for the length of that import. Deleting it in either
  # outcome keeps a failed run from leaving a branch in `git branch`; jj holds
  # the commit itself through a ref of its own from here on.
  ^git -C $root update-ref $WORKTREE_REF $commit | complete | ignore
  let imported = (try { import $shadow $root; null } catch { |e| $e })
  ^git -C $root update-ref -d $WORKTREE_REF | complete | ignore
  if $imported != null { error make --unspanned { msg: $imported.msg } }

  $commit
}

# The hook contract: one line per ref, `<local ref> <local sha> <remote ref>
# <remote sha>`. A ref the remote does not have yet comes with an all-zeroes
# remote sha, and a deletion arrives with the literal `delete` as its local ref.
export def push-input [text: string, root: string]: nothing -> record {
  let rows = (
    $text
    | lines
    | where { |l| ($l | str trim) != "" }
    | each { |l| $l | str trim | split row --regex '\s+' }
    | where { |f| ($f | length) >= 4 }
    | each { |f|
        { local_ref: ($f | get 0), local: ($f | get 1), remote_ref: ($f | get 2), remote: ($f | get 3) }
      }
  )
  let deletes = ($rows | where { |r| $r.local_ref == "delete" or ($r.local =~ $ZERO) })
  let sending = ($rows | where { |r| $r.local_ref != "delete" and not ($r.local =~ $ZERO) })
  {
    targets: (
      $sending
      | each { |r|
          $r
          | update local (peel $root $r.local)
          | update remote (peel $root $r.remote | default-to $ZERO_SHA)
        }
      # A tag of a tag, or an object this clone does not have: either way
      # there is no commit here to check.
      | where { |r| $r.local != "" }
    )
    deletes: ($deletes | get remote_ref)
  }
}

export def is-zero [sha: string]: nothing -> bool {
  ($sha | is-empty) or ($sha =~ $ZERO)
}

# `git push` names whatever object the ref holds, and an annotated tag holds a
# tag object, which is not a revision jj can be asked about. ^{commit} is what
# git calls following it to the commit underneath.
def peel [root: string, sha: string]: nothing -> string {
  if (is-zero $sha) { return "" }
  let r = (^git -C $root rev-parse --verify --quiet ($sha + "^{commit}") | complete)
  if $r.exit_code != 0 { "" } else { $r.stdout | str trim }
}

def default-to [fallback: string]: string -> string {
  if ($in | is-empty) { $fallback } else { $in }
}

def plumb [root: string, args: list<string>, what: string]: nothing -> string {
  let r = (^git -C $root ...$args | complete)
  if $r.exit_code != 0 {
    error make --unspanned { msg: $"could not ($what):\n($r.stderr | str trim)" }
  }
  $r.stdout | str trim
}

# jj does not refuse to work without an identity, but it warns on every
# command, and that warning would surface in the middle of someone's git push.
def identity [root: string]: nothing -> record {
  {
    JJ_USER: (git-config $root "user.name" "jj-ci")
    JJ_EMAIL: (git-config $root "user.email" "jj-ci@localhost")
  }
}

def git-config [root: string, key: string, fallback: string]: nothing -> string {
  let r = (^git -C $root config --get $key | complete)
  let value = ($r.stdout | str trim)
  if $r.exit_code != 0 or ($value | is-empty) { $fallback } else { $value }
}
