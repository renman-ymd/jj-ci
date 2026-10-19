# Both templates start on the line after their opening delimiter: a nushell raw
# string cannot begin with `#` directly after `r#'`. The leading newline is
# trimmed before the file is written.

const LIB = path self "../lib"
use $"($LIB)/log.nu" *
use $"($LIB)/vcs.nu"
use $"($LIB)/detect.nu"

const RUNNER_TEMPLATE = r#'
# jj-ci policy for this repository.
#
# Wired to @NAME@, detected from @MARKER@.
#
# workspace = true because @NAME@ is built on git: it wants a repository and an
# index, and the copy `jj run` checks out is a plain directory with neither. So
# this check looks at your working copy rather than at the revision being
# published. Declaring the underlying tools directly (see the examples that
# ship with jj-ci) is what gets you the revision-accurate version.

[jj-ci]
version = 1

[checks.@NAME@]
command = [@COMMAND@]
workspace = true
requires = ["@BIN@"]
pass-files = @PASSFILES@
'#

const SKELETON = r#'
# jj-ci policy for this repository.
#
# Checks run when you publish: `jj push` runs the "push" stage over what would
# reach the remote, and `jj ci` runs the "ci" stage on demand. A check is just
# a command; jj-ci decides which revisions to run it on and gets out of the way.
#
# Full key reference: the README that ships with jj-ci.

[jj-ci]
version = 1

# Named filesets, rendered into jj so that `jj fix`, the checks below, and
# anything you type yourself (`jj diff -r @ SOURCES`) all mean the same thing.
# Prefer root-glob: over glob:, which is relative to the directory you happen
# to be standing in.
[filesets]
SOURCES = 'root-glob:"src/**/*" ~ root-glob:"**/node_modules/**"'

# The copy jj run checks out has no gitignored state: no node_modules, no
# target/, no .venv. It is reused between runs, so this is paid once per
# fingerprint change rather than once per check.
# [bootstrap]
# command = ["make", "deps"]
# fingerprint = ["lockfile"]

# The write half, rendered into jj fix.tools: `jj fix` then formats every
# mutable revision with it.
# [format.myformatter]
# command = ["myformatter", "--stdin", "--path=$path"]
# patterns = ["SOURCES"]

[checks.build]
command = ["make", "build"]
# stages = ["push"]        # push (the gate) | ci (jj ci) | any name you invent
# scope = "tip"            # tip: the commit being published | each: every one
# paths = ["SOURCES"]      # skip the check when nothing matching changed…
# pass-files = true        # …and append the matching paths to the command
# requires = ["make"]      # skip when a tool is not on PATH
# skip-if = ["sh", "-c", "test -z \"$CI\""]
# skip-reason = "only outside CI"
# cache = true             # remember that this commit passed this check
# workspace = true         # run in the real working copy, not an isolated one

# A description belongs to one commit, so this runs on every published one.
# [checks.message]
# command = ["my-commit-lint"]
# input = "description"    # the description arrives on stdin, no checkout
'#

export def invoke [detect_runner: bool, force: bool, backend: string]: nothing -> int {
  let root = (vcs workspace-root $backend)
  let dest = ($root | path join ".jj-ci.toml")

  if ($dest | path exists) and (not $force) {
    err $"($dest) already exists — pass --force to replace it"
    return 1
  }

  let found = (if $detect_runner { detect probe $root } else { null })
  let body = (if $found != null { runner-template $found } else { $SKELETON })
  ($body | str trim --left) + "\n" | save --force --raw $dest

  print $"(ansi green)✓(ansi reset) wrote ($dest)"
  if $found != null {
    info $"wired to ($found.name), detected from ($found.marker)"
  }
  if (vcs backend $backend) == "jj" {
    info "edit it, then run `jj ci` to try it, or `jj push` to gate a publish"
  } else {
    info "edit it, then run `jj-ci ci` to try it, and `jj-ci install` to gate `git push`"
  }
  0
}

def runner-template [found: record]: nothing -> string {
  $RUNNER_TEMPLATE
  | str replace --all "@NAME@" $found.name
  | str replace --all "@MARKER@" $found.marker
  | str replace --all "@BIN@" $found.bin
  | str replace --all "@COMMAND@" ($found.command | each { |a| $'"($a)"' } | str join ", ")
  | str replace --all "@PASSFILES@" (if $found.pass-files { "true" } else { "false" })
}
