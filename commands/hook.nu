# The two moments git offers that jj does not: a publication, which is the
# same gate `jj push` is, and a message about to be written, which is the only
# chance to catch it while `git commit --amend` is still a one-liner.

const LIB = path self "../lib"

use $"($LIB)/log.nu" *
use $"($LIB)/jj.nu"
use $"($LIB)/git.nu"
use $"($LIB)/vcs.nu"
use $"($LIB)/config.nu"
use $"($LIB)/render.nu"
use $"($LIB)/runner.nu"
use $"($LIB)/plan.nu"
use $"($LIB)/exec.nu"

export def pre-push [self_cmd: list<string>, stdin_text: string]: nothing -> int {
  # Before anything is prepared: a branch without a policy is one jj-ci has
  # nothing to say about, and it should cost nothing to push.
  let root = (vcs workspace-root "git")
  if (config find $root) == null { return 0 }

  let repo = (vcs detect "git")
  cd $repo.jj_root
  vcs sync $repo

  let input = (git push-input $stdin_text $repo.root)
  if ($input.targets | is-empty) {
    if ($input.deletes | is-not-empty) {
      info $"nothing to check: deleting ($input.deletes | each { |r| short $r } | str join ', ')"
    }
    return 0
  }

  let revset = (vcs push-revset $input.targets)
  let revs = (jj revisions $revset)
  if ($revs | is-empty) { return 0 }

  let cfg = (config load $repo.root)
  render ensure $cfg

  let label = ($input.targets | each { |t| short $t.remote_ref } | str join ", ")
  title $"($label) — ((plural ($revs | length) 'revision')), stage push"

  let tips = (jj revisions $"heads\(($revset))" | get commit)
  let code = (runner execute $repo $cfg "push" $revs $tips $revset $self_cmd {
    no_cache: false, only: [], verbose: false, here: false, jobs: 1, strict: false
  })
  if $code != 0 {
    print $"(ansi dark_gray)push aborted — publish anyway with `git push --no-verify`(ansi reset)"
  }
  $code
}

# Every description check runs here, whatever stage it belongs to: this hook
# exists for exactly the thing they read, and it is the only moment at which
# the message is still cheap to change. They run again at push, because a
# message a rebase squashed together never reached this hook at all.
export def commit-msg [path: string]: nothing -> int {
  # A message is read, never a revision, so this hook never needs the jj side
  # of the repository prepared.
  let root = (vcs workspace-root "git")
  if (config find $root) == null { return 0 }

  let checks = (
    config load $root
    | get checks
    | where enabled
    | where input == "description"
  )
  if ($checks | is-empty) { return 0 }

  if not ($path | path exists) {
    err $"the commit-msg hook was given ($path), which does not exist"
    return 1
  }
  let message = (message-of $root $path)

  title "commit message"
  mut results = []
  for c in $checks {
    let status = (plan environment-status $c)
    if $status.status != "ok" {
      verdict "—" $c.name "skip" $status.reason
      $results = ($results | append { check: $c.name, status: "skip" })
      continue
    }
    let r = (exec run-one $c.command $root $message false)
    verdict "—" $c.name $r.status (exec fmt-duration $r.seconds)
    if $r.status == "fail" and ($r.output | is-not-empty) { print $r.output }
    $results = ($results | append { check: $c.name, status: $r.status })
  }

  let code = (summary $results)
  if $code != 0 {
    print $"(ansi dark_gray)commit aborted — commit anyway with `git commit --no-verify`(ansi reset)"
  }
  $code
}

# What git will actually record: the file still holds the comment block it
# shows in the editor, and everything past a scissors line is a diff.
def message-of [root: string, path: string]: nothing -> string {
  let char = (comment-char $root)
  let scissors = $"($char) ------------------------ >8 ------------------------"
  let body = (open --raw $path | lines)
  let cut = ($body | enumerate | where { |l| ($l.item | str trim) == $scissors } | get -o 0.index)
  (
    if $cut == null { $body } else { $body | first $cut }
    | where { |l| not ($l | str starts-with $char) }
    | str join "\n"
    | str trim --right
  )
}

def comment-char [root: string]: nothing -> string {
  let r = (^git -C $root config --get core.commentChar | complete)
  let value = ($r.stdout | str trim)
  # "auto" picks a character per message; the default is the one it starts from.
  if $r.exit_code != 0 or ($value | is-empty) or $value == "auto" { "#" } else { $value }
}

def short [ref: string]: nothing -> string {
  $ref | str replace --regex '^refs/(heads|tags|remotes)/' ''
}
