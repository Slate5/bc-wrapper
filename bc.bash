#!/bin/bash

export BC_LINE_LENGTH=0
BC_BASE=10
LINE_NUM=1
PROMPT_SIGN='>'

HISTFILE=~/.bc_history
HISTCONTROL='ignoredups:ignorespace'
HISTSIZE=1000
HISTFILESIZE=2000
HISTTIMEFORMAT=$(echo -e "\e[1;31m"%T"\e[33m" %d/%m/%y ⮕"\e[0;1m"\ \ )

IFS=$'\n'

trap 'history -a' 0
history -r

printf '\033[0m'

coproc BC { bc -lq &>/proc/$$/fd/1; }

exec > >(
  while read -r bc_output; do
    case "${bc_output}" in
      *error*)
        printf "\033[1;31m${bc_output}\033[0m\n" >&2
        ;;
      *warning*)
        printf "\033[1;35m${bc_output}\033[0m\n" >&2
        ;;
      *)
        printf "\033[1;35m=>\033[39m ${bc_output}\033[0m\n" >&2
        ;;
    esac
    rm /dev/shm/BC_lock
  done
)

while read -erp "BC:$(printf "%02d" ${LINE_NUM})${PROMPT_SIGN} " ${INDENT} input; do
  [[ -z "${input}" ]] && continue
  touch /dev/shm/BC_lock
  history -s "${input}"
  (( LINE_NUM++ ))

  if [[ "${input}" == *\{* && "${input}" != *\{*\}* ]]; then
    (( BC_STATEMENTS_LVL++ ))

    INDENT="-i$(printf "%$(( BC_STATEMENTS_LVL * 2 ))s")"
    PROMPT_SIGN=$'\033[31m{\033[m'
  elif [[ "${input}" == *\}* && "${input}" != *\{*\}* ]]; then
    if (( --BC_STATEMENTS_LVL > 0 )); then
      INDENT="-i$(printf "%$(( BC_STATEMENTS_LVL * 2 ))s")"
    else
      PROMPT_SIGN='>'
      unset INDENT
    fi
  fi

  for statement in $(sed -E '/^ *for *\(/! s/;/\n/g' <<< "${input}"); do
    if [[ "${statement}" =~ ^\ *history\ *$ ]]; then
      history >&2
      continue
    elif [[ "${statement}" =~ ^\ *\$\$\ *$ ]]; then
      bash -li >&2
      continue
    elif [[ "${statement}" =~ ^\ *\$ ]]; then
      printf "\033[1;35mWarning: Bash output goes into BC's input automatically.\033[0m\n" >&2
      statement=$(bash -c "${statement#*\$}")
      (( $? != 0 )) && continue
    elif [[ "${statement}" =~ (^| +)([io]?base)\ *=\ *(-?[0-9]+)( +|$) ]]; then
      input_base="${BASH_REMATCH[3]}"

      if (( input_base > 16 )); then
        printf '\033[1;35mWarning: base too large, set to 16\033[0m\n' >&2
        input_base=16
      elif (( input_base < 2 )); then
        printf '\033[1;35mWarning: base too small, set to 2\033[0m\n' >&2
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
    elif [[ "${statement}" =~ ^\ *print ]]; then
      statement="${statement}, \"\n\""
    fi

    echo "${statement}" >&${BC[1]}
    while sleep 0.005; do [ -e /dev/shm/BC_lock ] || break; done
  done
done

