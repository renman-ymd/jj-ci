const LIB = path self "../lib"
use $"($LIB)/vcs.nu"
use $"($LIB)/config.nu"

# `requires` and `skip-if` are deliberately not evaluated: the machine asking
# for the list is not the machine that will run them.
export def invoke [stage: string, backend: string]: nothing -> table {
  let root = (vcs workspace-root $backend)
  let file = (config find $root)
  if $file == null {
    error make --unspanned { msg: $"no .jj-ci.toml in ($root) — run `jj-ci init` to create one" }
  }

  config load $root
  | get checks
  | where enabled
  | where { |c| $stage in $c.stages }
  | each { |c| { check: $c.name, doc: $c.doc } }
}
