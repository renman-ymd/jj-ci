use log.nu [info, warn]
use jj.nu

const BEGIN = "# >>> jj-ci managed — generated from .jj-ci.toml >>>"
const END = "# <<< jj-ci managed <<<"

export def block [cfg: record]: nothing -> string {
  let aliases = (
    $cfg.filesets
    | columns
    | each { |name| $"fileset-aliases.($name) = (toml-str ($cfg.filesets | get $name))" }
  )
  let tools = (
    $cfg.format
    | columns
    | each { |name|
        let t = ($cfg.format | get $name)
        let base = [
          $"fix.tools.($name).command = (toml-array $t.command)"
          $"fix.tools.($name).patterns = (toml-array $t.patterns)"
          $"fix.tools.($name).enabled = (if $t.enabled { 'true' } else { 'false' })"
        ]
        let lines = (if $t.line-range-arg != null {
          $base | append $"fix.tools.($name).line-range-arg = (toml-str $t.line-range-arg)"
        } else { $base })
        if $t.run-tool-if-zero-line-ranges != null {
          $lines | append (
            $"fix.tools.($name).run-tool-if-zero-line-ranges = "
            + (if $t.run-tool-if-zero-line-ranges { "true" } else { "false" })
          )
        } else { $lines }
      }
    | flatten
  )

  ([
    $BEGIN
    $"# source hash: ($cfg.hash) — edit ($cfg.path | path basename), not this file."
    ...$aliases
    ...$tools
    $END
  ] | str join "\n")
}

export def ensure [cfg: record]: nothing -> bool {
  let wanted = (block $cfg)
  let dest = (jj repo-config-path)
  let current = (if ($dest | path exists) { open --raw $dest } else { "" })

  let existing = (extract $current)
  if $existing == $wanted { return false }

  # A table header outside our block would collide with the keys we write.
  let outside = (strip $current)
  if ($outside =~ '(?m)^\s*\[\s*(fix\.tools|fileset-aliases)') {
    error make {
      msg: ($"($dest) already declares [fix.tools] or [fileset-aliases] outside the jj-ci block."
        + $"\nMove those declarations into ($cfg.path | path basename), or delete them, then run again.")
    }
  }

  # The block goes first: a dotted key belongs to whatever [table] header
  # precedes it, so after someone's `[revset-aliases]` these would be read as
  # `revset-aliases.fix.tools.…` — valid TOML, silently the wrong setting.
  let body = (if ($outside | str trim | is-empty) { "" } else { "\n" + ($outside | str trim) + "\n" })
  let next = $wanted + "\n" + $body

  if ($dest | path exists) { cp $dest $"($dest).jj-ci.bak" }
  mkdir ($dest | path dirname)
  $next | save --force --raw $dest

  # A config jj cannot parse would break every later command.
  let probe = (^jj --ignore-working-copy config list --repo | complete)
  if $probe.exit_code != 0 {
    if ($"($dest).jj-ci.bak" | path exists) { cp $"($dest).jj-ci.bak" $dest } else { rm -f $dest }
    error make { msg: $"rendered repo config was rejected by jj, restored the previous one:\n($probe.stderr | str trim)" }
  }

  if $existing == null {
    info $"installed jj-ci block in ($dest)"
  } else {
    info $"refreshed jj-ci block in ($dest) \(.jj-ci.toml changed)"
  }
  true
}

export def remove []: nothing -> bool {
  let dest = (jj repo-config-path)
  if not ($dest | path exists) { return false }
  let current = (open --raw $dest)
  if (extract $current) == null { return false }
  cp $dest $"($dest).jj-ci.bak"
  (strip $current | str trim) + "\n" | save --force --raw $dest
  true
}

def extract [text: string]: nothing -> any {
  let start = ($text | str index-of $BEGIN)
  if $start < 0 { return null }
  let end = ($text | str index-of $END)
  if $end < 0 { return null }
  $text | str substring $start..($end + ($END | str length) - 1)
}

def strip [text: string]: nothing -> string {
  let found = (extract $text)
  if $found == null { return $text }
  $text | str replace $found ""
}

def toml-str [value: string]: nothing -> string {
  let escaped = (
    $value
    | str replace --all "\\" "\\\\"
    | str replace --all '"' '\"'
    | str replace --all "\n" "\\n"
    | str replace --all "\t" "\\t"
  )
  $'"($escaped)"'
}

def toml-array [values: list<string>]: nothing -> string {
  $"[($values | each { |v| toml-str $v } | str join ', ')]"
}
