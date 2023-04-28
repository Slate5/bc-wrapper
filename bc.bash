#!/bin/bash

export BC_LINE_LENGTH=0
BC_BASE=10
LINE_NUM=1

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

while read -erp "BC:${LINE_NUM}> " input; do
  [[ -z "${input}" ]] && continue
  history -s "${input}"
  (( LINE_NUM++ ))


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
  
    echo "${statement}"$'\nprint "\004"' >&${BC[1]}
  
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

