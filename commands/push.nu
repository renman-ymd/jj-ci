const LIB = path self "../lib"

use $"($LIB)/log.nu" *
use $"($LIB)/jj.nu"
use $"($LIB)/vcs.nu"
use $"($LIB)/config.nu"
use $"($LIB)/render.nu"
use $"($LIB)/runner.nu"

const OWN_FLAGS = [--no-verify --no-tug --fix --no-cache --verbose]
const OWN_VALUE_FLAGS = [--stage --only --jobs]

export def invoke [self_cmd: list<string>, rest: list<string>]: nothing -> int {
  let args = (split-args $rest)
  let repo = (vcs detect "")

  # git publishes through its own command, and gates it with the hook jj-ci
  # installs; there is no `jj git push` here to wrap.
  if $repo.backend == "git" {
    err "this is a git repository — push with `git push`, which the pre-push hook gates"
    info "run `jj-ci install` if that hook is not in place yet"
    return 1
  }

  cd $repo.root
  jj snapshot

  # A dry run is a question, not a publication.
  if "--dry-run" in $args.passthru {
    return (push-now $args.passthru)
  }

  if not $args.own.no_tug { jj tug }

  let file = (config find $repo.root)
  if $file == null {
    return (push-now $args.passthru)
  }

  if $args.own.no_verify {
    warn "checks skipped (--no-verify)"
    return (push-now $args.passthru)
  }

  let cfg = (config load $repo.root)
  render ensure $cfg

  # Before the dry run: rewriting moves the bookmarks. The revset is jj fix's
  # own default, the published range not being known yet.
  if $args.own.fix and ($cfg.format | columns | is-not-empty) {
    title "jj fix"
    if not (jj fix "reachable(@, mutable())") { return 1 }
  }

  let targets = (jj push-targets $args.passthru)
  if not $targets.parsed {
    warn "could not read `jj git push --dry-run`; checking everything unpushed instead"
    print $targets.raw
  }

  let tips = (if $targets.parsed {
    $targets.targets | get commit
  } else {
    jj revisions "heads(remote_bookmarks()..@)" | get commit
  })

  if ($tips | is-empty) {
    if ($targets.deletes | is-not-empty) {
      info $"nothing to check: deleting ($targets.deletes | str join ', ')"
    } else {
      print $targets.raw
    }
    return (push-now $args.passthru)
  }

  # ~root(): with nothing on the remote yet, `remote_bookmarks()..x` reduces to
  # `::x`, which includes jj's virtual root commit.
  let revset = $"remote_bookmarks\(\)..\(($tips | str join ' | ')) ~ root\(\)"
  let revs = (jj revisions $revset)
  if ($revs | is-empty) {
    return (push-now $args.passthru)
  }

  let label = (
    if $targets.parsed { $targets.targets | each { |t| $t.bookmark } | str join ", " } else { "unpushed" }
  )
  title $"($label) — ((plural ($revs | length) 'revision')), stage ($args.own.stage)"

  let code = (runner execute $repo $cfg $args.own.stage $revs $tips $revset $self_cmd {
    no_cache: $args.own.no_cache, only: $args.own.only, verbose: $args.own.verbose,
    here: false, jobs: $args.own.jobs, strict: false
  })
  if $code != 0 {
    print $"(ansi dark_gray)push aborted — publish anyway with `jj push --no-verify`(ansi reset)"
    return $code
  }

  print ""
  push-now $args.passthru
}

def push-now [args: list<string>]: nothing -> int {
  let r = (^jj git push ...$args | complete)
  print (($r.stdout + $r.stderr) | str trim)
  $r.exit_code
}

# jj-ci's own flags are pulled out; everything else is `jj git push`'s.
def split-args [rest: list<string>]: nothing -> record {
  mut own = {
    no_verify: false, no_tug: false, fix: false, no_cache: false,
    verbose: false, stage: "push", only: [], jobs: 1
  }
  mut passthru = []
  mut i = 0
  let n = ($rest | length)

  while $i < $n {
    let a = ($rest | get $i)
    if $a in $OWN_FLAGS {
      $own = (match $a {
        "--no-verify" => ($own | update no_verify true)
        "--no-tug" => ($own | update no_tug true)
        "--fix" => ($own | update fix true)
        "--no-cache" => ($own | update no_cache true)
        _ => ($own | update verbose true)
      })
    } else if $a in $OWN_VALUE_FLAGS {
      let v = ($rest | get -o ($i + 1) | default "")
      $own = (match $a {
        "--stage" => ($own | update stage $v)
        "--only" => (
          $own | update only (
            $own.only | append ($v | split row "," | where { |s| ($s | str trim) != "" })
          )
        )
        _ => ($own | update jobs ([($v | into int) 1] | math max))
      })
      $i = $i + 1
    } else {
      $passthru = ($passthru | append $a)
    }
    $i = $i + 1
  }

  { own: $own, passthru: $passthru }
}
