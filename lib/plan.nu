use jj.nu
use cache.nu

export def build [
  cfg: record
  stage: string
  revs: table # oldest first
  tips: list<string> # commits treated as the published tip
  range: string # revset a tip-scoped check should look at for changed paths
  cache_dir: string
  only: list<string>
  no_cache: bool
]: nothing -> record {
  let selected = (
    $cfg.checks
    | where enabled
    | where { |c| $stage in $c.stages }
    | where { |c| ($only | is-empty) or ($c.name in $only) }
  )

  let env_status = ($selected | each { |c| environment-status $c })
  let runnable = ($env_status | where status == "ok" | get check)

  mut seen = {}
  mut entries = []

  for c in ($selected | where { |c| $c.name in $runnable }) {
    let scope_revs = (if $c.scope == "tip" {
      $revs | where { |r| $r.commit in $tips }
    } else {
      $revs
    })

    for r in $scope_revs {
      # A tip-scoped check is about the state being published, so it reasons
      # about the whole range, not the tip commit's own diff.
      let revset = (if $c.scope == "tip" { $range } else { $r.commit })

      let files = (if ($c.paths | is-empty) or ($c.input == "description") {
        []
      } else {
        let key = ($revset + "\u{1}" + ($c.paths | str join "\u{1}"))
        if ($key in $seen) {
          $seen | get $key
        } else {
          let found = (jj changed-files $revset $c.paths)
          $seen = ($seen | insert $key $found)
          $found
        }
      })

      if ($c.paths | is-not-empty) and ($c.input != "description") and ($files | is-empty) {
        $entries = ($entries | append {
          commit: $r.commit, change: $r.change, check: $c.name,
          files: [], workspace: $c.workspace, state: "skip",
          reason: $"no file matched ($c.paths | str join ' ')"
        })
        continue
      }

      let cached = (
        (not $no_cache) and $c.cache and (cache hit $cache_dir $r.commit $c.name)
      )
      $entries = ($entries | append {
        commit: $r.commit, change: $r.change, check: $c.name,
        files: $files, workspace: $c.workspace,
        state: (if $cached { "cached" } else { "run" }), reason: ""
      })
    }
  }

  {
    skipped: ($env_status | where status != "ok")
    entries: $entries
  }
}

# Properties of the machine, not of a revision, so evaluated once.
export def environment-status [c: record]: nothing -> record {
  let missing = ($c.requires | where { |bin| which $bin | is-empty })
  if ($missing | is-not-empty) {
    return {
      check: $c.name, status: "missing",
      reason: $"not on PATH: ($missing | str join ', ')"
    }
  }
  if ($c.skip-if | is-not-empty) {
    let r = (^($c.skip-if | first) ...($c.skip-if | skip 1) | complete)
    if $r.exit_code == 0 {
      return { check: $c.name, status: "skip", reason: $c.skip-reason }
    }
  }
  { check: $c.name, status: "ok", reason: "" }
}
