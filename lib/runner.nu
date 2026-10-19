use log.nu *
use jj.nu
use cache.nu
use exec.nu
use plan.nu

export def execute [
  repo: record # { backend, root, jj_root, git_dir }
  cfg: record
  stage: string
  revs: table
  tips: list<string>
  range: string
  self_cmd: list<string> # how to re-invoke jj-ci inside jj run
  opts: record # { no_cache, only, verbose, here, jobs, strict }
]: nothing -> int {
  let cache_dir = (cache dir $repo.jj_root $cfg.hash)
  cache prune $repo.jj_root $cfg.hash

  let p = (plan build $cfg $stage $revs $tips $range $cache_dir $opts.only $opts.no_cache)

  # Nothing to run is a green run, which on a remote runner is indistinguishable
  # from a stage that passed.
  if $opts.strict and ($p.skipped | is-empty) and ($p.entries | is-empty) {
    err $"strict: stage ($stage) selected no checks at all"
    return 1
  }

  mut results = []

  # A check that cannot run here is a hole in the gate, not a result. Locally
  # that is the point of `requires`; on a runner it is the whole coverage.
  # A `paths` skip below is different: the check ran and found nothing to do.
  for s in $p.skipped {
    let status = (if $opts.strict { "fail" } else { "skip" })
    verdict "—" $s.check $status $s.reason
    $results = ($results | append { check: $s.check, status: $status })
  }

  for e in ($p.entries | where state == "skip") {
    verdict $e.change $e.check "skip" $e.reason
    $results = ($results | append { check: $e.check, status: "skip" })
  }

  for e in ($p.entries | where state == "cached") {
    verdict $e.change $e.check "pass" "cached"
    $results = ($results | append { check: $e.check, status: "pass" })
  }

  let todo = ($p.entries | where state == "run")
  if ($todo | is-empty) {
    return (summary $results)
  }

  let by_name = ($cfg.checks | reduce --fold {} { |c, acc| $acc | insert $c.name $c })

  let local = (if $opts.here { $todo } else { $todo | where workspace })
  let isolated = (if $opts.here { [] } else { $todo | where { |e| not $e.workspace } })

  # Every check of a revision runs; the next revision only if this one held.
  for commit in ($revs | get commit | where { |c| $c in ($local | get commit) }) {
    mut broke = false
    for e in ($local | where commit == $commit) {
      let check = ($by_name | get $e.check)
      let stdin = (if $check.input == "description" { jj description $e.commit } else { null })
      let argv = (exec argv-for $check $e.files)
      let r = (exec run-one $argv $repo.root $stdin $opts.verbose)
      verdict $e.change $e.check $r.status (exec fmt-duration $r.seconds)
      if $r.status == "fail" and ($r.output | is-not-empty) { print $r.output }
      if $r.status == "pass" and $check.cache { cache store $cache_dir $e.commit $e.check }
      $results = ($results | append { check: $e.check, status: $r.status })
      if $r.status == "fail" { $broke = true }
    }
    if $broke { return (summary $results) }
  }

  if ($isolated | is-empty) {
    return (summary $results)
  }

  let scratch = (cache dir $repo.jj_root $cfg.hash | path join "runs" (random chars --length 8))
  mkdir ($scratch | path join "results")

  let plan_file = ($scratch | path join "plan.json")
  {
    bootstrap: $cfg.bootstrap
    marker_dir: ($repo.jj_root | path join ".jj" "jj-ci" "bootstrap")
    cache_dir: $cache_dir
    results_dir: ($scratch | path join "results")
    verbose: $opts.verbose
    revisions: (
      $isolated
      | group-by commit
      | transpose commit entries
      | reduce --fold {} { |row, acc|
          $acc | insert $row.commit ($row.entries | each { |e|
            let check = ($by_name | get $e.check)
            {
              check: $e.check
              change: $e.change
              argv: (exec argv-for $check $e.files)
              cache: $check.cache
            }
          })
        }
    )
  } | to json | save --force --raw $plan_file

  let revset = ($isolated | get commit | uniq | str join " | ")
  let jobs = ([$opts.jobs 1] | math max)

  # --passthrough keeps the verdict lines live, at the cost of one job at a
  # time; -j is only honoured without it.
  let passthrough = (if $jobs == 1 { ["--passthrough"] } else { ["--jobs" ($jobs | into string)] })
  # --quiet keeps jj's own "Nothing changed." out of the report.
  let run_args = (
    ["run" "--quiet" "--ignore-changes" "--root"]
    ++ $passthrough
    ++ ["-r" $revset "--"]
    ++ $self_cmd
    ++ ["__revision"]
  )
  # No pipe: --passthrough hands the child the real terminal, so capturing jj
  # here would swallow every verdict line. jj's own stderr is set aside because
  # a failing check also makes jj report our plumbing by name; --verbose leaves
  # it attached, since the checks write there.
  let errfile = ($scratch | path join "jj-run.err")
  let ok = (with-env { JJ_CI_PLAN: $plan_file } {
    if $opts.verbose {
      try { ^jj ...$run_args; true } catch { false }
    } else {
      try { ^jj ...$run_args err> $errfile; true } catch { false }
    }
  })

  let collected = (
    ls ($scratch | path join "results")
    | get name
    | each { |f| open --raw $f | from json }
    | flatten
  )
  $results = ($results | append ($collected | select check status))

  let unreached = (
    ($isolated | length) - ($collected | length)
  )
  let jj_err = (if ($errfile | path exists) { open --raw $errfile | str trim } else { "" })
  rm -rf $scratch

  if (not $ok) and ($collected | where status == "fail" | is-empty) {
    err (if ($jj_err | is-empty) { "jj run failed before any check reported" } else { $jj_err })
    return 1
  }
  if $unreached > 0 {
    print $"  (ansi dark_gray)($unreached) check\(s) not reached — stopped at the first failing revision(ansi reset)"
  }
  summary $results
}

# Runs inside the isolated copy jj run prepared; everything it needs is in the
# plan file.
export def revision []: nothing -> int {
  let plan = (open --raw $env.JJ_CI_PLAN | from json)
  let commit = $env.JJ_COMMIT_ID
  let entries = ($plan.revisions | get -o $commit | default [])
  if ($entries | is-empty) { return 0 }

  if $plan.bootstrap != null {
    if not (bootstrap $plan) { return 1 }
  }

  # The nonzero exit is what stops jj run moving on to the next revision.
  mut results = []
  mut failed = false
  for e in $entries {
    let r = (exec run-one $e.argv $env.PWD null $plan.verbose)
    verdict $e.change $e.check $r.status (exec fmt-duration $r.seconds)
    if $r.status == "fail" and ($r.output | is-not-empty) { print $r.output }
    if $r.status == "pass" and $e.cache { cache store $plan.cache_dir $commit $e.check }
    $results = ($results | append { check: $e.check, status: $r.status })
    if $r.status == "fail" { $failed = true }
  }

  $results | to json | save --force --raw ($plan.results_dir | path join $"($commit).json")
  if $failed { 1 } else { 0 }
}

# The copy has no gitignored state, but is reused between invocations, so this
# is paid once per fingerprint change.
def bootstrap [plan: record]: nothing -> bool {
  let marker = ($plan.marker_dir | path join ($env.PWD | hash sha256 | str substring 0..15))
  let want = (
    ($plan.bootstrap.command | str join " ")
    + ($plan.bootstrap.fingerprint | each { |f|
        if ($f | path exists) { open --raw $f | hash sha256 } else { "absent" }
      } | str join "")
    | hash sha256 | str substring 0..15
  )
  let have = (if ($marker | path exists) { open --raw $marker | str trim } else { "" })
  if $have == $want { return true }

  let cmd = $plan.bootstrap.command
  let started = (date now)
  let r = (^($cmd | first) ...($cmd | skip 1) | complete)
  if $r.exit_code != 0 {
    verdict ($env.JJ_CHANGE_ID | str substring 0..7) "bootstrap" "fail" "failed"
    print (($r.stdout + $r.stderr) | str trim)
    return false
  }
  verdict ($env.JJ_CHANGE_ID | str substring 0..7) "bootstrap" "pass" (
    exec fmt-duration (((date now) - $started) / 1sec)
  )
  mkdir ($marker | path dirname)
  $want | save --force --raw $marker
  true
}
