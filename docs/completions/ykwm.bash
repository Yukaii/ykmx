_ykwm() {
  local cur prev
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"

  if [[ ${COMP_CWORD} -eq 1 ]]; then
    COMPREPLY=( $(compgen -W "--help --version --benchmark --smoke-zmx" -- "$cur") )
    return 0
  fi

  case "$prev" in
    --benchmark)
      COMPREPLY=( $(compgen -W "100 200 300 500" -- "$cur") )
      return 0
      ;;
  esac
}

complete -F _ykwm ykwm

