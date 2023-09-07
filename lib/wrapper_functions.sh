assign_and_print_PS_CURRENT() {
  PS_CURRENT="$(printf "${@}")"
  printf '%s' "${PS_CURRENT}" >&2
}

# Called indirectly by "readline" when <CTRL><~> is sent to `read -e` (or more
# precisely, when refresh_PS_CURRENT_using_read() is executed). Then it assigns
# the PS_READY to ${PS_CURRENT} if `coproc BC` finished a given task.
# Making this mess came from the need to synchronize `coproc BC` with the main shell.
refresh_PS_CURRENT() {
  while read -t 0 -u ${BC[0]}; do
    IFS= read -ru ${BC[0]} PS_CURRENT
  done

  printf '%s' "${PS_CURRENT}" >&2
}

# This triggers refresh_PS_CURRENT(). Used when `read` removes `printf`'s PS
# (PS_READY, PS_BUSY, etc) on SIGWINCH received, on autocomplete, and primarily when
# `coproc BC` finishes a task so that ${PS_CURRENT} can be updated in the main shell.
refresh_PS_CURRENT_using_read() {
  ${LIB_DIR}/write_to_STDIN 
}

# When SIGINT is received, BC does not clean STDIN. This function
# flushes STDIN and resets any nested statement.
trap_SIGINT() {
  ${LIB_DIR}/write_to_STDIN 

  if (( BC_STATEMENTS_LVL > 0 )); then
    unset INDENT
    PS_SIGN='>'
    while (( --BC_STATEMENTS_LVL > 0 )); do
      echo $'} /* \254 */#'"${LINE_NUM}" >&${BC[1]}
    done
    echo $'} /* \254 */#SIGINT inside statement#'"${LINE_NUM}" >&${BC[1]}

    unset whole_statement
  fi
}

trap_EXIT() {
  printf '\033[?25h\033[G\033[0K'
  history -a

  # `kill 0` would cause "Terminated" message and `wait` wouldn't help because it
  # wouldn't be executed at all. To avoid that message, child processes are
  # `kill`-ed one by one, from youngest to oldest.
  for pid in $(pgrep -g $$ | sort -nr); do
    (( pid == $$ )) && continue
    kill ${pid} &>/dev/null && wait ${pid} &>/dev/null
  done
}

fix_err_line_num_and_print() {
  local line_num_fixed="$(sed "s/ [0-9]*: / $(( LINE_NUM - 1 )): /" <<< "${1}")"
  printf '\033[G\033[0K\033[1;31m%s\033[m\n' "${line_num_fixed}" >&2
}

# Helper function for autocomplete(), helpless attempt to make this wet script DRY...
autocomplete_begin_new_row() {
  color=232
  if [[ -n "${1}" ]]; then
    (( ++bg ))
    (( --title_bg ))
    row_len=${indent}
  fi

  # Colorize bg for the whole row in advance
  printf '\n\033[48;5;%dm%*s\033[G' ${bg} ${max_columns} >&2
  # Place titles at the beginning of the row
  printf '\033[1;48;5;%dm%*s\033[m' ${title_bg} "-${indent}" "${1}" >&2
}

autocomplete() {
  refresh_PS_CURRENT_using_read

  local IFS=$'|\n\t'
  declare -I COMPS_STATEMENTS COMPS_KEYWORDS COMPS_VAR COMPS_STD COMPS_EXT

  local delimiters='"(?{<>,;=%^/*+-'
  local line_before_cursor="${READLINE_LINE::${READLINE_POINT}}"
  local line_after_cursor="${READLINE_LINE:${READLINE_POINT}}"
  local line_split_last_token="${line_before_cursor##*[${delimiters}]}"
  local line_split_2nd_last_token
  local line_split_last_delimiter="${line_before_cursor%${line_split_last_token}*}"

  local print_info='INFO: Wrapper appends new-line to print.'
  local comps_tmp comps_selections comps_final comps comp
  local indent=12
  local max_columns max_columns_st max_columns_kw max_columns_var max_columns_std max_columns_ext
  local st_done kw_done var_done std_done ext_done sel_done
  local row_len color bg=238 title_bg=237
  local line_before_cursor_with_comp common_substring position_part

  line_split_last_token="${line_split_last_token#${line_split_last_token%%[![:space:]]*}}"
  line_split_last_delimiter="${line_split_last_delimiter##*[^${delimiters}]}"
  line_split_2nd_last_token="${line_before_cursor%${line_split_last_delimiter}*}"
  line_split_2nd_last_token="${line_split_2nd_last_token##*[${delimiters}]}"
  line_split_2nd_last_token="${line_split_2nd_last_token#${line_split_2nd_last_token%%[![:space:]]*}}"

  if (( BC_STATEMENTS_LVL > 0 )); then
    comps_tmp='halt|auto|return |continue|break|} else if () {|} else {'

    COMPS_STATEMENTS="${COMPS_STATEMENTS/define fun() \{}"
    COMPS_KEYWORDS="${COMPS_KEYWORDS/limits}"
    COMPS_KEYWORDS="${COMPS_KEYWORDS/warranty}"
    COMPS_KEYWORDS+="|halt"

    if [[ ${whole_statement} =~ ^\ *define\  ]]; then
      COMPS_KEYWORDS+='|auto|return '
    fi
    if [[ ${whole_statement} =~ (^|$'\n')\ *(for|while)\ *\( ]]; then
      COMPS_KEYWORDS+='|continue|break'
    fi
    if [[ ${whole_statement} =~ (^|$'\n')\ *if\ *\( ]]; then
      COMPS_STATEMENTS="${COMPS_STATEMENTS/if () \{/if () {|\} else if () {|\} else {}"
    fi
  fi

  case "${line_split_last_delimiter}" in
    \?|[\;\{]\?)
      # Remove variables from ${COMPS_EXT}
      comps_final="$(sed -E 's/[^\|)]+(\||$)//g' <<< "${COMPS_EXT}")"
      ;;
    =|[%^/*+-]=)
      unset COMPS_STATEMENTS COMPS_KEYWORDS COMPS_VAR comps_tmp

      case "${line_split_2nd_last_token} " in
        concurrent_input\ *)
          comps_selections='0|1'
          comps_final="${comps_selections}"
          ;;
        base\ *|[io]base\ *)
          comps_selections="$(seq ${BASE_MIN} ${BASE_MAX} | tr '\n' '|')"
          comps_final="${comps_selections}"
          ;;
        *)
          comps_final="${COMPS_STD}|${COMPS_EXT}"
          ;;
      esac
      ;;
    \"|\"\")
      if [[ "${line_split_2nd_last_token%% *}" == 'print' ]]; then
        printf '\033[1;35m%*s\033[m\n' $(( (COLUMNS + ${#print_info}) / 2 )) "${print_info}"
      fi

      return 0
      ;;
    [\(\<\>,%^/*+-]|[=\<\>]=)
      unset COMPS_STATEMENTS COMPS_KEYWORDS COMPS_VAR comps_tmp
      comps_final="${COMPS_STD}|${COMPS_EXT}"
      ;;
    *)
      comps_final="${COMPS_STATEMENTS}|${COMPS_KEYWORDS}|${COMPS_VAR}|${COMPS_STD}|${COMPS_EXT}"
      ;;
  esac

  comps=( $(compgen -W "${comps_final}" -- "${line_split_last_token,,}") )
  if (( $? != 0 )); then
    printf '\a'
    return 1
  fi

  if (( ${#comps[@]} > 1 )); then
    # max_columns (on which depends the length of autocomplete table) should be
    # limited by the terminal length or by the length of the currently longest category.
    if [[ -n "${comps_selections}" ]]; then
      (( max_columns = $(wc -w <<< "${comps_selections//|/ }") * (MAX_COMP_LEN + 1) ))
    else
      # Find the longest category from the current completions
      for comp in ${comps[@]}; do
        if [[ "|${COMPS_STATEMENTS//\\}|" == *"|${comp}|"* ]]; then
          (( max_columns_st += MAX_COMP_LEN + 1 ))
        elif [[ "|${COMPS_KEYWORDS//\\}|" == *"|${comp}|"* ]]; then
          (( max_columns_kw += MAX_COMP_LEN + 1 ))
        elif [[ "|${COMPS_VAR//\\}|" == *"|${comp}|"* ]]; then
          (( max_columns_var += MAX_COMP_LEN + 1 ))
        elif [[ "|${COMPS_STD//\\}|" == *"|${comp}|"* ]]; then
          (( max_columns_std += MAX_COMP_LEN + 1 ))
        elif [[ "|${COMPS_EXT//\\}|" == *"|${comp}|"* ]]; then
          (( max_columns_ext += MAX_COMP_LEN + 1 ))
        fi
      done

			max_columns="$(sort -n <<-EOF | tail -n 1
				${max_columns_st}
				${max_columns_kw}
				${max_columns_var}
				${max_columns_std}
				${max_columns_ext}
			EOF
			)"
    fi

    (( max_columns += indent ))

    while (( max_columns > COLUMNS )); do
      (( max_columns -= MAX_COMP_LEN + 1 ))
    done

    for comp in ${comps[@]}; do
      if [[ -z "${st_done}" && "|${COMPS_STATEMENTS//\\}|" == *"|${comp}|"* ]]; then
        st_done=yes

        autocomplete_begin_new_row 'Statements:'
      elif [[ -z "${kw_done}" && "|${COMPS_KEYWORDS//\\}|" == *"|${comp}|"* ]]; then
        kw_done=yes

        autocomplete_begin_new_row 'Keywords:'
      elif [[ -z "${var_done}" && "|${COMPS_VAR//\\}|" == *"|${comp}|"* ]]; then
        var_done=yes

        autocomplete_begin_new_row 'Variables:'
      elif [[ -z "${std_done}" && "|${COMPS_STD//\\}|" == *"|${comp}|"* ]]; then
        std_done=yes

        autocomplete_begin_new_row 'Std Lib:'
      elif [[ -z "${ext_done}" && "|${COMPS_EXT//\\}|" == *"|${comp}|"* ]]; then
        ext_done=yes

        autocomplete_begin_new_row 'Extras:'
      elif [[ -z "${sel_done}" && -n "${comps_selections}" ]]; then
        sel_done=yes

        autocomplete_begin_new_row 'Selections:'
      fi

      (( row_len += MAX_COMP_LEN + 1 ))
      if (( row_len > COLUMNS )); then
        autocomplete_begin_new_row

        (( row_len = indent + MAX_COMP_LEN + 1 ))
      fi

      (( color = (color + 230) % 233 ))
      [[ "|${comps_tmp//\\}|" == *"|${comp}|"* ]] && printf '\033[2m' >&2
      printf '\033[1;38;5;%d;48;5;%dm %*s\033[m' ${color} ${bg} "-${MAX_COMP_LEN}" "${comp}" >&2

    done

    echo

    if (( ${#comps[@]} != $(grep -cv '^$' <<< "${comps_final//|/$'\n'}") )); then
      common_substring="$(printf "%s\n" "${comps[@]}" | sed -e '$!{N;s/^\(.*\).*\n\1.*$/\1\n\1/;D;}')"
      if (( ${#common_substring} > ${#line_split_last_token} )); then
        line_before_cursor_with_comp="${line_before_cursor%${line_split_last_token}*}${common_substring}"

        READLINE_LINE="${line_before_cursor_with_comp}${line_after_cursor}"
        READLINE_POINT=${#line_before_cursor_with_comp}
        READLINE_MARK=${READLINE_POINT}
      fi
    fi

  else
    if [[ "${comps[0]}" == *\) ]]; then
      comp="${comps[0]/(*)/()}"
    else
      comp="${comps[0]}"
    fi

    line_before_cursor_with_comp="${line_before_cursor%${line_split_last_token}*}${comp}"

    case "${comp}" in
      for\ \(*++i*) position_part="${line_before_cursor_with_comp%; ++i*}" ;;
      *\(*\)*) position_part="${line_before_cursor_with_comp%\)*}" ;;
      print\ *) position_part="${line_before_cursor_with_comp%\"*}" ;;
      *) position_part="${line_before_cursor_with_comp}" ;;
    esac

    READLINE_LINE="${line_before_cursor_with_comp}${line_after_cursor}"
    READLINE_POINT=${#position_part}
    READLINE_MARK=${#position_part}
  fi
}

create_list() {
  local list_line
  [[ "${input}" =~ ^[[:space:]]*$ ]] || input_list="${input}"$'\n'

  while :; do
    IFS= read -ser list_line
    [[ "${list_line}" =~ ^[[:space:]]*$ ]] || input_list+="${list_line}"$'\n'

    read -t 0 || break
  done

  input_list="${input_list:0:-1}"
}

modify_list_of_num() {
  local answer ascii_char_octal

  local PS_opts='Available options [+-*/aosdq]: [ ]'
  local PS_desc='(a - average, o - output, s - sort, d - descending sort, q - quit)'
  local input_position=$'\033[G\033['"$(( ${#PS_opts} - 2 ))C"

  local PS=$'\033[G\033[0K\033[1;35m'"${PS_opts}"$'\033[m\n'"${PS_desc}"$'\033[A'"${input_position}"
  local PS_wrong=$'\033[4C\033[1;31m'"Input unknown${input_position}"

  stty -echo

  input_list="${input_list// }"
  printf '\033[?25l\033[G\033[0KList detected: %s\n\n' "${input_list//$'\n'/, }"

  while IFS= read -srN 1 -p "${PS}" answer; do
    case "${answer}" in
      [+\-/*]) input_list="${input_list//$'\n'/${answer}}" ;;
      a) input_list="(${input_list//$'\n'/+}) / ${input_list_line_num}" ;;
      o) input_list="${input_list//$'\n'/;}" ;;
      s) input_list="$(sort -n <<< "${input_list}" | tr '\n' ';')" ;;
      d) input_list="$(sort -rn <<< "${input_list}" | tr '\n' ';')" ;;
      q) unset input_list ;;
      []) # Caught when SIGINT received, thanks to trap_SIGINT
        unset input_list
        read -n 1000 -t 0.005
        printf "${PS}"
        answer=q
        ;;
      *) # Any other input will warn the user and loop again
        if (( $(printf -- '%s' "${answer}" | wc -c) > 1 )); then
          answer=?
        else
          ascii_char_octal=$(printf -- '%s' "${answer}" | od -dA n)
          if (( ascii_char_octal < 32 || ascii_char_octal > 126 )); then
            answer=?
          fi
        fi

        IFS= read -t 0.8 -srN 1 -p "${PS_wrong}${answer}" answer

        if (( $(printf -- '%s' "${answer}" | wc -c) == 1 )); then
          ascii_char_octal=$(printf -- '%s' "${answer}" | od -dA n)

          if (( ascii_char_octal > 31 && ascii_char_octal < 127 )); then
            ${LIB_DIR}/write_to_STDIN ${answer}
          fi
        fi

        continue
        ;;
    esac

    break
  done

  printf '\033[1;32m%s\033[m\033[?25h\n' "${answer}"
  stty echo
}

ignore_input_BC() {
  statement='/* ignore */'
  (( BC_STATEMENTS_LVL == 0 )) && input_type=$'/* \255 */'
}

