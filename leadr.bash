# shellcheck shell=bash
# shellcheck disable=SC2030,SC2031 # config intentionally mutates a registry in a subshell.
# Source this file, then run: leadr_init KEY CONFIG

if (( BASH_VERSINFO[0] < 5 )); then
  printf 'leadr: Bash 5 or newer is required\n' >&2
  # shellcheck disable=SC2317 # exit is the fallback when the file is executed.
  return 1 2>/dev/null || exit 1
fi

# One record per mapping: description<TAB>FLAGS COMMAND.
if ! declare -p __LEADR_MAP &>/dev/null; then
  declare -gA __LEADR_MAP=()
  declare -g __LEADR_KEY=''
fi

__leadr_error() {
  printf 'leadr: %s\n' "$*" >&2
}

__leadr_map_error() {
  __leadr_error "$*"
  return 1
}

__leadr_marker_count() {
  local value=$1
  local marker=$2
  local count=0

  while [[ $value == *"$marker"* ]]; do
    value=${value#*"$marker"}
    count=$((count + 1))
  done

  printf '%d' "$count"
}

__leadr_parse_flags() {
  local flags=$1 mode_name=$2 evaluate_name=$3 execute_name=$4 key=${5:-mapping}
  local token parsed_mode='' eval_flag=0 exec_flag=0 mode_count=0
  local -a tokens=()
  local -n mode_out=$mode_name evaluate_out=$evaluate_name execute_out=$execute_name

  IFS=+ read -r -a tokens <<< "$flags"
  for token in "${tokens[@]}"; do
    case $token in
      REPLACE|INSERT|PREPEND|APPEND|SURROUND)
        parsed_mode=${token,,}
        mode_count=$((mode_count + 1))
        ;;
      EVAL)
        (( ! eval_flag )) || { __leadr_map_error "mapping ${key@Q} repeats EVAL"; return 1; }
        eval_flag=1
        ;;
      EXEC)
        (( ! exec_flag )) || { __leadr_map_error "mapping ${key@Q} repeats EXEC"; return 1; }
        exec_flag=1
        ;;
      *)
        __leadr_map_error "mapping ${key@Q} has unknown flag: ${token@Q}"
        return 1
        ;;
    esac
  done
  (( mode_count == 1 )) ||
    { __leadr_map_error "mapping ${key@Q} requires exactly one transformation mode"; return 1; }
  # shellcheck disable=SC2034 # nameref assignments are outputs to the caller.
  mode_out=$parsed_mode
  # shellcheck disable=SC2034 # nameref assignments are outputs to the caller.
  evaluate_out=$eval_flag
  # shellcheck disable=SC2034 # nameref assignments are outputs to the caller.
  execute_out=$exec_flag
}

__leadr_validate_mapping() {
  local key=$1 description=$2 flags=$3 command=$4
  local mode evaluate execute cursor_count command_count LC_ALL=C

  [[ $key =~ ^[A-Za-z0-9]+$ ]] ||
    { __leadr_map_error "invalid mapping key: ${key@Q}"; return 1; }
  [[ -n $description ]] ||
    { __leadr_map_error "mapping ${key@Q} requires a description"; return 1; }
  [[ $description != *[$'\t\r\n']* ]] ||
    { __leadr_map_error "mapping ${key@Q} description must be one line without tabs"; return 1; }
  __leadr_parse_flags "$flags" mode evaluate execute "$key" || return 1
  [[ -n $command ]] ||
    { __leadr_map_error "mapping ${key@Q} requires a payload"; return 1; }
  [[ $command != *[$'\t\r\n']* ]] ||
    { __leadr_map_error "mapping ${key@Q} payload must be one line without tabs"; return 1; }

  cursor_count=$(__leadr_marker_count "$command" '#CURSOR')
  command_count=$(__leadr_marker_count "$command" '#COMMAND')
  (( cursor_count <= 1 )) ||
    { __leadr_map_error "mapping ${key@Q} repeats #CURSOR"; return 1; }
  (( !(evaluate || execute) || !cursor_count )) ||
    { __leadr_map_error "mapping ${key@Q} cannot combine #CURSOR with evaluate or execute"; return 1; }

  if [[ $mode == surround ]]; then
    (( command_count == 1 )) ||
      { __leadr_map_error "surround mapping ${key@Q} requires exactly one #COMMAND"; return 1; }
    (( ! evaluate )) ||
      { __leadr_map_error "surround mapping ${key@Q} cannot use EVAL"; return 1; }
  else
    (( ! command_count )) ||
      { __leadr_map_error "mapping ${key@Q} may use #COMMAND only with SURROUND"; return 1; }
  fi
}

__leadr_has_prefix_conflict() {
  local key=$1
  local registry_name=${2:-__LEADR_MAP}
  local existing
  local -n registry=$registry_name

  for existing in "${!registry[@]}"; do
    [[ $existing == "$key" ]] && continue
    if [[ $existing == "$key"* || $key == "$existing"* ]]; then
      __leadr_map_error "mapping ${key@Q} conflicts with prefix mapping ${existing@Q}"
      return 0
    fi
  done

  return 1
}

__leadr_unpack_record() {
  local record=$1 description_name=$2 flags_name=$3 command_name=$4
  local instruction
  local -n description_out=$description_name flags_out=$flags_name command_out=$command_name

  [[ $record == *$'\t'* ]] || return 1
  # shellcheck disable=SC2034 # nameref assignments are outputs to the caller.
  description_out=${record%%$'\t'*}
  instruction=${record#*$'\t'}
  [[ $instruction == *' '* ]] || return 1
  # shellcheck disable=SC2034 # nameref assignments are outputs to the caller.
  flags_out=${instruction%% *}
  # shellcheck disable=SC2034 # nameref assignments are outputs to the caller.
  command_out=${instruction#* }
}

# Register during config loading, or add/replace a live mapping after init.
leadr_map() {
  local key=${1-} description=${2-} flags=${3-} command=${4-}

  (( $# == 4 )) ||
    { __leadr_map_error 'usage: leadr_map KEY DESCRIPTION FLAGS COMMAND'; return 1; }
  __leadr_validate_mapping "$key" "$description" "$flags" "$command" || return 1
  __leadr_has_prefix_conflict "$key" __LEADR_MAP && return 1
  __LEADR_MAP[$key]="${description}"$'\t'"${flags} ${command}"
}

# Runs in a child process. A mapping error aborts the config immediately.
__leadr_run_config() (
  local file=$1
  __LEADR_MAP=()

  # shellcheck disable=SC2329 # dynamically overrides the config child's error handler.
  __leadr_map_error() {
    __leadr_error "$*"
    exit 1
  }

  # shellcheck disable=SC1090
  source "$file" 1>&2 || exit $?
  (( ${#__LEADR_MAP[@]} )) || { __leadr_error 'configuration registered no mappings'; exit 1; }
  builtin declare -p __LEADR_MAP
)

__leadr_load_config() {
  local file=$1 output_name=$2 snapshot declaration
  local prefix='declare -A __LEADR_MAP='
  # shellcheck disable=SC2034 # populated by the verified declare snapshot.
  local -A decoded=()

  snapshot=$(__leadr_run_config "$file") || return 1
  if [[ $snapshot != "$prefix"* || $snapshot == *$'\n'* ]]; then
    __leadr_error 'config produced an invalid registry snapshot'
    return 1
  fi

  declaration="declare -A decoded=${snapshot#"$prefix"}"
  eval "$declaration"
  __leadr_copy_assoc decoded "$output_name"
}

__leadr_key_valid() {
  local key=$1 suffix
  local LC_ALL=C

  if (( ${#key} != 4 )) || [[ ${key:0:3} != '\C-' ]]; then
    return 1
  fi
  suffix=${key:3:1}
  case $suffix in
    [A-Za-z]|'@'|'['|']'|'^'|'_'|'?') return 0 ;;
    *) return 1 ;;
  esac
}

__leadr_binding_is_ours() {
  local keymap=$1 key=$2 line
  local expected="\"$key\" \"__leadr_invoke\""

  while IFS= read -r line; do
    [[ $line == "$expected" ]] && return 0
  done < <(bind -m "$keymap" -X 2>/dev/null)
  return 1
}

__leadr_install_key() {
  local key=$1 keymap rollback_map
  local -a installed=()

  for keymap in emacs-standard vi-insert vi-command; do
    if bind -m "$keymap" -x "\"$key\":__leadr_invoke"; then
      installed+=("$keymap")
      continue
    fi
    __leadr_error "failed to bind ${key@Q} in $keymap"
    for rollback_map in "${installed[@]}"; do
      bind -m "$rollback_map" -r "$key" 2>/dev/null || :
    done
    return 1
  done
}

__leadr_remove_owned_key() {
  local key=$1 keymap

  for keymap in emacs-standard vi-insert vi-command; do
    if __leadr_binding_is_ours "$keymap" "$key"; then
      bind -m "$keymap" -r "$key" 2>/dev/null || :
    fi
  done
}

__leadr_copy_assoc() {
  local input_name=$1 output_name=$2 key
  local -n input=$input_name
  # shellcheck disable=SC2178 # caller passes an associative array name.
  local -n output=$output_name

  output=()
  for key in "${!input[@]}"; do output["$key"]=${input[$key]}; done
}

leadr_init() {
  local key=${1-} file=${2-} old_key
  # shellcheck disable=SC2034 # populated through a nameref.
  local -A staged=()
  if (( $# != 2 )); then
    __leadr_error 'usage: leadr_init KEY CONFIG'
    return 1
  fi
  if [[ $- != *i* ]]; then
    __leadr_error 'leadr_init requires an interactive Bash shell'
    return 1
  fi
  if ! command -v fzf >/dev/null; then
    __leadr_error 'fzf is required but was not found'
    return 1
  fi
  if [[ ! -r /dev/tty ]]; then
    __leadr_error '/dev/tty is not readable'
    return 1
  fi

  if ! __leadr_key_valid "$key"; then
    __leadr_error "leader key must be one Ctrl chord such as \\C-g: ${key@Q}"
    return 1
  fi
  if [[ -z $file || ! -f $file || ! -r $file ]]; then
    __leadr_error "config must be a readable file: ${file@Q}"
    return 1
  fi
  __leadr_load_config "$file" staged || return 1

  old_key=${__LEADR_KEY-}
  if [[ $key != "$old_key" ]]; then
    __leadr_install_key "$key" || return 1
  fi

  # From here on, the registry transition is infallible.
  __leadr_copy_assoc staged __LEADR_MAP
  __LEADR_KEY=$key

  if [[ -n $old_key && $old_key != "$key" ]]; then
    __leadr_remove_owned_key "$old_key"
  fi

}

__leadr_require_init() {
  if [[ -z ${__LEADR_KEY-} ]]; then
    __leadr_error 'leadr has not been initialized'
    return 1
  fi
}

__leadr_has_prefix() {
  local prefix=$1 key

  for key in "${!__LEADR_MAP[@]}"; do
    [[ $key == "$prefix"* ]] && return 0
  done
  return 1
}

__leadr_sorted_keys() {
  local output_name=$1 key i
  local LC_ALL=C
  # shellcheck disable=SC2178 # caller passes an indexed array name.
  local -n output=$output_name

  output=()
  for key in "${!__LEADR_MAP[@]}"; do
    i=0
    while (( i < ${#output[@]} )) && [[ ${output[i]} < $key ]]; do
      i=$((i + 1))
    done
    output=("${output[@]:0:i}" "$key" "${output[@]:i}")
  done
}

__leadr_list() {
  local key description flags command
  local -a keys=()

  __leadr_require_init || return 1
  __leadr_sorted_keys keys
  printf '%-8s %-20s %-28s %s\n' KEY FLAGS DESCRIPTION COMMAND

  for key in "${keys[@]}"; do
    __leadr_unpack_record "${__LEADR_MAP[$key]}" description flags command
    printf '%-8s %-20s %-28s %s\n' "$key" "$flags" "$description" "$command"
  done
}

__leadr_show() {
  local key=$1 description flags command

  __leadr_require_init || return 1
  if [[ ! ${__LEADR_MAP[$key]+present} ]]; then
    __leadr_error "unknown mapping: ${key@Q}"
    return 1
  fi

  __leadr_unpack_record "${__LEADR_MAP[$key]}" description flags command
  printf 'key:         %s\n' "$key"
  printf 'flags:       %s\n' "$flags"
  printf 'description: %s\n' "$description"
  printf 'command:     %s\n' "$command"
}

__leadr_help() {
  printf '%s\n' \
    'Usage:' \
    "  leadr_init KEY CONFIG" \
    '  leadr_map KEY DESCRIPTION FLAGS COMMAND' \
    '  leadr list' \
    '  leadr show KEY' \
    '  leadr help' \
    '' \
    'Flags: REPLACE INSERT PREPEND APPEND SURROUND, optionally +EVAL and +EXEC'
}

leadr() {
  local subcommand=${1-help}
  (( $# == 0 )) || shift

  case $subcommand in
    list)
      if (( $# != 0 )); then
        __leadr_error 'usage: leadr list'
        return 1
      fi
      __leadr_list
      ;;
    show)
      if (( $# != 1 )); then
        __leadr_error 'usage: leadr show KEY'
        return 1
      fi
      __leadr_show "$1"
      ;;
    help|-h|--help)
      if (( $# != 0 )); then
        __leadr_error 'usage: leadr help'
        return 1
      fi
      __leadr_help
      ;;
    *)
      __leadr_error "unknown command: ${subcommand@Q}"
      return 1
      ;;
  esac
}

__leadr_emit_candidates() {
  local prefix=$1 key description flags command
  local -a keys=()

  __leadr_sorted_keys keys
  for key in "${keys[@]}"; do
    [[ $key == "$prefix"* ]] || continue
    __leadr_unpack_record "${__LEADR_MAP[$key]}" description flags command
    printf '%s\t%s\t%s\t%s\n' "$key" "$description" "$flags" "$command"
  done
}

# Return 0 with a key, 1 for cancel, and 2 for failure.
__leadr_pick() {
  local prefix=$1 selected status key

  if selected=$(
    set +o pipefail
    __leadr_emit_candidates "$prefix" |
      FZF_DEFAULT_OPTS='' FZF_DEFAULT_OPTS_FILE='' command fzf \
        --height='~40%' \
        --layout=reverse \
        --border \
        --prompt='leadr> ' \
        --delimiter=$'\t' \
        --with-nth=1,2,3,4 \
        +m
  ); then
    status=0
  else
    status=$?
  fi

  case $status in
    0)
      key=${selected%%$'\t'*}
      if [[ ! ${__LEADR_MAP[$key]+present} ]]; then
        __leadr_error 'fzf returned an unknown mapping'
        return 2
      fi
      printf '%s' "$key"
      ;;
    1|130)
      return 1
      ;;
    *)
      __leadr_error "fzf failed with status $status"
      return 2
      ;;
  esac
}

# Produce a transformed line and byte cursor in caller-named variables.
__leadr_transform() {
  local mode=$1 payload=$2 original=$3 point=$4
  local line_output_name=$5 point_output_name=$6
  local clean=$payload before_cursor after_cursor before after
  local final final_point command_before
  local cursor_at=0 command_at=0 has_cursor=0
  local command_marker='#COMMAND' LC_ALL=C
  # shellcheck disable=SC2034 # nameref outputs are consumed by the caller.
  local -n line_output=$line_output_name point_output=$point_output_name

  [[ $point =~ ^[0-9]+$ ]] || point=0
  (( point <= ${#original} )) || point=${#original}

  if [[ $payload == *'#CURSOR'* ]]; then
    has_cursor=1
    before_cursor=${payload%%#CURSOR*}
    after_cursor=${payload#*#CURSOR}
    clean=${before_cursor}${after_cursor}
    cursor_at=${#before_cursor}
  fi

  case $mode in
    replace)
      final=$clean
      final_point=${#clean}
      (( has_cursor )) && final_point=$cursor_at
      ;;
    insert)
      final=${original:0:point}${clean}${original:point}
      final_point=$((point + ${#clean}))
      (( has_cursor )) && final_point=$((point + cursor_at))
      ;;
    prepend)
      final=${clean}${original}
      final_point=$((point + ${#clean}))
      (( has_cursor )) && final_point=$cursor_at
      ;;
    append)
      final=${original}${clean}
      final_point=${#final}
      (( has_cursor )) && final_point=$((${#original} + cursor_at))
      ;;
    surround)
      before=${clean%%#COMMAND*}
      after=${clean#*#COMMAND}
      final=${before}${original}${after}
      final_point=$((${#before} + point))

      if (( has_cursor )); then
        command_before=${payload%%#COMMAND*}
        command_at=${#command_before}
        if (( cursor_at < command_at )); then
          final_point=$cursor_at
        else
          final_point=$((cursor_at - ${#command_marker} + ${#original}))
        fi
      fi
      ;;
    *)
      __leadr_error "unknown transformation mode: ${mode@Q}"
      return 1
      ;;
  esac

  # shellcheck disable=SC2034 # nameref assignment is an output to the caller.
  line_output=$final
  # shellcheck disable=SC2034 # nameref assignment is an output to the caller.
  point_output=$final_point
}

__leadr_apply_mapping() {
  local key=$1 mode evaluate execute description flags payload
  local transformed cursor status

  if [[ ! ${__LEADR_MAP[$key]+present} ]]; then
    __leadr_error "unknown mapping: ${key@Q}"
    return 1
  fi
  __leadr_unpack_record "${__LEADR_MAP[$key]}" description flags payload
  __leadr_parse_flags "$flags" mode evaluate execute "$key" || return 1

  if (( evaluate )); then
    if payload=$(eval -- "$payload"); then
      :
    else
      status=$?
      __leadr_error "evaluation failed for ${key@Q} with status $status"
      return "$status"
    fi
    if [[ -z $payload ]]; then
      __leadr_error "evaluation produced no value for ${key@Q}"
      return 1
    fi
    if [[ $payload == *[$'\t\r\n']* ]]; then
      __leadr_error "evaluation produced multiline or tabbed output for ${key@Q}"
      return 1
    fi
  fi

  __leadr_transform \
    "$mode" "$payload" "${READLINE_LINE-}" "${READLINE_POINT-0}" \
    transformed cursor || return 1

  if (( ! execute )); then
    READLINE_LINE=$transformed
    READLINE_POINT=$cursor
    return 0
  fi

  READLINE_LINE=''
  READLINE_POINT=0
  printf '\n+ %s\n' "$transformed" >/dev/tty
  history -s -- "$transformed"
  if eval -- "$transformed"; then
    return 0
  else
    return $?
  fi
}

__leadr_invoke() {
  local sequence='' key='' selected='' old_int
  local interrupted=0 done=0 cancelled=0

  __leadr_require_init || return 1
  old_int=$(trap -p INT)
  trap 'interrupted=1' INT

  while (( ! done && ! cancelled )); do
    key=''
    if ! IFS= read -r -s -n 1 key </dev/tty; then
      cancelled=1
      break
    fi
    if (( interrupted )); then
      cancelled=1
      break
    fi

    case $key in
      $'\e'|$'\003')
        cancelled=1
        ;;
      $'\b'|$'\177')
        if [[ -n $sequence ]]; then
          sequence=${sequence%?}
        else
          cancelled=1
        fi
        ;;
      $'\t')
        if selected=$(__leadr_pick "$sequence"); then
          done=1
        else
          cancelled=1
        fi
        ;;
      '?')
        if [[ -z $sequence ]] && selected=$(__leadr_pick ''); then
          done=1
        else
          [[ -n $sequence ]] && printf '\a' >/dev/tty
          cancelled=1
        fi
        ;;
      [A-Za-z0-9])
        sequence+=$key
        if [[ ${__LEADR_MAP[$sequence]+present} ]]; then
          selected=$sequence
          done=1
        elif ! __leadr_has_prefix "$sequence"; then
          printf '\a' >/dev/tty
          cancelled=1
        fi
        ;;
      *)
        printf '\a' >/dev/tty
        cancelled=1
        ;;
    esac
  done

  if [[ -n $old_int ]]; then
    eval -- "$old_int"
  else
    trap - INT
  fi

  (( cancelled )) && return 0
  __leadr_apply_mapping "$selected"
}

__leadr_complete() {
  local current=${COMP_WORDS[COMP_CWORD]-}
  local key
  local -a keys=()

  COMPREPLY=()
  if [[ ${COMP_WORDS[0]-} == leadr_init ]]; then
    if (( COMP_CWORD == 2 )); then
      compopt -o filenames 2>/dev/null || :
      mapfile -t COMPREPLY < <(compgen -f -- "$current")
    fi
    return 0
  fi

  if (( COMP_CWORD == 1 )); then
    for key in help list show; do
      [[ $key == "$current"* ]] && COMPREPLY+=("$key")
    done
    return 0
  fi

  if [[ ${COMP_WORDS[1]-} == show && $COMP_CWORD == 2 && -n ${__LEADR_KEY-} ]]; then
    __leadr_sorted_keys keys
    for key in "${keys[@]}"; do
      [[ $key == "$current"* ]] && COMPREPLY+=("$key")
    done
  fi
}

complete -F __leadr_complete leadr leadr_init
