# shellcheck shell=bash
# Sourced by leadr_integration_test.exp inside an interactive Bash PTY.

binding_test_fail() {
  printf 'BINDING_TEST_FAIL: %s\n' "$1" >&2
  return 1
}

binding_test_main() {
  local test_dir project_dir config bad_config current

  test_dir=$(cd -- "${BASH_SOURCE[0]%/*}" && pwd -P)
  project_dir=$(cd -- "$test_dir/.." && pwd -P)
  config=$project_dir/config.example.bash
  # shellcheck disable=SC1091
  source "$project_dir/leadr.bash"

  leadr_init '\C-g' "$config" || binding_test_fail 'initialization failed' || return
  for current in emacs-standard vi-insert vi-command; do
    __leadr_binding_is_ours "$current" '\C-g' || binding_test_fail "missing leadr binding in $current" || return
  done

  bad_config=$(mktemp "${TMPDIR:-/tmp}/leadr-bad-config.XXXXXX") || return
  printf '%s\n' "leadr_map bad-key Bad REPLACE bad" >"$bad_config"
  if leadr_init '\C-x' "$bad_config" 2>/dev/null; then
    rm -f -- "$bad_config"
    binding_test_fail 'invalid reinitialization succeeded'
    return
  fi
  rm -f -- "$bad_config"
  for current in emacs-standard vi-insert vi-command; do
    __leadr_binding_is_ours "$current" '\C-g' || binding_test_fail "failed init damaged $current" || return
  done

  leadr_init '\C-x' "$config" || binding_test_fail 're-key initialization failed' || return
  for current in emacs-standard vi-insert vi-command; do
    ! __leadr_binding_is_ours "$current" '\C-g' || binding_test_fail "old binding remains in $current" || return
    __leadr_binding_is_ours "$current" '\C-x' || binding_test_fail "new binding missing in $current" || return
  done

  # Re-key once more so the interactive input test uses the default chord.
  leadr_init '\C-g' "$config" || binding_test_fail 'round-trip re-key failed' || return
  for current in emacs-standard vi-insert vi-command; do
    __leadr_binding_is_ours "$current" '\C-g' || binding_test_fail "round-trip binding missing in $current" || return
  done

  printf 'BINDING_TEST_OK\n'
}

binding_test_main
