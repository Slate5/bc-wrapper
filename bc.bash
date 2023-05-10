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

coproc BC { bc -lq 2>&1; }

while read -erp "BC:$(printf "%02d" ${LINE_NUM})${PROMPT_SIGN} " ${INDENT} input; do
  [[ -z "${input}" ]] && continue
  history -s "${input}"
  (( LINE_NUM++ ))

  [[ "${one_shot_prompt_change}" ]] && PROMPT_SIGN='>' && unset one_shot_prompt_change

  if [[ "${input}" == *[a-zA-Z]*\{* && "${input}" != *\{*\}* ]]; then
    if test_input="$(bc -lq <<< "${input} break; }" |& grep 'error')"; then
      printf "\033[1;31m${test_input}\033[0m\n" >&2
      continue
    fi
  fi

  if [[ "${input}" =~ ^\ *((define +[a-zA-Z]+|if|while|for)\ *\(.*\{|\{)\ * ]]; then
    (( BC_STATEMENTS_LVL++ ))
    INDENT="-i$(printf "%$(( BC_STATEMENTS_LVL * 2 ))s")"
    PROMPT_SIGN=$'\033[31m{\033[m'
  elif [[ "${input}" =~ ^\ *(define +[a-zA-Z]+|if|while|for)\ *\(.* ]]; then
    one_shot_prompt_change=yes
    PROMPT_SIGN=$'\033[31m{\033[m'
    echo "${input}" >&${BC[1]}
    continue
  fi

  for statement in ${input//[;\\]/$'\n'}; do
    if [[ "${statement}" == "history" ]]; then
      history
      continue
    elif [[ "${statement}" =~ ^\ *\$\$\ *$ ]]; then
      bash -li
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
    fi

    echo "${statement}" >&${BC[1]}

    if (( BC_STATEMENTS_LVL > 0 )); then
      if [[ "${statement}" == *\}* ]]; then
        (( BC_STATEMENTS_LVL-- ))

        if (( BC_STATEMENTS_LVL > 0 )); then
          INDENT="-i$(printf "%$(( BC_STATEMENTS_LVL * 2 ))s")"
        else
          PROMPT_SIGN='>'
          unset INDENT
        fi
      fi

      (( BC_STATEMENTS_LVL > 0 )) && continue
    fi

    echo $'print "\004"' >&${BC[1]}

    read -ru ${BC[0]} -d $'\004' bc_output

    case "${bc_output}" in
      *error*)
        printf "\033[1;31m${bc_output}\033[0m\n" >&2
        ;;
      *warning*)
        printf "\033[1;35m${bc_output}\033[0m\n" >&2
        ;;
      *?*)
        printf "\033[1;35m=>\033[39m ${bc_output}\033[0m\n"
        ;;
    esac
  done
done

