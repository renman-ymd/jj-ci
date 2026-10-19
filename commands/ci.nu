const LIB = path self "../lib"

use $"($LIB)/log.nu" *
use $"($LIB)/jj.nu"
use $"($LIB)/vcs.nu"
use $"($LIB)/config.nu"
use $"($LIB)/render.nu"
use $"($LIB)/runner.nu"

export def invoke [
  self_cmd: list<string>
  backend: string # "jj", "git", or "" to work it out
  stage: string
  revisions: any # revset, or null for the default
  here: bool
  fix: bool
  no_cache: bool
  only: list<string>
  verbose: bool
  jobs: int
  strict: bool
]: nothing -> int {
  let repo = (vcs detect $backend)
  cd $repo.jj_root
  vcs sync $repo

  let file = (config find $repo.root)
  if $file == null {
    err $"no .jj-ci.toml in ($repo.root) — run `jj-ci init` to create one"
    return 1
  }
  let cfg = (config load $repo.root)
  render ensure $cfg

  let revset = (
    if $here {
      vcs here-revset $repo
    } else if $revisions != null {
      $revisions
    } else {
      vcs default-revset $repo
    }
  )

  # Before resolving revisions: jj fix rewrites the commits it touches.
  if $fix and ($cfg.format | columns | is-not-empty) {
    vcs require-fix $repo
    title "jj fix"
    if not (jj fix $revset) { return 1 }
  }

  let revs = (jj revisions $revset)
  if ($revs | is-empty) {
    if $strict {
      err $"strict: no revisions in ($revset)"
      return 1
    }
    warn $"no revisions in ($revset)"
    return 0
  }

  let tips = (if $here { [($revs | last | get commit)] } else {
    jj revisions $"heads\(($revset))" | get commit
  })

  title $"($stage): ((plural ($revs | length) 'revision')) in (label $repo $here $revset)"
  runner execute $repo $cfg $stage $revs $tips $revset $self_cmd {
    no_cache: $no_cache, only: $only, verbose: $verbose, here: $here, jobs: $jobs
    strict: $strict
  }
}

# Under git, --here names a commit built for the occasion, and printing its id
# would say nothing about where it came from.
def label [repo: record, here: bool, revset: string]: nothing -> string {
  if $here and $repo.backend == "git" { "the working tree" } else { $revset }
}
