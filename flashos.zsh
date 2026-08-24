# FlashOS Zsh entrypoint.
#
# Keep this filename for directory-based auto-source setups. The shared wrapper
# implementation lives in flashos.sh so Bash users get the same commands.

typeset _flashos_zsh_entry="${${(%):-%x}:A:h}/flashos.sh"
source "$_flashos_zsh_entry" || return 1
unset _flashos_zsh_entry

_flashos_zsh_completion() {
  local -a commands=(
    'status:show repository, profile, and artifacts'
    'doctor:validate the development environment'
    'version:print the product version'
    'versions:show release and tag state or check drift'
    'profile:show or select the image profile'
    'env:print the selected Make environment'
    'build:build FlashOS images'
    'run:start interactive QEMU'
    'smoke:run exact-artifact QEMU qualification'
    'qualify:check, build, and smoke end to end'
    'recipe:find, cook, rebuild, or push recipes'
    'artifacts:list, locate, or hash image artifacts'
    'logs:inspect or follow QEMU smoke logs'
    'changes:inspect Git state without writing it'
    'check:run repository checks'
    'shell:run Flash checks'
    'podman:inspect or control the Podman machine'
    'clean:remove an explicit generated-data scope'
    'root:change to the repository root'
    'list:show commands and direct helper functions'
    'help:show command help'
  )

  if (( CURRENT == 2 )); then
    _describe -t commands 'FlashOS command' commands
  elif (( CURRENT == 3 )); then
    case "${words[2]}" in
      profile) _values 'profile' dev release ;;
      versions) _values 'action' show check ;;
      build)   _values 'image' disk live both rebuild ;;
      run)     _values 'image' disk live ;;
      smoke)   _values 'image' disk live all ;;
      qualify) _values 'image' disk live all ;;
      recipe)  _values 'action' find tree image-tree fetch build rebuild clean unfetch push build-push rebuild-push ;;
      artifacts) _values 'action' list path hash ;;
      logs)    _values 'action' list disk live follow ;;
      changes) _values 'action' status diff stat staged recent ;;
      check)   _values 'scope' quick profile root shell target python docs ci all ;;
      shell)   _values 'scope' fmt clippy test target all ;;
      podman)  _values 'action' status start stop info ;;
      clean)   _values 'scope' build recipes fetches container dist ;;
    esac
  fi
}

if (( $+functions[compdef] )); then
  compdef _flashos_zsh_completion flashos fos
fi
