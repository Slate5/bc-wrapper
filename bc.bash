#!/bin/bash

# Find bc binary command
for bc_command in $(type -ap bc); do
  if grep -qI . ${bc_command}; then
    unset bc_command
    continue
  else
    break
  fi
done

if [[ -z "${bc_command}" ]]; then
  printf '\033[1;3;31mbc\033[23m not found\033[m\n' >&2
  exit 1
fi

# Overriding bc command to avoid recursion when this
# script is a priority in update-alternatives
bc() {
  ${bc_command} ${@}
}

# Gives a user real BC when STDIN/STDOUT is not tty or when flag is being used
if [ ! -t 0 ]; then
  cat | bc ${@}
  exit
elif [ -n "${1}" -o ! -t 1 ]; then
  bc ${@}
  exit
fi

# Env var tells BC to not truncate output line length
export BC_LINE_LENGTH=0

BC_BASE=10
LINE_NUM=1
SATISFY_PS_DUMMY_LEN=''
PS_LEN=7
# `read` used for interaction with the user is fed with this PS_DUMMY to mimic
# the length of human visible PS (PS_READY and PS_BUSY) that `printf` outputs.
# This is done to be able to colorize PS without the drawback that `read` has.
# The drawback is: when the user starts manically pressing keys the `read` will
# miscalculate its length because of the terminal VT100 escape code.
# Manic users need all the support they can get... 🐼
PS_DUMMY=$'\033[G\033['"${SATISFY_PS_DUMMY_LEN}${PS_LEN}C"
PS_READY=$'\033[G\033[1;32mBC\033[m:%02d> '
PS_SIGN='>'
PS_BUSY=$'\033[G\033[1;33mBC\033[m:%02d%s '

# Autocomplete statements, separated into 4 classes
COMPS_STATEMENTS='define f() {|if () {|while () {|for (i=1; i<; ++i) {'
COMPS_KEYWORDS='print \"\"|last|history|\$|\$\$|quit'
COMPS_VAR='scale = |base = |ibase = |obase = '
COMPS_LIB='length()|scale()|sqrt()|s()|c()|a()|l()|e()|j()'

HOME_DIR="$(dirname $(readlink -en $0))"

HISTFILE=${HOME_DIR}/.bc_history
HISTCONTROL='ignoredups:ignorespace'
HISTSIZE=1000
HISTFILESIZE=2000
HISTTIMEFORMAT=$(echo -e '\e[1;31m%T\e[33m %d/%m/%y ⮕\e[0;1m  ')

# Called by `readline` when <ALT><V> send to `read`. It checks which PS is used
# last (PS_READY or PS_BUSY). This is a way to find out if background `coproc`
# BC finished a task (e.g. long calculation).
bind_PS_refresher() {
  while read -t 0 -u ${BC[0]}; do
    read -ru ${BC[0]} PS_current
  done

  printf "${PS_current}"
}

# Function used to trigger bind_PS_refresher(). Used when `read` removes
# `printf`'s PS, e.g. SIGWINCH, autocomplete...
refresh_read_cmd() {
  ${HOME_DIR}/bin/write_to_STDIN v
}

# When SIGINT is received, BC does not clean STDIN. This function
# flushes STDIN and resets any nested statement.
trap_SIGINT() {
  ${HOME_DIR}/bin/write_to_STDIN v

  if (( BC_STATEMENTS_LVL > 0 )); then
    unset INDENT
    PS_SIGN='>'
    while (( --BC_STATEMENTS_LVL > 0 )); do
      echo $'} /* \254 */#'"${LINE_NUM}" >&${BC[1]}
    done
    echo $'} /* \254 */#'"${LINE_NUM}" >&${BC[1]}
  fi
}

trap_EXIT() {
  printf '\033[?25h\033[G\033[0K'
  history -a
}

autocomplete() {
  local IFS=$'|\n\t'
  local AUTOCOMPLETE_OPTS="${COMPS_STATEMENTS}|${COMPS_KEYWORDS}|${COMPS_VAR}|${COMPS_LIB}"
  local trim_indent_line="${READLINE_LINE#${READLINE_LINE%%[![:space:]]*}}"
  local comps
  local comp row_len color st_done kw_done var_done lib_done i dist=0 indent=12
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
    (( ++dist ))

    for comp in ${comps[@]}; do
      if [[ -z "${st_done}" && "${COMPS_STATEMENTS//\\}" == *"${comp}"* ]]; then
        st_done=yes
        color=0
        row_len=${indent}
        printf "\n%-${indent}s" 'Statements:' >&2
      elif [[ -z "${kw_done}" && "${COMPS_KEYWORDS//\\}" == *"${comp}"* ]]; then
        kw_done=yes
        color=0
        row_len=${indent}
        printf "\n%-${indent}s" 'Keywords:' >&2
      elif [[ -z "${var_done}" && "${COMPS_VAR//\\}" == *"${comp}"* ]]; then
        var_done=yes
        color=0
        row_len=${indent}
        printf "\n%-${indent}s" 'Variables:' >&2
      elif [[ -z "${lib_done}" && "${COMPS_LIB//\\}" == *"${comp}"* ]]; then
        lib_done=yes
        color=0
        row_len=${indent}
        printf "\n%-${indent}s" 'Library:' >&2
      fi

      (( row_len += dist ))
      if (( row_len >= COLUMNS )); then
        printf "\n%-${indent}s" >&2
        (( row_len = indent + dist ))
      fi

      (( color = color % 6 + 1 ))
      printf "\033[1;3%dm%-${dist}s\033[m" ${color} "${comp}" >&2
    done

    echo
  else
    READLINE_LINE="${READLINE_LINE%%${comps[0]:0:1}*}${comps[0]}"

    case "${comps[0]}" in
      for\ \(*) position_part="${READLINE_LINE%%; ++i*}" ;;
      *\(*\)*) position_part="${READLINE_LINE%%\)*}" ;;
      print\ *) position_part="${READLINE_LINE%\"*}" ;;
      *) position_part="${READLINE_LINE}" ;;
    esac
    READLINE_POINT="${#position_part}"
  fi
}

create_list() {
  local list_line

  input_list="${input}"

  while :; do
    read -ser list_line
    input_list+=";${list_line}"

    read -t 0 || break
  done
}

modify_list() {
  local answer ascii_char_octal

  local PS_opts='Available options [+-*/aosdq]: [ ]'
  local PS_desc='(a - average, o - output, s - sort, d - descending sort, q - quit)'
  local input_position=$'\033[G\033['"$(( ${#PS_opts} - 2 ))C"

  local PS=$'\033[G\033[1;35m'"${PS_opts}"$'\033[m\n'"${PS_desc}"$'\033[A'"${input_position}"
  local PS_wrong=$'\033[4C\033[1;31m'"Input unknown${input_position}"

  printf '\033[?25l\033[G\033[0KList detected: %s\n\n' "${input_list//;/, }"

  while read -srN 1 -p "${PS}" answer; do
    case "${answer}" in
      [+-/*]) input_list="${input_list//;/${answer}}" ;;
      a) input_list="(${input_list//;/+}) / $(wc -c <<< "${input_list//[^;]}")" ;;
      o) : ;;
      s) input_list="$(sort -n <<< "${input_list//;/$'\n'}" | tr '\n' ';')" ;;
      d) input_list="$(sort -rn <<< "${input_list//;/$'\n'}" | tr '\n' ';')" ;;
      q) unset input_list ;;
      $'\001') # Caught when SIGINT received, thanks to trap_SIGINT's <CTRL><A>
        unset input_list
        read -t 0.005
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

        read -t 0.8 -srN 1 -p "${PS_wrong}${answer}" answer

        if (( $(printf -- '%s' "${answer}" | wc -c) == 1 )); then
          ascii_char_octal=$(printf -- '%s' "${answer}" | od -dA n)

          if (( ascii_char_octal > 31 && ascii_char_octal < 127 )); then
            ${HOME_DIR}/bin/write_to_STDIN ${answer}
          fi
        fi

        printf '\033[0K'
        continue
        ;;
    esac

    printf '\033[1;32m%s\033[m\033[?25h\n' "${answer}"
    [[ "${answer}" == q ]] && refresh_read_cmd
    break
  done
}

set -o emacs
trap refresh_read_cmd 28
trap trap_SIGINT 2
trap trap_EXIT 0

history -r
bind -x '"\C-i":"autocomplete"'
bind -x '"\ev":"bind_PS_refresher"'
bind -u 'reverse-search-history'
bind -u 'forward-search-history'

coproc BC {
  trap '' 2

  bc -liq |&
    while read -r bc_output; do
      case "${bc_output}" in
        *standard_in*|*error*)
          printf '\033[G\033[0K\033[1;31m%s\033[m\n' "${bc_output}" >&2
          ;;
        *warning*|*interrupt*)
          printf '\033[G\033[0K\033[1;35m%s\033[m\n' "${bc_output}" >&2
          ;;
        *$'/* \254 */#'*) # Type of input that shouldn't print green PS, e.g. 2^222222
          (( LINE_NUM = ${bc_output##*#} ))
          continue
          ;;
        *$'/* \255 */#'*) # Type of input that should print green PS, e.g. a = 2
          (( LINE_NUM = ${bc_output##*#} ))
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

      printf "${PS_READY}\n" ${LINE_NUM}
      printf "${PS_READY}" ${LINE_NUM} >&2
      refresh_read_cmd
    done
  kill 0
}

PS_current="$(printf "${PS_READY}" ${LINE_NUM} | tee /dev/stderr)"

while read -erp "${PS_DUMMY}" ${INDENT} input; do
  if [[ -z "${input}" ]]; then
    refresh_read_cmd
    continue
  fi

  if read -t 0; then
    create_list
    modify_list
    [[ -z "${input_list}" ]] && continue
  else
    history -s "${input}"
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
  elif [[ "${input}" =~ ^\ *for\ *\( ]]; then
    IFS=$'\n'
  else
    IFS=$';\n'
  fi

  for statement in ${input}; do
    input_type=$'/* \254 */'

    if [[ "${statement}" == *\"* ]]; then
      (( BC_STATEMENTS_LVL == 0 )) && input_type=$'/* \255 */'

      if [[ "${statement}" != *\"*\"* ]]; then
        printf '\033[G\033[0K\033[1;31mSyntax error: multi-line ' >&2
        printf '\033[3mstring\033[0;1;31m not supported\033[m\n' >&2

        statement='/* ignore */'
      fi
    fi

    if [[ "${statement}" =~ ^\ *history\ *$ ]]; then
      history >&2

      statement='/* ignore */'
      input_type=$'/* \255 */'
    elif [[ "${statement}" =~ ^\ *\$\$\ *$ ]]; then
      bash -li

      statement='/* ignore */'
      input_type=$'/* \255 */'
    elif [[ "${statement}" =~ ^\ *\$ ]]; then
      statement="$(bash -c "${statement#*\$}" 2>&1)"

      if (( $? != 0 )); then
        printf '\033[G\033[0K\033[1;31m%s\033[m\n' "${statement}" >&2

        statement='/* ignore */'
        input_type=$'/* \255 */'
      else
        printf '\033[G\033[0K\033[1;35mWarning: Bash output ' >&2
        printf "goes into BC's input automatically.\033[0m\n" >&2
      fi
    elif [[ "${statement}" =~ \ *print( *\".*\"| +[a-z]) ]]; then
      statement="$(sed 's/print.*["a-zA-Z0-9]/&, "\\n"/' <<< "${statement}")"

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
          statement="base=${input_base};obase=${adjusted_base};ibase=${adjusted_base}"
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
    if [[ "${statement}" == *\{*\}* ]]; then
      input_type=$'/* \255 */'
    elif [[ "${statement}" == *\{* ]]; then
      unset oneliner_statement

      if test_input="$(bc -lq <<< "${statement}; quit; }" |& grep 'standard_in')"; then
        printf '\033[G\033[0K\033[1;31m%s\033[m\n' "${test_input}" >&2

        statement='/* ignore */'
        (( BC_STATEMENTS_LVL == 0 )) && input_type=$'/* \255 */'
      else
        (( BC_STATEMENTS_LVL++ ))
        INDENT="-i$(printf "%$(( BC_STATEMENTS_LVL * 2 ))s")"
        PS_SIGN=$'\033[31m{\033[m'
      fi
    elif [[ -n "${oneliner_statement}" ]]; then
      PS_SIGN='>'
      unset oneliner_statement

      input_type=$'/* \255 */'
    elif [[ "${statement}" =~ ^\ *(if|while|for)\ *\(.* ]]; then
      oneliner_statement=possible
      PS_SIGN=$'\033[31m{\033[m'
    elif [[ "${statement}" == *\}* ]]; then
      if (( --BC_STATEMENTS_LVL > 0 )); then
        INDENT="-i$(printf "%$(( BC_STATEMENTS_LVL * 2 ))s")"
      else
        PS_SIGN='>'
        unset INDENT

        input_type=$'/* \255 */'
      fi
    elif [[ "${statement}" =~ ^\ *[a-z0-9_]+(\[.+\])?\ *=\ *[a-z0-9_]+\ * ]]; then
      input_type=$'/* \255 */'
    fi


    PS_current="$(printf "${PS_BUSY}" ${LINE_NUM} "${PS_SIGN}" | tee /dev/stderr)"

    # Feeding BC with the user's input
    echo "${statement} ${input_type}#${LINE_NUM}" >&${BC[1]}

  done
done

