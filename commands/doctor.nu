const LIB = path self "../lib"
use $"($LIB)/log.nu" *
use $"($LIB)/jj.nu"
use $"($LIB)/git.nu"
use $"($LIB)/vcs.nu"
use $"($LIB)/config.nu"
use $"($LIB)/render.nu"
use $"($LIB)/detect.nu"

const HOOKS = ["pre-push" "commit-msg"]

export def invoke [bin: string, backend: string]: nothing -> int {
  title "environment"
  line "jj" (jj version)
  line "nushell" $"nu (version | get version)"
  line "jj-ci" $bin
  line "on PATH" (if (which jj-ci | is-not-empty) { "yes" } else { "no — aliases need the absolute path" })

  let repo = (try { vcs detect $backend } catch { null })
  if $repo == null {
    print ""
    warn "not inside a jj or git repository — run this again from one to check its policy"
    return 0
  }

  print ""
  title "repository"
  line "root" $repo.root
  line "driven with" $repo.backend

  if $repo.backend == "jj" {
    line "alias jj ci" (alias-of "ci")
    line "alias jj push" (alias-of "push")
    line "colocated" (
      if (($repo.root | path join ".git") | path exists) { "yes" } else {
        "no — a git-based hook runner (pre-commit, lefthook, hk) cannot run here"
      }
    )
  } else {
    line "jj repository" $repo.jj_root
    line "refs left" (refs-note $repo.root)
    for name in $HOOKS { line $"hook ($name)" (hook-state $repo $name) }
  }

  let file = (config find $repo.root)
  if $file == null {
    line "policy" (
      if $repo.backend == "jj" {
        "none — `jj push` here behaves exactly like `jj git push`"
      } else {
        "none — the hooks let every push and every message through"
      }
    )
    let found = (detect probe $repo.root)
    if $found != null {
      info $"($found.marker) is present; `jj-ci init --detect` would wire ($found.name) up"
    }
    return 0
  }

  let cfg = (try { config load $repo.root } catch { |e|
    line "policy" $"($file) — (ansi red)invalid(ansi reset)"
    print ($e.msg)
    return 1
  })

  line "policy" $file
  line "checks" (
    $cfg.checks
    | group-by { |c| $c.stages | str join "+" }
    | transpose stage items
    | each { |r| $"($r.stage): ($r.items | get name | str join ', ')" }
    | str join "; "
  )
  line "formatters" (
    if ($cfg.format | columns | is-empty) {
      "none"
    } else if $repo.backend == "git" {
      ($cfg.format | columns | str join ", ") + " — declared, but --fix needs jj"
    } else {
      $cfg.format | columns | str join ", "
    }
  )
  line "bootstrap" (
    if $cfg.bootstrap == null { "none" } else { $cfg.bootstrap.command | str join " " }
  )

  cd $repo.jj_root
  let rendered = (try { render ensure $cfg; "in sync" } catch { |e| $e.msg })
  line "repo config" $rendered

  let missing = (
    $cfg.checks
    | each { |c| $c.requires | where { |b| which $b | is-empty } }
    | flatten
    | uniq
  )
  line "missing tools" (if ($missing | is-empty) { "none" } else { $missing | str join ", " })
  0
}

def hook-state [repo: record, name: string]: nothing -> string {
  let path = (git hooks-dir $repo.root $repo.git_dir | path join $name)
  if not ($path | path exists) { return "not installed — run `jj-ci install`" }

  let body = (open --raw $path)
  if not ($body | str contains "jj-ci") { return $"($path) — written by something else" }

  # The hook holds the absolute paths it was installed with, and a nix rebuild
  # moves them. It falls back to PATH, so a stale one still works in a
  # terminal and fails in a GUI client, which is the confusing half.
  let stale = (
    $body
    | lines
    | parse --regex "^(?:nu|entry)='(?<path>.*)'$"
    | get path
    | where { |p| not ($p | path exists) }
  )
  if ($stale | is-empty) {
    $path
  } else {
    $"($path) — points at ($stale | str join ', '), which has moved; run `jj-ci install`"
  }
}

def refs-note [root: string]: nothing -> string {
  $"(git keep-refs $root) under refs/jj/ — jj pins what it imports, and jj-ci tidies them as they build up"
}

def alias-of [name: string]: nothing -> string {
  let r = (^jj config list $"aliases.($name)" | complete)
  if $r.exit_code != 0 or ($r.stdout | str trim | is-empty) {
    "not installed — run `jj-ci install`"
  } else {
    $r.stdout | str trim | str replace --regex '^[^=]*=\s*' ''
  }
}

def line [key: string, value: string] {
  print $"  ($key | fill -a l -w 15) ($value)"
}
