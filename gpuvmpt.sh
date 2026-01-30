#!/usr/bin/env bash

[[ -n "$DEBUG" ]] && set -x

if command -v tput &> /dev/null && [[ -n "$TERM" ]]; then
  red=$(tput setaf 1)
  green=$(tput setaf 2)
  yellow=$(tput setaf 3)
  normal=$(tput sgr0)
else
  red=""
  green=""
  yellow=""
  normal=""
fi

declare -A pid_to_cmd

gpu_ids=()
gpu_ids_virsh=()
vm_ipaddr=()
vm_netif=()

gpu_alias="$1"
vm_name="$2"

script_name="$(basename "$0")"
config_dir="${HOME}/.config/${script_name}"

# shellcheck source=/dev/null
[[ -f "${config_dir}/${script_name}.conf" ]] && source "${config_dir}/${script_name}.conf"

if [[ -d "${config_dir}/${script_name}.d" ]]; then
  for conf in "${config_dir}/${script_name}.d"/*.conf; do
    # shellcheck source=/dev/null
    [[ -f "$conf" ]] && source "$conf"
  done
fi

# shellcheck source=/dev/null
[[ -f "${HOME}/.${script_name}" ]] && source "${HOME}/.${script_name}"

die() {
  for prompt in "${@}"; do
    printf "%s\n" "$prompt"
  done
  exit 1
}

elevate() {
  echo
}

log() {
  local mode="${1:-normal}"
  case "$mode" in
    "normal") printf "%s\n" "${normal}${2}${normal}" ;;
    "urgent") printf "%s\n" "${yellow}${2}${normal}" ;;
    "critical") printf "%s\n" "${red}${2}${normal}" ;;
  esac
}

prompt() {
  local mode="${1:-normal}"
  case "$mode" in
    "normal") printf "%s " "${normal}${2} (${green}y${normal}/${red}N${normal})" ;;
    "urgent") printf "%s " "${yellow}${2} (${green}y${yellow}/${red}N${yellow})${normal}" ;;
    "critical") printf "%s " "${red}${2} (${green}y${red}/${red}N${red})${normal}" ;;
  esac
  read -r choose
  choose=${choose:-n}
  if [[ "${choose,,}" =~ ^(y|yes)$  ]]; then
    return 0
  elif [[ "${choose,,}" =~ ^(n|no)$ ]]; then
    return 1
  else
    log urgent "Invalid input."
    return 1
  fi
}

check_deps() {
  local missing=()
  for cmd in lspci virsh xmllint curl lsof modprobe tput; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if (( ${#missing[@]} )); then
    die "Missing required commands: ${missing[*]}"
  fi
}

if [[ -z "$gpu_alias" || -z "$vm_name" ]]; then
  die "Usage: $0 <gpu_alias> <vm_name>" \
    "" \
    "Example | Description" \
    "$0 nvidia win11 | unload nvidia gpu modules, detach from the host and start win11" \
    "$0 nvidia win11 recover | shutdown win11 vm, reattach nvidia gpu to the host and reload the modules" \
    "$0 nvidia win11 moonlight | start moonlight and auto connect to the sunshine host"
fi

case "$gpu_alias" in
  "nvidia")
    gpu_modules=("nvidia" "nvidia-drm" "nvidia-modeset" "nvidia-uvm")
    ;;
  "manual")
    gpu_modules=("${MANUAL_MODULES[@]}")
    ;;
  *)
    die "Missing or unknown GPU alias."
    ;;
esac

detect_valid_vm() {
  if ! sudo virsh list --all | grep -q "$vm_name"; then
  	printf "The VM name \"%s\" is invalid.\n" "$vm_name"
    return 1
  else
    return 0
  fi
}

detect_running_vm() {
  if sudo virsh list | grep -q "$vm_name"; then
  	printf "The VM \"%s\" is already running.\n" "$vm_name"
    return 1
  else
    return 0
  fi
}

detect_gpu() {
  while IFS= read -r line; do
    gpu_ids+=("$line")
  done <<< "$(lspci -nn | grep -Ei "${gpu_alias}" | awk '{print $1}')"
  while IFS= read -r line; do
    gpu_ids_virsh+=("$line")
  done <<< "$(lspci -nn | grep -Ei "${gpu_alias}" | awk '{print "pci_0000_" $1}' | sed 's/:/_/; s/\./_/')"
  if [[ "${#gpu_ids[@]}" -gt 0 ]]; then
    return 0
  else
    return 1
  fi
}

detect_gpu_modules() {
  if lsmod | grep -Eiq "$(printf "%s\n" "${gpu_modules[@]}" | paste -sd\| -)"; then
    printf "Detected %s modules loaded.\n" "${gpu_alias}"
    return 0
  else
    printf "No %s modules loaded.\n" "${gpu_alias}"
    return 1
  fi
}

unload_gpu_modules() {
  if sudo modprobe -r "${gpu_modules[@]}"; then
    return 0
  else
    return 1
  fi
}

detect_using_gpu() {
  local cmd module pid output
  local cmd_list
  local pid_list

  for module in "${gpu_modules[@]}"; do
    output=$(sudo lsof -Fpc /dev/"${module}"* 2>/dev/null)
    while IFS= read -r line; do
      case "$line" in
        p*) pid="${line#p}" ;;
        c*) cmd="${line#c}"; [[ -n "$pid" ]] && pid_to_cmd["$pid"]="$cmd" ;;
      esac
    done <<< "$output"
  done
  if [[ ${#pid_to_cmd[@]} -eq 0 ]]; then
    printf "No processes using the specified GPU modules.\n"
    return 1
  else
    printf "Processes using the requested GPU: "
    cmd_list="$(IFS=","; printf "%s" "${pid_to_cmd[*]}"; IFS="")"
    pid_list="$(IFS=","; printf "%s" "${!pid_to_cmd[*]}"; IFS="")"
    printf "%s (%s)\n" "$cmd_list" "$pid_list"
    return 0
  fi
}

wait_for_gpu_free() {
  local max_attempts=10
  local attempt=0
  local wait_time=0.5
  
  printf "Waiting for GPU to be released"
  while [[ $attempt -lt $max_attempts ]]; do
    pid_to_cmd=()
    
    #local using_gpu=false
    for module in "${gpu_modules[@]}"; do
      output=$(sudo lsof -Fpc /dev/"${module}"* 2>/dev/null)
      if [[ -n "$output" ]]; then
        while IFS= read -r line; do
          case "$line" in
            p*) pid="${line#p}" ;;
            c*) cmd="${line#c}"; [[ -n "$pid" ]] && pid_to_cmd["$pid"]="$cmd" ;;
          esac
        done <<< "$output"
      fi
    done
    
    if [[ ${#pid_to_cmd[@]} -eq 0 ]]; then
      printf " %s\n" "${green}✓${normal}"
      return 0
    fi
    
    printf "."
    sleep "$wait_time"
    ((attempt++))
  done
  
  printf " %s\n" "${red}✗${normal}"
  printf "%s" "${red}GPU still in use after waiting. Processes: ${normal}"
  cmd_list="$(IFS=","; printf "%s" "${pid_to_cmd[*]}"; IFS="")"
  pid_list="$(IFS=","; printf "%s" "${!pid_to_cmd[*]}"; IFS="")"
  printf "%s (%s)\n" "$cmd_list" "$pid_list"
  return 1
}

kill_using_gpu() {
  if [[ ${#pid_to_cmd[@]} -eq 0 ]]; then
    return 0
  else
    if prompt normal "Kill these processes?"; then
      if ! sudo kill "${!pid_to_cmd[@]}" 2>/dev/null; then
        if prompt urgent "Some processes didn't respond. Force kill?"; then
          if ! sudo kill -9 "${!pid_to_cmd[@]}" 2>/dev/null; then
            printf "%s\n" "${red}Failed to forcefully terminate the processes.${normal}"
            return 1
          else
            printf "%s\n" "${green}Processes terminated forcefully.${normal}"
            return 0
          fi
        else
          printf "%s\n" "${red}Aborted.${normal}"
          return 1
        fi
      else
        printf "%s\n" "${green}Processes terminated.${normal}"
        return 0
      fi
    else
      printf "%s\n" "${red}Aborted.${normal}"
      return 1
    fi
  fi
}

load_gpu_modules() {
  local failed_module=0

  printf "Loading %s modules...\n" "${gpu_alias}"
  for module in "${gpu_modules[@]}"; do
    if sudo modprobe "${module}"; then
      printf "%s\n" "Module ${green}${module}${normal} loaded successfully."
    else
      printf "%s\n" "Failed to load module ${red}${module}${normal}."
      failed_module=1
    fi
  done
  if [[ "${failed_module}" -eq 1 ]]; then
    return 1
  else
    return 0
  fi
}

reattach_gpu() {
  printf "Reattaching GPU to host...\n"
  for dev in "${gpu_ids_virsh[@]}"; do
    virsh_output="$(sudo virsh nodedev-reattach "$dev" 2>/dev/null)"
    case "$virsh_output" in
      *"re-attached"*) printf "Re-attached %s to the host\n" "$dev" ;;
      *) printf "%s\n" "${yellow}Failed to re-attach $dev to the host${normal}" ;;
    esac
  done
  
  sleep 2
  
  if load_gpu_modules; then
    printf "%s\n" "${green}GPU recovery complete.${normal}"
    return 0
  else
    printf "%s\n" "${red}GPU recovery failed.${normal}"
    return 1
  fi
}

recover_gpu() {
  if detect_gpu; then
    if sudo virsh list | grep -q "$vm_name"; then
      printf "Shutting down VM \"%s\"...\n" "$vm_name"
      declare -F pre_vm_recover &>/dev/null && pre_vm_recover
      virsh_output="$(sudo virsh shutdown "$vm_name" 2>/dev/null)"
      case "$virsh_output" in
        *"is being shutdown"*)
          printf ""
          declare -F post_vm_recover &>/dev/null && post_vm_recover
          ;;
        *) printf "Failed to shutdown %s\n" "$vm_name" ;;
      esac
      
      printf "Waiting for VM to shut down"
      local max_wait=30
      local waited=0
      while sudo virsh list | grep -q "$vm_name" && [[ $waited -lt $max_wait ]]; do
        printf "."
        sleep 2
        ((waited+=2))
      done
      printf "\n"
      
      if sudo virsh list | grep -q "$vm_name"; then
        if prompt urgent "VM didn't shut down gracefully. Force off?"; then
          virsh_output="$(sudo virsh destroy "$vm_name")"
          case "$virsh_output" in
            *"destroyed"*)
              printf ""
              declare -F post_vm_recover &>/dev/null && post_vm_recover
              ;;
            *) printf "Failed to destroy %s\n" "$vm_name" ;;
          esac
        else
          printf "%s\n" "${red}Cannot recover GPU while VM is running.${normal}"
          return 1
        fi
      fi
    fi
    
    reattach_gpu
  else
    printf "%s\n" "${red}GPU not detected.${normal}"
    return 1
  fi
}

get_netif() {
  local netif=()
  mapfile -t netif < <(sudo virsh dumpxml "$vm_name" | xmllint --xpath "string(//domain//interface/source/@network)" -)
  if [[ "${#netif}" -gt 0 ]]; then
    vm_netif=("${netif[@]}")
    return
  else
    return 1
  fi
}

get_ipaddr() {
  local method="${1:-domifaddr}"
  local max_wait=120
  local waited=0
  local ipaddr=()
  printf "Waiting for the VM to get an IP"
  while [[ $waited -lt $max_wait ]]; do
    case "$method" in
      "domifaddr")
        mapfile -t ipaddr < <(sudo virsh domifaddr "$vm_name" | awk 'NR>=3 {print $4}' | sed 's/\/.*//')
        ;;
      "dhcp-leases")
        if get_netif; then
          for netif in "${vm_netif[@]}"; do
            mapfile -t ipaddr -O "${#ipaddr[@]}" < <(sudo virsh net-dhcp-leases --network "$netif" | awk 'NR>=3 {print $5}' | sed 's/\/..//')
          done
        fi
        ;;
    esac
    if [[ "${#ipaddr}" -gt 0 ]]; then
      printf " %s\n" "${green}✓${normal}"
      break
    fi
    printf "."
    sleep 2
    ((waited+=2))
  done
  if [[ "${#ipaddr}" -gt 0 ]]; then
    vm_ipaddr=("${ipaddr[@]}")
    return
  else
    printf " %s\n" "${red}✗${normal}"
    return 1
  fi
}

launch_moonlight() {
  local max_wait=120
  local waited=0
  local moonlight_cmd=""
  local sunshine_host="${SUNSHINE_HOST:-}"

  printf "Launching Moonlight...\n"

  if [[ -n "$MOONLIGHT_CMD" ]]; then
    moonlight_cmd="$MOONLIGHT_CMD"
  else
    if command -v moonlight &> /dev/null; then
      moonlight_cmd="moonlight"
    elif flatpak list | grep -q "com.moonlight_stream.Moonlight"; then
      moonlight_cmd="flatpak run com.moonlight_stream.Moonlight"
    else
      printf "%s\n" "${red}Moonlight not found. Please install it first.${normal}"
      return 1
    fi
  fi

  if get_ipaddr "domifaddr" || get_ipaddr "dhcp-leases"; then
    printf "Waiting for sunshine to come up"
    while [[ $waited -lt $max_wait ]]; do 
      for ip in "${vm_ipaddr[@]}"; do
        if curl -s -m 2 --insecure "http://$ip:47989" >/dev/null; then
          sunshine_host="$ip"
        fi
      done
      if [[ -n "$sunshine_host" ]]; then
        printf " %s\n" "${green}✓${normal}"
        break
      else
        printf "."
        sleep 2
        ((waited+=2))
      fi
    done
  fi
  
  if [[ -z "$sunshine_host" ]]; then
    printf "Enter Sunshine host IP (or press Enter to launch Moonlight GUI): "
    read -r sunshine_host
  else
    printf "Connecting to Sunshine host: %s\n" "$sunshine_host"
  fi

  if [[ -n "$sunshine_host" ]]; then
    $moonlight_cmd stream "$sunshine_host" Desktop &>/dev/null & disown
  else
    $moonlight_cmd &>/dev/null & disown
  fi
  
  printf "%s\n" "${green}Moonlight launched.${normal}"
}

action="${3:-start}"

check_deps

case "$action" in
  "start")
    sudo -v
    if ! pgrep -u "$USER" pipewire > /dev/null; then
      printf "Starting PipeWire.\n"
      gentoo-pipewire-launcher restart & disown
    fi

    if detect_gpu; then
      if detect_valid_vm; then
        if detect_running_vm; then
          if detect_gpu_modules; then
            if detect_using_gpu; then
              kill_using_gpu || exit 1
              wait_for_gpu_free || exit 1
            fi
          fi
          if unload_gpu_modules; then
            for dev in "${gpu_ids_virsh[@]}"; do
              virsh_output="$(sudo virsh nodedev-detach "$dev" 2>/dev/null)"
              case "$virsh_output" in
                *"detached"*) printf "Detached %s from the host\n" "$dev" ;;
                *) printf "%s\n" "${yellow}Failed to detach $dev from the host ${normal}" ;;
              esac
            done
            declare -F pre_vm_start &>/dev/null && pre_vm_start
            virsh_output="$(sudo virsh start "$vm_name")"
            case "$virsh_output" in
              *"started"*)
                printf ""
                declare -F post_vm_start &>/dev/null && post_vm_start
                ;;
              *) printf "Failed to start %s\n" "$vm_name" ;;
            esac
            if [[ "${MOONLIGHT_AUTOSTART,,}" =~ ^(y|yes)$ ]]; then
              launch_moonlight
            else 
              if [[ ! "${MOONLIGHT_AUTOSTART,,}" =~ (n|no)$ ]]; then
                if prompt normal "Launch Moonlight to connect? Make sure you have already paired your client with your host!"; then
                  launch_moonlight
                fi
              fi
            fi
          fi
        fi
      fi
    fi
    ;;
  "stop"|"recover")
    sudo -v
    recover_gpu
    ;;
  "moonlight")
    sudo -v
    launch_moonlight
    ;;
  *)
    die "Usage: $0 <gpu_alias> <vm_name> [start|stop|recover]"
    ;;
esac

