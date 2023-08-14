#!/bin/bash

# Check if the wrapper is installed
if [ ! -e /usr/local/src/bc_wrapper/bc_wrapper.sh ]; then
  printf '\033[1;31mFirst, install the wrapper using \033[3mmake\033[m\n' >&2
  exit 1
fi

# Find bc binary command
for bc_command in $(type -ap bc); do
  if grep -qI . ${bc_command}; then
    unset bc_command
    continue
  else
    break
  fi
done

# Exit wrapper if command doesn't exist or replace it with real
# BC when STDIN/STDOUT is not tty or when flag is being used
if [[ -z "${bc_command}" ]]; then
  printf '\033[1;3;31mbc\033[23m not found\033[m\n' >&2
  exit 1
elif [ ! -t 0 ]; then
  exec ${bc_command} ${@} < <(cat)
elif [ -n "${1}" -o ! -t 1 ]; then
  exec ${bc_command} ${@}
fi

# Overriding bc command to avoid recursion when this
# script is a priority in update-alternatives
bc() {
  ${bc_command} ${@}
}

# Installation stores functional files in this dir that the wrapper relies on
LIB_DIR='/usr/local/lib/bc_wrapper'

# Env var tells BC to not truncate output line length
export BC_LINE_LENGTH=0

BC_BASE=10
LINE_NUM=1
CONCURRENT_INPUT=1
SPINNER='━╲┃╱'
SATISFY_PS_DUMMY_LEN=''
PS_LEN=7
# `read` used for interaction with the user is fed with this PS_DUMMY to mimic
# the length of human visible PS (PS_READY and PS_BUSY) that `printf` outputs.
# This is done to be able to colorize PS without the drawback that `read` has.
# The drawback is: when the user starts manically pressing keys the `read` will
# miscalculate its length because of the terminal VT100 escape code.
# Manic users need all the support they can get... 🐼
PS_DUMMY=$'\033[G\033['"${SATISFY_PS_DUMMY_LEN}${PS_LEN}C"
PS_READY=$'\033[G\033[0K\033[1;32mBC\033[m:%02d> '
PS_SIGN='>'
PS_BUSY=$'\033[G\033[0K\033[1;33mBC\033[m:%02d%s '
PS_READ_INPUT=$'\033[G\033[0K\033[1;2;33mIN\033[0;2m:%02d\033[5;31m%s\033[m '
PS_CURRENT=''
STATEMENT_DONE_TRIGGER_MSG=$'/* \255 */#STATEMENT DONE'
STATEMENT_DONE_TRIGGER="; print \"${STATEMENT_DONE_TRIGGER_MSG}\\n\""

# Autocomplete statements, separated into several categories
COMPS_STATEMENTS='define fun() {|if () {|while () {|for (i=0; i<; ++i) {'
COMPS_KEYWORDS='print \"\"|last|history|warranty|limits|\$|\$\$|quit'
COMPS_STD='length(expr)|scale(expr)|sqrt(expr)|s(rad)|c(rad)|a(input)|l(arg)|e(exp)|j(order, arg)'
COMPS_VAR='scale = |base = |ibase = |obase = |concurrent_input = '
COMPS_EXT="$(awk -F '(^define *| *=|\\))' '
                  /^[a-z]+ *=[^=]/ { printf "%s|", $1 }
                  /^define / { printf "%s)|", $2 }
                ' ${LIB_DIR}/custom_functions.bc)"

FUNCTIONS_WITH_READ="read$(awk -F '[( ]' '
                            /^define / { tmp = $2 }
                            /[=	 ]+read *\(\)/ { functions = functions"|"tmp }
                          END { print functions }
                          ' ${LIB_DIR}/custom_functions.bc)"

HISTFILE=~/.bc_history
HISTCONTROL='ignoredups:ignorespace'
HISTSIZE=1000
HISTFILESIZE=2000
HISTTIMEFORMAT=$'\033[1;31m%T\033[33m %d/%m/%y ⮕\033[39m  '

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
autocomplete_print() {
  color=232

  printf '\n\033[48;5;%dm%*s\033[G' ${bg} ${max_cols} >&2
  printf '\033[1;48;5;%dm%*s\033[m' ${title_bg} "-${indent}" "${1}" >&2
}

autocomplete() {
  local IFS=$'|\n\t'

  if (( BC_STATEMENTS_LVL > 0 )); then
    declare -I COMPS_KEYWORDS+="|break|continue|halt|auto|return "
    COMPS_KEYWORDS="$(sed -E 's/\|?(warranty|limits)\|?/|/g' <<< "${COMPS_KEYWORDS}")"
  fi

  local AUTOCOMPLETE_OPTS="${COMPS_STATEMENTS}|${COMPS_KEYWORDS}|${COMPS_VAR}|${COMPS_STD}|${COMPS_EXT}"
  local trim_indent_line="${READLINE_LINE#${READLINE_LINE%%[![:space:]]*}}"
  local comps
  local i dist=0 indent=12
  local max_cols_st max_cols_kw max_cols_var max_cols_std max_cols_ext max_cols
  local comp row_len color bg title_bg st_done kw_done var_done std_done ext_done
  local common_substring
  local position_part

  refresh_read_cmd

  comps=( $(compgen -W "${AUTOCOMPLETE_OPTS}" -- "${trim_indent_line}") )
  if (( $? != 0 )); then
    printf '\a'
    return 1
  fi

  if (( ${#comps[@]} > 1 )); then
    for i in ${AUTOCOMPLETE_OPTS}; do
      (( dist < ${#i} )) && dist=${#i}
    done

    for i in ${comps[@]}; do
      if [[ "|${COMPS_STATEMENTS//\\}|" == *"|${i}|"* ]]; then
        (( max_cols_st += dist + 1 ))
      elif [[ "|${COMPS_KEYWORDS//\\}|" == *"|${i}|"* ]]; then
        (( max_cols_kw += dist + 1 ))
      elif [[ "|${COMPS_VAR//\\}|" == *"|${i}|"* ]]; then
        (( max_cols_var += dist + 1 ))
      elif [[ "|${COMPS_STD//\\}|" == *"|${i}|"* ]]; then
        (( max_cols_std += dist + 1 ))
      elif [[ "|${COMPS_EXT//\\}|" == *"|${i}|"* ]]; then
        (( max_cols_ext += dist + 1 ))
      fi
    done

    max_cols=$(printf "${max_cols_st}\n${max_cols_kw}\n${max_cols_var}\n${max_cols_std}\n${max_cols_ext}" | sort -n | tail -n 1)

    (( max_cols += indent ))

    while (( max_cols > COLUMNS )); do
      (( max_cols -= dist + 1 ))
    done

    for comp in ${comps[@]}; do
      if [[ -z "${st_done}" && "|${COMPS_STATEMENTS//\\}|" == *"|${comp}|"* ]]; then
        st_done=yes
        bg=238
        title_bg=237
        row_len=${indent}

        autocomplete_print 'Statements:'
      elif [[ -z "${kw_done}" && "|${COMPS_KEYWORDS//\\}|" == *"|${comp}|"* ]]; then
        kw_done=yes
        bg=239
        title_bg=236
        row_len=${indent}

        autocomplete_print 'Keywords:'
      elif [[ -z "${var_done}" && "|${COMPS_VAR//\\}|" == *"|${comp}|"* ]]; then
        var_done=yes
        bg=240
        title_bg=235
        row_len=${indent}

        autocomplete_print 'Variables:'
      elif [[ -z "${std_done}" && "|${COMPS_STD//\\}|" == *"|${comp}|"* ]]; then
        std_done=yes
        bg=241
        title_bg=234
        row_len=${indent}

        autocomplete_print 'Std Lib:'
      elif [[ -z "${ext_done}" && "|${COMPS_EXT//\\}|" == *"|${comp}|"* ]]; then
        ext_done=yes
        bg=242
        title_bg=233
        row_len=${indent}

        autocomplete_print 'Extras:'
      fi

      (( row_len += dist + 1 ))
      if (( row_len > COLUMNS )); then
        autocomplete_print
        (( row_len = indent + dist + 1 ))
      fi

      (( color = (color + 230) % 233 ))
      printf '\033[1;38;5;%d;48;5;%dm %*s\033[m' ${color} ${bg} "-${dist}" "${comp}" >&2

    done

    echo
    common_substring="$(printf "%s\n" "${comps[@]}" | sed -e '$!{N;s/^\(.*\).*\n\1.*$/\1\n\1/;D;}')"
    READLINE_LINE="${READLINE_LINE%%${common_substring:0:1}*}${common_substring}"
    READLINE_POINT="${#READLINE_LINE}"

  else
    if [[ "${comps[0]}" == *\) ]]; then
      READLINE_LINE="${READLINE_LINE%%${comps[0]:0:1}*}${comps[0]/(*)/()}"
    else
      READLINE_LINE="${READLINE_LINE%%${comps[0]:0:1}*}${comps[0]}"
    fi

    case "${comps[0]}" in
      for\ \(*++i*) position_part="${READLINE_LINE%%; ++i*}" ;;
      *\(*\)*) position_part="${READLINE_LINE%%\)*}" ;;
      print\ *) position_part="${READLINE_LINE%\"*}" ;;
      *) position_part="${READLINE_LINE}" ;;
    esac

    READLINE_POINT="${#position_part}"
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

trap refresh_PS_CURRENT_using_read 28
trap trap_SIGINT 2
trap trap_EXIT 0

history -r

set -f -o emacs
bind 'set enable-bracketed-paste off'
for fun in reverse-search-history forward-search-history possible-filename-completions\
           possible-hostname-completions possible-username-completions clear-screen\
           possible-variable-completions possible-completions clear-display\
           possible-command-completions insert-completions glob-list-expansions\
           glob-complete-word edit-and-execute-command dynamic-complete-history\
           display-shell-version complete-command complete-filename complete-hostname\
           complete-into-braces complete-username complete-variable complete
do
  bind -u ${fun}
done
bind -x '"\C-i":"autocomplete"'
bind -x '"\C-~":"refresh_PS_CURRENT"'
bind -x '"\C-l":"clear -x; refresh_PS_CURRENT_using_read"'
bind -x '"\e\C-l":"clear; refresh_PS_CURRENT_using_read"'

coproc BC {
  trap '' 2

  bc -liq ${LIB_DIR}/custom_functions.bc |&
    while IFS= read -r bc_output; do
      case "${bc_output}" in
        *interrupt*)
          if [[ -n "${postpone_PS_READY}" ]]; then
            unset postpone_PS_READY
          fi

          if [[ -n "${statement_interrupted}" ]]; then
            unset statement_interrupted
            continue
          fi

          printf '\033[G\033[0K\033[1;33m%s\033[m\n' "${bc_output}" >&2
          ;;
        *standard_in*|*error*)
          fix_err_line_num_and_print "${bc_output}"
          ;;
        *warning*)
          printf '\033[G\033[0K\033[1;35m%s\033[m\n' "${bc_output}" >&2
          ;;
        *$'/* \254 */#'*) # Type of input that shouldn't print green PS, e.g. 2^222222
          (( LINE_NUM = $(grep -o '^[0-9]*' <<< ${bc_output##*#}) ))

          # Upon receiving SIGINT, trap_SIGINT() close all statements with "}". That
          # could potentially cause infinite loop in a background e.g. while (1) {}
          # so SIGINT is sent to interrupt that.
          if [[ "${bc_output}" == *$'/* \254 */#SIGINT inside statement#'* ]]; then
            statement_interrupted=yes
            kill -s 2 0
          fi

          # When some statement has iterative calculations, this prevents PS_READY
          # to appear after the first successful calculation. It waits until the
          # statement is done, e.g. for (i=0; i<10; ++i) 2^222222. Also, it is
          # needed when BC's read() is inside the iterator to keep PS_READ_INPUT.
          if [[ "${bc_output}" == *"${STATEMENT_DONE_TRIGGER}"* ]]; then
            postpone_PS_READY=true
          fi

          continue
          ;;
        *$'/* \255 */#'*) # Type of input that should print green PS, e.g. a = 2
          if [[ -n "${postpone_PS_READY}" ]]; then
            if [[ "${bc_output}" == "${STATEMENT_DONE_TRIGGER_MSG}" ]]; then
              unset postpone_PS_READY
            else
              continue
            fi
          else
            (( LINE_NUM = $(grep -o '^[0-9]*' <<< ${bc_output##*#}) ))

            if [[ "${bc_output}" =~ ^\ *(warranty|limits)\ +/\*\  ]]; then
              while read -t 0; do
                IFS= read -r line
                printf '\033[G\033[0K%s\n' "${line}" >&2
              done
            fi
          fi

          ;;
        *?*)
          printf '\033[G\033[0K\033[1;35m=>\033[39m %s\033[m\n' "${bc_output}" >&2

          # If there is a looped output (e.g. while (1) { print "hi" }),
          # don't print PS until the loop is done
          if (( old_LINE_NUM == LINE_NUM )); then
             read -t 0 && continue
          else
            (( old_LINE_NUM=LINE_NUM ))
          fi
          ;;
      esac

      if [[ -z "${postpone_PS_READY}" ]]; then
        printf "${PS_READY}\n" ${LINE_NUM}
      fi
      refresh_PS_CURRENT_using_read
    done

  kill -0 $$ &>/dev/null && ${LIB_DIR}/write_to_STDIN 
}

# Feed BC with wrapper's special variables in case user wants to check values.
echo "base = ${BC_BASE}"$' /* \254 */#'"${LINE_NUM}" >&${BC[1]}
echo "concurrent_input = ${CONCURRENT_INPUT}"$' /* \254 */#'"${LINE_NUM}" >&${BC[1]}

assign_and_print_PS_CURRENT "${PS_READY}" ${LINE_NUM}

while IFS= read -erp "${PS_DUMMY}" ${INDENT} input; do
  if [[ "${input//;}" =~ ^[[:space:]]*$ ]]; then
    printf '%s' "${PS_CURRENT}" >&2
    continue
  elif [[ "${countdown_to_feed_BC_read}" == 0 ]]; then
    refresh_PS_CURRENT
    if [[ "${PS_CURRENT}" != *'IN'* ]]; then
      unset countdown_to_feed_BC_read
    else
      echo "${input}" >&${BC[1]}
      continue
    fi
  elif read -t 0; then
    create_list

    input_list_line_num="$(wc -l <<< "${input_list}")"

    if (( input_list_line_num < 2 )); then
      unset input_list
    elif [[ "${input_list//$'\n'}" == *[^0-9]* ]]; then
      CONCURRENT_INPUT=0
      input_list_counter=0

      history -s -- "${input}"
    else
      modify_list_of_num

      if [[ -z "${input_list}" ]]; then
        printf '%s' "${PS_CURRENT}" >&2
        continue
      fi
    fi

  elif [[ "${input}" =~ (#|/\*) ]]; then
    history -s -- "${input}"
    comment_type="${BASH_REMATCH[1]}"

    if [[ "${comment_type}" == '/*' ]]; then
      input="$(sed 's,/\*[^*/]*\(\*/\)\?,,g' <<< "${input}")"
      printf '\033[1;35mMulti-line comments are not supported.\033[m\n' >&2
    else
      input="${input%%${comment_type}*}"
    fi

    if [[ "${input}" =~ ^[[:space:]]*$ ]]; then
      printf '%s' "${PS_CURRENT}" >&2
      continue
    fi
  else
    history -s -- "${input}"
  fi

  (( LINE_NUM++ ))

  if (( LINE_NUM > 99 )); then
    PS_LEN=$(( 5 + ${#LINE_NUM} ))
    SATISFY_PS_DUMMY_LEN="$(printf '0%.0s' $(seq 3 ${#LINE_NUM}) )"
    PS_DUMMY=$'\033[G\033['"${SATISFY_PS_DUMMY_LEN}${PS_LEN}C"
  fi

  if [[ -n "${input_list}" ]]; then
    input="${input_list}"
    unset input_list
    IFS=$'\n'
  elif [[ "${input}" =~ (^|[[:space:]]+)for[[:space:]]*\(.*\; ]]; then
    IFS=$'\n'
  else
    IFS=$';\n'
  fi

  for statement in ${input}; do
    [[ "${statement}" =~ ^[[:space:]]*$ ]] && continue

    if [ -n "${input_list_counter}" ] && (( input_list_counter++ > 0 )); then
      history -s -- "${statement}"
      (( LINE_NUM++ ))

      printf '%s\n' "${statement}"

      if (( input_list_counter == input_list_line_num )); then
        unset input_list_counter
        CONCURRENT_INPUT="${concurrent_input:-1}"
      fi
    fi

    statement="${statement//$'\t'/ }"
    input_type=$'/* \254 */'

    if [[ "${statement}" == *\"* ]]; then
      if (( BC_STATEMENTS_LVL == 0 )) && [[ "${statement}" =~ ^\ *\" ]]; then
        input_type=$'/* \255 */'
      fi

      if [[ "${statement}" != *\"*\"* ]]; then
        printf '\033[G\033[0K\033[1;31mSyntax error: multi-line ' >&2
        printf '\033[3mstring\033[0;1;31m not supported\033[m\n' >&2

        statement='/* ignore */'
      fi
    fi

    if [[ "${statement}" =~ ^\ *history\ *$ ]]; then
      history >&2

      ignore_input_BC
    elif [[ "${statement}" =~ ^\ *\$\$\ *$ ]]; then
      bash -li

      ignore_input_BC
    elif [[ "${statement}" =~ ^\ *\$ ]]; then
      statement="$(bash -c "${statement#*\$}" 2>&1)"

      if (( $? != 0 )); then
        if [[ -n "${statement}" ]]; then
          fix_err_line_num_and_print "${statement}"
        else
          printf '\033[G\033[0K\033[1;31mNon-zero exit code received.\033[m\n'
        fi

        ignore_input_BC
      elif [[ -z "${statement}" ]]; then
        printf '\033[G\033[0K\033[1;35mWarning: Bash output ' >&2
        printf 'seems to be empty. Nothing to do...\033[0m\n' >&2

        ignore_input_BC
      else
        printf '\033[G\033[0K\033[1;35mWarning: Bash output ' >&2
        printf "goes into BC's input automatically.\033[0m\n" >&2
      fi
    elif [[ "${statement}" =~ ^\ *concurrent_input\ *=\ *([^=; ]+) ]]; then
      if [[ "${BASH_REMATCH[1]}" == [01] ]]; then
        concurrent_input=${BASH_REMATCH[1]}
        CONCURRENT_INPUT=${concurrent_input}
      else
        printf '\033[G\033[0K\033[1;35mWarning: Special variable ' >&2
        printf 'accepts 1 or 0 to switch concurrent input on/off.\n' >&2

        ignore_input_BC
      fi
    elif [[ "${statement}" == *\?* && "${statement}" =~ ^\ *\??\ *([^?]*)\ *\??\ *$ ]]; then
      if [[ -n "${BASH_REMATCH[1]}" ]]; then
        for fun in ${BASH_REMATCH[1]// /$'\n'}; do
          while read -r line; do
            if [[ "${line}" == '/*' ]]; then
              while read -r line; do
                [[ "${line}" == '*/' ]] && break
                help+="      ${line}"$'\n'
              done
              read -r line
            fi

            if [[ "${line}" =~ ^\ *define\ +(${fun%%\(*}\([^\)]*\)) ]]; then
              function="${BASH_REMATCH[1]}"

              if [[ -n "${help}" ]]; then
                help=$'\033[1mHelp: \033[34m'"${function}"$'\033[m\n'"${help}"
              else
                help=$'\033[1;35mNo help written for \033[3m'"${function}"$'\033[m\n'
              fi

              break
            else
              unset help
            fi
          done < <(<${LIB_DIR}/custom_functions.bc)

          if [[ -n "${help}" ]]; then
            help_all+="${help}"$'\n'
          else
            help_all+=$'\033[1;35mUnknown function: \033[3m'"${fun%%\(*}()"$'\033[m\n\n'
          fi

          unset fun line help function
        done

        printf '%s' "${help_all}"
        unset help_all
      else
        printf $'\033[1;3;35m?\033[23m provides help for custom functions, try: ?<tab>\033[m\n'
      fi

      ignore_input_BC
    elif [[ "${statement}" =~ \ *print( *\".*\"| +.+) ]]; then
      statement="$(sed -E 's/print(.*,)? *(".*"|[^ ;]+)/&, "\\n"/' <<< "${statement}")"

    elif [[ "${statement}" =~ ^\ *(warranty|limits)\ *$ ]]; then
      if (( BC_STATEMENTS_LVL == 0 )); then
        input_type=$'/* \255 */'
      else
        statement='/* ignore */'
      fi

    elif [[ "${statement}" =~ (^| +)([io]?base)\ *=\ *(-?[0-9]+)( +|$) ]]; then
      input_base="${BASH_REMATCH[3]}"

      if (( input_base > 16 )); then
        printf '\033[G\033[0K\033[1;35mWarning: base too large, set to 16\033[0m\n' >&2
        input_base=16
      elif (( input_base < 2 )); then
        printf '\033[G\033[0K\033[1;35mWarning: base too small, set to 2\033[0m\n' >&2
        input_base=2
      fi

      adjusted_base="$(bc <<< "obase=${BC_BASE}; ${input_base}")"

      case "${BASH_REMATCH[2]}" in
        base)
          statement="base=${adjusted_base};obase=${adjusted_base};ibase=${adjusted_base}"
          BC_BASE="${input_base}"
          ;;
        ibase)
          statement="ibase=${adjusted_base}"
          BC_BASE="${input_base}"
          ;;
        obase)
          statement="obase=${adjusted_base}"
          ;;
      esac
    fi

    # Create indentation when nesting and also decides if the user's input should
    # get output from BC or not. E.g., input a = 2 doesn't output anything so PS
    # can immediately be green, but input 2^2222222 will output the calculation
    # and only then the script will colorize PS into the green.
    # Also, this madness exists because BC act "weird" when an error happens
    # inside the statement body. BC drops the whole statement input when an error
    # happens, but doesn't close the statement's body ("}"). Therefore, the user's
    # input is examined before sending it to BC so that the user can continuously
    # write code inside the statement's body even when input yells an error.
    if [[ "${statement}" == *[{}]* ]]; then
      opening_braces_num=$(printf "${statement//[^\{]}" | wc -c)
      closing_braces_num=$(printf "${statement//[^\}]}" | wc -c)

      if (( BC_STATEMENTS_LVL + opening_braces_num == closing_braces_num )); then
        test_input="${whole_statement}${statement%\}*}"$'\nquit\n}'"${statement##*\}}"
      else
        test_input="${whole_statement}${statement}"$'\nquit'
      fi

      test_output="$(bc -lq <<< "${test_input}" |& grep 'standard_in')"
      if (( $? == 0 )); then
        fix_err_line_num_and_print "${test_output}"

        ignore_input_BC
      else
        unset oneliner_statement
        whole_statement+="${statement}"$'\n'

        (( BC_STATEMENTS_LVL += opening_braces_num - closing_braces_num ))

        if (( BC_STATEMENTS_LVL > 0 )); then
          PS_SIGN=$'\033[31m{\033[m'
          INDENT="-i$(printf "%$(( BC_STATEMENTS_LVL * 2 ))s")"
        elif [[ "${statement}" =~ \}\ *else\ * ]]; then
          oneliner_statement=possible
          unset INDENT
        else
          PS_SIGN='>'
          unset INDENT
          unset whole_statement

          statement+="${STATEMENT_DONE_TRIGGER}"
        fi
      fi

    elif [[ "${statement}" =~ ^\ *((if|while|for)\ *\([^\)]*\)\ *)+$ ]]; then
      test_output="$(bc -lq <<< "${whole_statement}${statement}"$'\nquit' |& grep 'standard_in')"
      if (( $? == 0 )); then
        fix_err_line_num_and_print "${test_output}"

        statement='/* ignore */'
      else
        whole_statement+="${statement}"$'\n'
        oneliner_statement=possible
        PS_SIGN=$'\033[31m{\033[m'
      fi

    elif [[ -n "${oneliner_statement}" || "${statement}" =~ ^\ *(if|while|for)\ *\( ]]; then
      test_output="$(bc -lq <<< "${whole_statement}${statement}; quit" |& grep 'standard_in')"
      if (( $? == 0 )); then
        fix_err_line_num_and_print "${test_output}"

        assign_and_print_PS_CURRENT "${PS_BUSY}" ${LINE_NUM} "${PS_SIGN}"
        (( LINE_NUM-- ))
        continue 2
      elif (( BC_STATEMENTS_LVL > 0 )); then
        whole_statement+="${statement}"$'\n'
      else
        PS_SIGN='>'
        unset whole_statement
        statement+="${STATEMENT_DONE_TRIGGER}"
      fi

      unset oneliner_statement

    elif (( BC_STATEMENTS_LVL > 0 )); then
      test_output="$(bc -lq <<< "${whole_statement}${statement}"$'\nquit' |& grep 'standard_in')"
      if (( $? == 0 )); then
        fix_err_line_num_and_print "${test_output}"

        statement='/* ignore */'
      else
        whole_statement+="${statement}"$'\n'
      fi

    elif [[ "${statement}" =~ ^\ *[a-z0-9_]+(\[.+\])?\ *[%^*/+-]?=[^=] ]]; then
      input_type=$'/* \255 */'

    fi

    # BC's read() is quirky at processing input, buffering, etc. This block of code tries to
    # mimic the same weird and confusing behavior (if not even surpass it) of GNU BC's read().
    if (( countdown_to_feed_BC_read > 0 && BC_STATEMENTS_LVL == 0 )); then
      (( countdown_to_feed_BC_read-- ))
      assign_and_print_PS_CURRENT "${PS_READ_INPUT}" ${LINE_NUM} "${PS_SIGN}"
    elif [[ "${statement}" != *'define '* && "${statement}" =~ (^|[= ])(${FUNCTIONS_WITH_READ})\ *\( ]]; then
      if (( BC_STATEMENTS_LVL > 0 )); then
        new_function_with_read="$(grep -Po '^ *define +\K[^( ]+' <<< "${whole_statement}")"
        if (( $? == 0 )); then
          FUNCTIONS_WITH_READ+="|${new_function_with_read}"
        else
          countdown_to_feed_BC_read=1
        fi
        assign_and_print_PS_CURRENT "${PS_BUSY}" ${LINE_NUM} "${PS_SIGN}"
      else
        statement+="${STATEMENT_DONE_TRIGGER}"
        assign_and_print_PS_CURRENT "${PS_READ_INPUT}" ${LINE_NUM} "${PS_SIGN}"
        countdown_to_feed_BC_read=0
        input_type=$'/* \254 */'
      fi
    else
      assign_and_print_PS_CURRENT "${PS_BUSY}" ${LINE_NUM} "${PS_SIGN}"
    fi

    # Feeding BC with the user's input
    echo "${statement} ${input_type}#${LINE_NUM}" >&${BC[1]}

    if (( CONCURRENT_INPUT + BC_STATEMENTS_LVL == 0 )) && [ -z "${countdown_to_feed_BC_read}" ]; then
      printf '\033[?25l\033[1;33m'

      unset i
      while sleep 0.12; do printf "${SPINNER:i++%4:1}\033[D" >&2; done &
      spinner_pid=$(jobs -p %)

      while read -srn 1 calc_finished; do
        if [[ "${calc_finished}" == $'\036' ]]; then
          refresh_PS_CURRENT
          break
        fi
      done

      printf '\033[?25h\033[m'
      if kill -0 ${spinner_pid} &>/dev/null; then
        kill ${spinner_pid}
      else
        unset input_list_counter
        CONCURRENT_INPUT="${concurrent_input:-1}"
        continue 2
      fi
    fi
  done
done

