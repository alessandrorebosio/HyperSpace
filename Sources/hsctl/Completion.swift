/// `hsctl completion zsh`: the zsh completion, for `eval "$(hsctl completion zsh)"` in
/// ~/.zshrc (after `compinit`). Workspace, mode and app names are asked from HyperSpace
/// as you type, so they follow the config.
let zshCompletion = #"""
#compdef hsctl

_hsctl_workspaces() {
  local -a names
  names=(${(f)"$(hsctl list-workspaces --all 2>/dev/null)"})
  compadd -a names
}

_hsctl() {
  local -a commands
  commands=(
    'status:show permissions and config state'
    'enable:turn remapping on'
    'disable:turn remapping off'
    'toggle:switch between enabled and disabled'
    'do:perform an action now'
    'reload:reload the config'
    'config-path:print the config directory'
    'apps:list running apps with their bundle id'
    'version:print the version'
    'completion:print the shell completion'
    'workspace:show a workspace'
    'workspace-back-and-forth:show the previous workspace'
    'summon-workspace:bring a workspace to the focused monitor'
    'move-node-to-workspace:move the window to a workspace'
    'move-workspace-to-monitor:move the workspace to another monitor'
    'move-node-to-monitor:move the window to another monitor'
    'focus-monitor:focus another monitor'
    'ignore-monitor:leave a monitor out, as if disconnected'
    'monitor-brightness:change an external display brightness'
    'monitor-volume:change an external display volume'
    'monitor-input:switch an external display input'
    'focus:focus a window'
    'focus-back-and-forth:focus the previous window'
    'move:move the window'
    'swap:swap the window with another'
    'join-with:join the window with a neighbor'
    'resize:resize the window'
    'balance-sizes:give every window the same size'
    'flatten-workspace-tree:reset the workspace layout'
    'layout:change the layout'
    'fullscreen:toggle fullscreen in the workspace'
    'macos-native-fullscreen:toggle macOS fullscreen'
    'macos-native-minimize:minimize the window'
    'close:close the window'
    'close-all-windows-but-current:close the other windows'
    'scratchpad:summon or put away an app window'
    'mode:switch binding mode'
    'trigger-binding:run a binding'
    'move-mouse:move the mouse'
    'volume:change the volume'
    'exec-and-forget:run a shell command'
    'reload-config:reload the config'
    'list-windows:list windows'
    'list-workspaces:list workspaces'
    'list-monitors:list monitors'
    'list-apps:list apps'
    'list-modes:list binding modes'
    'subscribe:print window manager events as they happen'
  )
  if (( CURRENT == 2 )); then
    _describe -t commands 'hsctl command' commands
    return
  fi

  local -a flags
  case $words[2] in
    workspace) flags=(--auto-back-and-forth --wrap-around --fail-if-noop) ;;
    summon-workspace) flags=(--fail-if-noop) ;;
    move-node-to-workspace) flags=(--focus-follows-window --wrap-around --fail-if-noop --window-id) ;;
    move-workspace-to-monitor) flags=(--wrap-around --no-swap --workspace) ;;
    scratchpad) flags=(--new) ;;
    move-node-to-monitor) flags=(--focus-follows-window --wrap-around --window-id) ;;
    focus-monitor) flags=(--wrap-around) ;;
    focus) flags=(--window-id --dfs-index --boundaries --boundaries-action --ignore-floating --wrap-around) ;;
    move) flags=(--window-id --boundaries --boundaries-action --fail-if-fullscreen) ;;
    swap) flags=(--window-id --swap-focus --wrap-around) ;;
    join-with|resize|macos-native-minimize) flags=(--window-id) ;;
    balance-sizes|flatten-workspace-tree) flags=(--workspace) ;;
    layout) flags=(--window-id --workspace --root --fail-if-noop) ;;
    fullscreen) flags=(--window-id --no-outer-gaps --fail-if-noop) ;;
    macos-native-fullscreen) flags=(--window-id --fail-if-noop) ;;
    close) flags=(--window-id --quit-if-last-window) ;;
    close-all-windows-but-current) flags=(--quit-if-last-window) ;;
    trigger-binding) flags=(--mode) ;;
    list-windows) flags=(--all --focused --workspace --monitor --pid --app-bundle-id --format --count --json) ;;
    list-workspaces) flags=(--all --focused --monitor --visible --empty --format --count --json) ;;
    monitor-brightness|monitor-volume|monitor-input) flags=(--monitor) ;;
    list-monitors) flags=(--all --focused --format --count --json) ;;
    list-apps|list-modes) flags=(--format --count --json) ;;
    subscribe) flags=(--all --no-send-initial) ;;
  esac
  if [[ $PREFIX == -* ]]; then
    compadd -a flags
    return
  fi

  case $words[CURRENT-1] in
    --workspace) _hsctl_workspaces; return ;;
    --mode) compadd ${(f)"$(hsctl list-modes 2>/dev/null)"}; return ;;
    --app-bundle-id) compadd ${(f)"$(hsctl list-apps --format '%{app-bundle-id}' 2>/dev/null)"}; return ;;
  esac
  case $words[2] in
    workspace|move-node-to-workspace) _hsctl_workspaces; compadd next prev ;;
    summon-workspace) _hsctl_workspaces ;;
    focus) compadd left down up right dfs-next dfs-prev ;;
    move|join-with) compadd left down up right ;;
    swap) compadd left down up right dfs-next dfs-prev ;;
    focus-monitor|move-node-to-monitor|move-workspace-to-monitor) compadd left down up right next prev ;;
    resize) compadd smart smart-opposite width height ;;
    layout) compadd tiles accordion horizontal vertical tiling floating h_tiles v_tiles h_accordion v_accordion ;;
    fullscreen|macos-native-fullscreen) compadd on off toggle ;;
    monitor-input) compadd dp1 dp2 hdmi1 hdmi2 usb-c vga1 dvi1 ;;
    monitor-volume) compadd mute-toggle ;;
    ignore-monitor) (( CURRENT == 3 )) && compadd on off toggle || compadd main secondary ;;
    scratchpad) compadd ${(f)"$(hsctl list-apps --format '%{app-bundle-id}' 2>/dev/null)"} ;;
    mode) compadd ${(f)"$(hsctl list-modes 2>/dev/null)"} ;;
    move-mouse) compadd monitor-lazy-center monitor-force-center window-lazy-center window-force-center ;;
    volume) compadd up down mute-toggle mute-on mute-off set ;;
    completion) compadd zsh ;;
    subscribe) compadd focus-changed focused-monitor-changed focused-workspace-changed mode-changed window-detected ;;
  esac
}

compdef _hsctl hsctl
"""#
