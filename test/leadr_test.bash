#!/usr/bin/env bash
# Unit tests for leadr.bash. Run with Bash 5+:
#   bash test/leadr_test.bash

set -u
set -o pipefail

TEST_DIR=$(cd -- "${BASH_SOURCE[0]%/*}" && pwd -P)
PROJECT_DIR=$(cd -- "$TEST_DIR/.." && pwd -P)
# shellcheck disable=SC1091 # path is computed from this test file at runtime.
source "$PROJECT_DIR/leadr.bash"

TESTS=0
FAILURES=0
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/leadr-test.XXXXXX")
trap 'rm -rf -- "$TMP_DIR"' EXIT

pass() {
  TESTS=$((TESTS + 1))
  printf 'ok %d - %s\n' "$TESTS" "$1"
}

fail() {
  TESTS=$((TESTS + 1))
  FAILURES=$((FAILURES + 1))
  printf 'not ok %d - %s\n' "$TESTS" "$1"
  [[ $# -lt 2 ]] || printf '  %s\n' "$2"
}

assert_eq() {
  local expected=$1 actual=$2 name=$3
  if [[ $actual == "$expected" ]]; then
    pass "$name"
  else
    fail "$name" "expected ${expected@Q}, got ${actual@Q}"
  fi
}

assert_status() {
  local expected=$1 actual=$2 name=$3
  if (( actual == expected )); then
    pass "$name"
  else
    fail "$name" "expected status $expected, got $actual"
  fi
}

assert_contains() {
  local value=$1 expected=$2 name=$3
  if [[ $value == *"$expected"* ]]; then
    pass "$name"
  else
    fail "$name" "expected output to contain ${expected@Q}"
  fi
}

reset_registry() {
  __LEADR_KEY='\C-g'
  __LEADR_MAP=()
}

register() {
  local key=$1 mode=$2 command=$3
  leadr_map "$key" "Mapping $key" "${mode^^}" "$command"
}

transform() {
  local mode=$1 payload=$2 line=$3 point=$4
  local output cursor
  __leadr_transform "$mode" "$payload" "$line" "$point" output cursor
  printf '%s\037%s' "$output" "$cursor"
}

activate_config() {
  local file=$1
  # shellcheck disable=SC2034 # populated through a nameref.
  local -A staged=()
  __leadr_load_config "$file" staged || return 1
  __leadr_copy_assoc staged __LEADR_MAP
  __LEADR_KEY='\C-g'
}

# Initialization requires exactly KEY and CONFIG.
if leadr_init '\C-g' 2>/dev/null; then
  fail 'leadr_init rejects a missing config argument'
else
  pass 'leadr_init rejects a missing config argument'
fi
if leadr_init '\C-g' one two 2>/dev/null; then
  fail 'leadr_init rejects extra arguments'
else
  pass 'leadr_init rejects extra arguments'
fi

# Registration is available before initialization.
__LEADR_KEY=''
__LEADR_MAP=()
if leadr_map a A REPLACE alpha; then
  pass 'registration before init is allowed'
else
  fail 'registration before init is allowed'
fi

reset_registry
if leadr_map gs 'Git status' REPLACE+EXEC 'git status'; then
  pass 'registers a complete mapping'
else
  fail 'registers a complete mapping'
fi
show_output=$(leadr show gs)
assert_contains "$show_output" 'flags:       REPLACE+EXEC' 'show exposes mapping flags'
assert_contains "$show_output" 'command:     git status' 'show exposes command payload'

leadr_map gs 'Short status' INSERT 'git status --short'
show_output=$(leadr show gs)
assert_contains "$show_output" 'flags:       INSERT' 'live registration replaces mapping flags'
assert_contains "$show_output" 'command:     git status --short' 'live registration replaces mapping command'

if leadr_map g Git REPLACE git; then
  pass 'fzf-only mappings may share key prefixes'
else
  fail 'fzf-only mappings may share key prefixes'
fi
if leadr_map 'g-' Bad REPLACE bad 2>/dev/null; then
  fail 'rejects non-alphanumeric mapping keys'
else
  pass 'rejects non-alphanumeric mapping keys'
fi
if leadr_map xx Missing EVAL value 2>/dev/null; then
  fail 'requires an explicit transformation mode'
else
  pass 'requires an explicit transformation mode'
fi
if leadr_map xx '' REPLACE value 2>/dev/null; then
  fail 'requires a description'
else
  pass 'requires a description'
fi
if leadr_map xx Extra REPLACE one two 2>/dev/null; then
  fail 'requires one quoted payload argument'
else
  pass 'requires one quoted payload argument'
fi
if leadr_map xx Cursor REPLACE+EXEC '#CURSOR echo' 2>/dev/null; then
  fail 'rejects cursor marker with execute'
else
  pass 'rejects cursor marker with execute'
fi
if leadr_map xx Surround SURROUND 'watch command' 2>/dev/null; then
  fail 'requires command marker for surround'
else
  pass 'requires command marker for surround'
fi
if leadr_map xx Surround SURROUND+EVAL 'printf #COMMAND' 2>/dev/null; then
  fail 'rejects evaluated surround mapping'
else
  pass 'rejects evaluated surround mapping'
fi
# Buffer transformations. Unit separator keeps line and point together.
result=$(transform replace 'git #CURSORstatus' 'old #CURSOR' 3)
assert_eq $'git status\0374' "$result" 'replace honors cursor marker'
result=$(transform insert 'X#CURSOR' 'old #CURSOR' 3)
assert_eq $'oldX #CURSOR\0374' "$result" 'insert ignores marker text already in original buffer'
result=$(transform prepend 'sudo ' 'apt update' 4)
assert_eq $'sudo apt update\0379' "$result" 'prepend preserves original cursor position'
result=$(transform append ' | less' 'make' 2)
assert_eq $'make | less\03711' "$result" 'append places cursor at end'
result=$(transform surround "watch '#COMMAND'" 'echo hello' 5)
assert_eq "watch 'echo hello'"$'\03712' "$result" 'surround preserves cursor relative to original text'
result=$(transform surround "#CURSORwatch '#COMMAND'" 'echo hello' 5)
assert_eq "watch 'echo hello'"$'\0370' "$result" 'surround supports cursor marker before command'
result=$(transform surround "watch '#COMMAND'#CURSOR" 'echo hello' 5)
assert_eq "watch 'echo hello'"$'\03718' "$result" 'surround supports cursor marker after command'
result=$(transform insert 'Z' 'éx' 2)
assert_eq $'éZx\0373' "$result" 'UTF-8 insertion uses Readline byte offsets'

# Evaluation behavior
reset_registry
leadr_map ev 'Generated value' INSERT+EVAL 'printf generated'
READLINE_LINE='pre-post'
READLINE_POINT=4
if __leadr_apply_mapping ev; then
  assert_eq 'pre-generatedpost' "$READLINE_LINE" 'evaluation output is inserted'
  assert_eq '13' "$READLINE_POINT" 'evaluation updates cursor by byte count'
else
  fail 'evaluation mapping succeeds'
fi

leadr_map empty 'Empty value' REPLACE+EVAL ':'
READLINE_LINE='unchanged'
READLINE_POINT=4
if __leadr_apply_mapping empty 2>/dev/null; then
  fail 'empty evaluation is rejected'
else
  assert_eq 'unchanged' "$READLINE_LINE" 'failed evaluation leaves line unchanged'
fi

leadr_map multi 'Multiline value' REPLACE+EVAL "printf 'one\\ntwo'"
READLINE_LINE='unchanged'
READLINE_POINT=4
if __leadr_apply_mapping multi 2>/dev/null; then
  fail 'multiline evaluation is rejected'
else
  pass 'multiline evaluation is rejected'
fi

# Isolated, committed config loading.
cat >"$TMP_DIR/good.bash" <<'CONFIG'
leadr_map aa 'First value' REPLACE 'echo first'
leadr_map aa 'Last value' APPEND ' second'
CONFIG
if activate_config "$TMP_DIR/good.bash"; then
  show_output=$(leadr show aa)
  assert_contains "$show_output" 'flags:       APPEND' 'config duplicate keeps latest flags'
  assert_contains "$show_output" 'command:      second' 'config duplicate keeps latest command'
else
  fail 'valid config loads successfully'
fi

cat >"$TMP_DIR/bad.bash" <<'CONFIG'
leadr_map ok 'Valid first mapping' REPLACE 'echo ok'
leadr_map 'not-valid' 'Invalid mapping' REPLACE 'echo bad'
true
CONFIG
before=$(leadr show aa)
# shellcheck disable=SC2034 # populated only if loading unexpectedly succeeds.
declare -A rejected=()
if __leadr_load_config "$TMP_DIR/bad.bash" rejected >/dev/null 2>&1; then
  fail 'any failed registration rejects config'
else
  after=$(leadr show aa)
  assert_eq "$before" "$after" 'failed loading leaves active registry unchanged'
fi

: >"$TMP_DIR/empty.bash"
if __leadr_load_config "$TMP_DIR/empty.bash" rejected >/dev/null 2>&1; then
  fail 'empty config is rejected'
else
  pass 'empty config is rejected'
fi

cat >"$TMP_DIR/isolation.bash" <<'CONFIG'
cd /
export LEADR_TEST_SIDE_EFFECT=changed
leadr_map iso 'Isolated mapping' REPLACE 'declare -A value=()'
CONFIG
before_dir=$PWD
unset LEADR_TEST_SIDE_EFFECT || :
if activate_config "$TMP_DIR/isolation.bash"; then
  assert_eq "$before_dir" "$PWD" 'config cannot change parent directory'
  assert_eq 'unset' "${LEADR_TEST_SIDE_EFFECT-unset}" 'config cannot export parent variables'
  show_output=$(leadr show iso)
  assert_contains "$show_output" 'command:     declare -A value=()' 'registry snapshot preserves shell syntax as text'
else
  fail 'isolated config loads successfully'
fi

cat >"$TMP_DIR/early-exit.bash" <<'CONFIG'
leadr_map lost 'Must not commit' REPLACE 'echo lost'
exit 0
CONFIG
before=$(leadr show iso)
if __leadr_load_config "$TMP_DIR/early-exit.bash" rejected >/dev/null 2>&1; then
  fail 'config exit zero without a snapshot is rejected'
else
  after=$(leadr show iso)
  assert_eq "$before" "$after" 'missing snapshot preserves active registry'
fi

# Sorting and management output
reset_registry
register z replace zed
register a replace alpha
register m replace middle
list_output=$(leadr list)
list_keys=$(printf '%s\n' "$list_output" | tail -n +2 | while read -r key _; do printf '%s' "$key"; done)
assert_eq 'amz' "$list_keys" 'list output sorts mapping keys'
show_output=$(leadr show m)
assert_contains "$show_output" 'description: Mapping m' 'show prints mapping description'
assert_contains "$show_output" 'command:     middle' 'show prints mapping command'

# fzf protocol with a PATH-provided fake executable.
mkdir -p "$TMP_DIR/bin"
cat >"$TMP_DIR/bin/fzf" <<'FAKE'
#!/usr/bin/env bash
if [[ -n ${FZF_DEFAULT_OPTS-} || -n ${FZF_DEFAULT_OPTS_FILE-} ]]; then
  exit 91
fi
case ${FAKE_FZF_MODE-select} in
  cancel) exit 130 ;;
  fail) exit 7 ;;
  unknown) printf 'unknown\tUnknown\tunknown\n'; exit 0 ;;
esac
IFS= read -r first || exit 1
printf '%s\n' "$first"
FAKE
chmod +x "$TMP_DIR/bin/fzf"
old_path=$PATH
PATH="$TMP_DIR/bin:$PATH"
export PATH
export FZF_DEFAULT_OPTS='--multi --print-query'
export FZF_DEFAULT_OPTS_FILE='/tmp/should-not-be-read'

reset_registry
register ga replace 'git add .'
register gc replace 'git commit'
if picked=$(__leadr_pick); then
  assert_eq 'ga' "$picked" 'fzf picker returns selected mapping key'
else
  fail 'fzf picker returns selected mapping key'
fi

export FAKE_FZF_MODE=cancel
if __leadr_pick >/dev/null 2>&1; then
  fail 'fzf cancellation returns cancellation status'
else
  assert_status 1 "$?" 'fzf cancellation returns cancellation status'
fi

export FAKE_FZF_MODE=fail
if __leadr_pick >/dev/null 2>&1; then
  fail 'fzf failure returns failure status'
else
  assert_status 2 "$?" 'fzf failure returns failure status'
fi

export FAKE_FZF_MODE=unknown
if __leadr_pick >/dev/null 2>&1; then
  fail 'fzf unknown key is rejected'
else
  assert_status 2 "$?" 'fzf unknown key is rejected'
fi

PATH=$old_path
unset FAKE_FZF_MODE FZF_DEFAULT_OPTS FZF_DEFAULT_OPTS_FILE

# A failed multi-keymap installation removes bindings already installed.
declare -A FAKE_BIND_TYPE=(
  [emacs-standard]=function
  [vi-insert]=macro
  [vi-command]=shell
)
declare -A FAKE_BIND_LINE=(
  [emacs-standard]='"\C-g": abort'
  [vi-insert]='"\C-g": "prior-macro"'
  [vi-command]='"\C-g" "echo prior-shell"'
)

bind() {
  local keymap definition quoted_key
  [[ $1 == -m ]] || return 2
  keymap=$2
  shift 2
  case ${1-} in
    -X) [[ ${FAKE_BIND_TYPE[$keymap]} == shell ]] && printf '%s\n' "${FAKE_BIND_LINE[$keymap]}" ;;
    -s) [[ ${FAKE_BIND_TYPE[$keymap]} == macro ]] && printf '%s\n' "${FAKE_BIND_LINE[$keymap]}" ;;
    -p) [[ ${FAKE_BIND_TYPE[$keymap]} == function ]] && printf '%s\n' "${FAKE_BIND_LINE[$keymap]}" ;;
    -r)
      FAKE_BIND_TYPE[$keymap]=none
      FAKE_BIND_LINE[$keymap]=''
      ;;
    -x)
      definition=$2
      if [[ $definition == *':__leadr_invoke' ]]; then
        [[ $keymap != vi-insert ]] || return 1
        quoted_key=${definition%%:*}
        FAKE_BIND_TYPE[$keymap]=shell
        FAKE_BIND_LINE[$keymap]="$quoted_key \"__leadr_invoke\""
      else
        FAKE_BIND_TYPE[$keymap]=shell
        FAKE_BIND_LINE[$keymap]=$definition
      fi
      ;;
    *)
      definition=$1
      FAKE_BIND_LINE[$keymap]=$definition
      if [[ $definition == *': "'* ]]; then
        FAKE_BIND_TYPE[$keymap]=macro
      else
        FAKE_BIND_TYPE[$keymap]=function
      fi
      ;;
  esac
}

if __leadr_install_key '\C-g' 2>/dev/null; then
  fail 'partial binding installation fails'
else
  assert_eq '' "${FAKE_BIND_LINE[emacs-standard]}" 'rollback removes installed leadr binding'
  assert_eq '"\C-g": "prior-macro"' "${FAKE_BIND_LINE[vi-insert]}" 'failed keymap retains prior macro binding'
  assert_eq '"\C-g" "echo prior-shell"' "${FAKE_BIND_LINE[vi-command]}" 'untouched keymap retains prior shell binding'
fi
unset -f bind

# Completion reads the live registry.
COMP_WORDS=(leadr show g)
COMP_CWORD=2
__leadr_complete
assert_eq 'ga gc' "${COMPREPLY[*]}" 'completion offers live mapping keys'

printf '\n%d tests, %d failures\n' "$TESTS" "$FAILURES"
(( FAILURES == 0 ))
