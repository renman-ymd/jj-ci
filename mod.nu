#!/usr/bin/env nu

# Reached through the bin/jj-ci symlink, a bare `path self` reports the
# symlink's own directory, and every `use` below would look for bin/lib.
const ROOT = (path self | path expand | path dirname)
const SELF = (path self | path expand)

use $"($ROOT)/commands"
use $"($ROOT)/lib/log.nu" [err]
use $"($ROOT)/lib/runner.nu"

def self-cmd []: nothing -> list<string> {
  [$nu.current-exe "--no-config-file" $SELF]
}

const VERDICT = "jj-ci: "

# Interactively, returning an exit code would print a stray `0`.
def raise [code: int, msg: string]: nothing -> nothing {
  if $code != 0 { error make --unspanned { msg: ($VERDICT + $msg) } }
}

# Run as a script, a raised error has nowhere to surface: nushell renders one
# only for the module commands. Without this, a refusal — or a git hook that
# could not read the repository — would be an exit code and nothing else. A
# run that merely ended in a red verdict has already said so itself.
def fail [e: record]: nothing -> nothing {
  let msg = ($e | get -o msg | default "")
  if not ($msg | str starts-with $VERDICT) { err (if ($msg | is-empty) { "failed" } else { $msg }) }
  exit 1
}

# Run a stage of this repository's checks over a revset.
export def ci [
  --stage (-s): string = "push" # stage to run: push, ci, or any name the repo invents
  --revisions (-r): string # revset to check (default: the unpushed commits)
  --here # check the working copy as it is, instead of isolated checkouts
  --fix # run jj fix over the same revisions first
  --no-cache # ignore remembered green results
  --only: string = "" # run only these checks (comma-separated)
  --jobs (-j): int = 1 # revisions to check in parallel; above 1, output is captured
  --verbose # stream each check's output instead of showing it only on failure
  --strict # a check that cannot run here fails instead of being skipped
  --vcs: string = "" # force jj or git, instead of reading the repository
]: nothing -> nothing {
  raise (
    commands ci invoke (self-cmd) $vcs $stage $revisions $here $fix $no_cache (
      $only | split row "," | where { |s| ($s | str trim) != "" }
    ) $verbose $jobs $strict
  ) "checks failed"
}

# Checks a stage would run here, without running any of them.
export def checks [
  stage: string = "push" # stage to list
  --json # one line of JSON, for a CI matrix
  --vcs: string = "" # force jj or git, instead of reading the repository
]: nothing -> any {
  let rows = (commands checks invoke $stage $vcs)
  if $json { $rows | to json --raw } else { $rows }
}

# Run the push stage over what would be published, then `jj git push`.
export def --wrapped push [...rest: string]: nothing -> nothing {
  if ("--help" in $rest) or ("-h" in $rest) {
    print (push-help)
    return
  }
  raise (commands push invoke (self-cmd) $rest) "push aborted"
}

# Write a starting .jj-ci.toml in this repository.
export def init [
  --detect # start from a hook runner already configured here
  --force # overwrite an existing file
  --vcs: string = "" # force jj or git, instead of reading the repository
]: nothing -> nothing {
  raise (commands init invoke $detect $force $vcs) "nothing written"
}

# Wire jj-ci in: the two jj aliases, or the git hooks, whichever this is.
export def install [
  --format: string = "both" # toml, nix, or both; jj only
  --on-path # emit the bare name, for when jj-ci is on PATH; jj only
  --write # write them with `jj config set --user` instead of printing; jj only
  --vcs: string = "" # force jj or git, instead of reading the repository
]: nothing -> nothing {
  raise (
    commands install invoke ($ROOT | path join "bin" "jj-ci") (self-cmd) $format $on_path $write $vcs
  ) "not installed"
}

# Shell completions for the jj aliases. Nushell only — see --help.
export def completions [
  shell: string = "nushell" # nushell
  --ci-alias: string = "ci" # name you gave the ci alias
  --push-alias: string = "push" # name you gave the push alias
]: nothing -> string {
  commands completions invoke $shell $ci_alias $push_alias
}

# Report what jj-ci can and cannot do in this repository.
export def doctor [
  --vcs: string = "" # force jj or git, instead of reading the repository
]: nothing -> nothing {
  raise (
    commands doctor invoke ($ROOT | path join "bin" "jj-ci") $vcs
  ) "this repository has a problem"
}

# Run a git hook. `jj-ci install` writes these into .git/hooks; the pre-push
# one is fed the refs git is about to send, on stdin.
export def "hook pre-push" []: nothing -> nothing {
  raise (commands hook pre-push (self-cmd) (stdin-text)) "push aborted"
}

export def "hook commit-msg" [
  file: string # the file holding the proposed message
]: nothing -> nothing {
  raise (commands hook commit-msg $file) "commit aborted"
}

# A `main` subcommand is handed nothing in `$in`, whatever is piped at it.
def stdin-text []: nothing -> string {
  try { open --raw /dev/stdin } catch { "" }
}

export def main []: nothing -> nothing {
  print $"jj-ci — local checks for jj and git repositories

  (ansi cyan)jj ci(ansi reset) [--stage S] [-r REVSET] [--here] [--fix]    run a stage
  (ansi cyan)jj push(ansi reset) [jj git push args…] [--no-verify]        gate, then publish

In a git repository the gate is the pre-push hook instead, and `jj-ci ci` is
how you run a stage by hand.

  (ansi cyan)jj-ci checks(ansi reset) [stage] [--json]          list a stage without running it
  (ansi cyan)jj-ci init(ansi reset) [--detect]                 write a .jj-ci.toml here
  (ansi cyan)jj-ci install(ansi reset)                         the jj aliases, or the git hooks
  (ansi cyan)jj-ci completions(ansi reset) nushell             completions for those aliases
  (ansi cyan)jj-ci doctor(ansi reset)                          what works here, what does not

Add --help to any of them. Policy lives in .jj-ci.toml, at the repository root,
and is the same file whichever of the two you drive. In nushell, `use ($ROOT)`
gives the same commands with native help."
}

def push-help []: nothing -> string {
  $"jj push [jj git push arguments…]

Runs the push stage over exactly what `jj git push` would publish, then
publishes it. Unknown arguments go to jj untouched.

  --no-verify     publish without running anything
  --no-tug        do not move the nearest bookmark forward
  --fix           run jj fix over the published range first
  --stage S       run a stage other than push
  --only NAME     run only this check \(repeatable)
  --no-cache      ignore remembered green results
  --jobs N        check N revisions in parallel
  --verbose       stream each check's output
  --dry-run       forwarded to jj; asks what would be pushed and runs nothing"
}

# Unexported on purpose: exporting them would put `jj-ci main ci` in the
# module's namespace, and a script dispatches `main <sub>` either way.

def "main ci" [
  --stage (-s): string = "push"
  --revisions (-r): string
  --here
  --fix
  --no-cache
  --only: string = ""
  --jobs (-j): int = 1
  --verbose
  --strict
  --vcs: string = ""
]: nothing -> nothing {
  try {
    (ci --stage $stage --revisions $revisions --here=$here --fix=$fix
        --no-cache=$no_cache --only $only --jobs $jobs --verbose=$verbose
        --strict=$strict --vcs $vcs)
  } catch { |e| fail $e }
}

def "main checks" [stage: string = "push", --json, --vcs: string = ""]: nothing -> nothing {
  try { print (checks $stage --json=$json --vcs $vcs) } catch { |e| fail $e }
}

def --wrapped "main push" [...rest: string]: nothing -> nothing {
  try { push ...$rest } catch { |e| fail $e }
}

def "main init" [--detect, --force, --vcs: string = ""]: nothing -> nothing {
  try { init --detect=$detect --force=$force --vcs $vcs } catch { |e| fail $e }
}

def "main install" [
  --format: string = "both"
  --on-path
  --write
  --vcs: string = ""
]: nothing -> nothing {
  try { install --format $format --on-path=$on_path --write=$write --vcs $vcs } catch { |e| fail $e }
}

def "main hook pre-push" []: nothing -> nothing {
  try { hook pre-push } catch { |e| fail $e }
}

def "main hook commit-msg" [file: string]: nothing -> nothing {
  try { hook commit-msg $file } catch { |e| fail $e }
}

def "main completions" [
  shell: string = "nushell"
  --ci-alias: string = "ci"
  --push-alias: string = "push"
]: nothing -> nothing {
  try { completions $shell --ci-alias $ci_alias --push-alias $push_alias } catch { |e| fail $e }
}

def "main doctor" [--vcs: string = ""]: nothing -> nothing {
  try { doctor --vcs $vcs } catch { |e| fail $e }
}

def "main __revision" []: nothing -> nothing {
  if ($env | get -o JJ_CI_PLAN) == null {
    err "__revision is run by jj-ci itself, inside jj run"
    exit 2
  }
  exit (runner revision)
}
