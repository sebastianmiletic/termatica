#!/bin/zsh

setopt no_nomatch
zmodload zsh/datetime

typeset -gi once=0 paused=0
typeset sort_mode=cpu
typeset -gi previous_rx=0 previous_tx=0 previous_time=0

[[ "${1:-}" == "--once" ]] && once=1
[[ -t 1 ]] || once=1

accent=$'\e[38;5;75m'
muted=$'\e[38;5;244m'
strong=$'\e[1m'
reset=$'\e[0m'
green=$'\e[38;5;114m'
yellow=$'\e[38;5;221m'
red=$'\e[38;5;203m'

cleanup() {
  (( once )) || printf '\e[0m\e[?25h\e[?1049l'
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
(( once )) || printf '\e[?1049h\e[?25l'

human_bytes() {
  /usr/bin/awk -v value="${1:-0}" 'BEGIN {
    split("B KiB MiB GiB TiB", units, " "); unit=1
    while (value >= 1024 && unit < 5) { value/=1024; unit++ }
    if (unit == 1) printf "%.0f %s", value, units[unit]
    else printf "%.1f %s", value, units[unit]
  }'
}

human_duration() {
  /usr/bin/awk -v seconds="${1:-0}" 'BEGIN {
    days=int(seconds/86400); hours=int((seconds%86400)/3600); minutes=int((seconds%3600)/60)
    if (days > 0) printf "%dd %dh %dm", days, hours, minutes
    else if (hours > 0) printf "%dh %dm", hours, minutes
    else printf "%dm", minutes
  }'
}

bar() {
  local value="${1:-0}" width="${2:-20}" colour="$green"
  (( ${value%.*} >= 85 )) && colour="$red"
  (( ${value%.*} >= 65 && ${value%.*} < 85 )) && colour="$yellow"
  local filled=$(( value * width / 100 ))
  (( filled > width )) && filled=$width
  local empty=$(( width - filled ))
  printf '%s' "$colour"
  printf '%*s' "$filled" '' | tr ' ' '#'
  printf '%s' "$muted"
  printf '%*s' "$empty" '' | tr ' ' '.'
  printf '%s' "$reset"
}

network_totals() {
  /usr/sbin/netstat -ibn 2>/dev/null | /usr/bin/awk '
    NR > 1 && $3 ~ /^<Link/ && $1 != "lo0" && $1 !~ /\*/ {
      rx += $(NF-4); tx += $(NF-1)
    }
    END { printf "%.0f %.0f", rx, tx }
  '
}

render() {
  local size rows columns
  size=$(stty size 2>/dev/null) || size="24 80"
  rows=${size%% *}; columns=${size##* }
  (( columns < 64 )) && columns=64
  (( rows < 18 )) && rows=18

  local cores cpu_total load memory_free memory_used memory_total
  cores=$(/usr/sbin/sysctl -n hw.logicalcpu 2>/dev/null || print 1)
  cpu_total=$(/bin/ps -A -o pcpu= 2>/dev/null | /usr/bin/awk -v cores="$cores" '{sum+=$1} END {value=sum/cores; if(value>100)value=100; printf "%.1f",value}')
  load=$(/usr/sbin/sysctl -n vm.loadavg 2>/dev/null | tr -d '{}')
  memory_total=$(/usr/sbin/sysctl -n hw.memsize 2>/dev/null || print 0)
  memory_free=$(/usr/bin/memory_pressure -Q 2>/dev/null | /usr/bin/awk '/System-wide memory free percentage:/ {gsub(/%/,"",$5); print $5}')
  [[ -z "$memory_free" ]] && memory_free=0
  memory_used=$(( 100 - memory_free ))

  local disk_line disk_total_k disk_used_k disk_percent
  disk_line=$(/bin/df -k / 2>/dev/null | /usr/bin/awk 'NR==2 {print $2, $3, $5}')
  read disk_total_k disk_used_k disk_percent <<< "$disk_line"
  disk_percent=${disk_percent%%%}

  local totals rx tx now elapsed rx_rate tx_rate
  totals=$(network_totals); read rx tx <<< "$totals"
  now=$EPOCHSECONDS; elapsed=$(( now - previous_time )); (( elapsed < 1 )) && elapsed=1
  if (( previous_time > 0 )); then
    rx_rate=$(( (rx - previous_rx) / elapsed )); tx_rate=$(( (tx - previous_tx) / elapsed ))
  else
    rx_rate=0; tx_rate=0
  fi
  previous_rx=$rx; previous_tx=$tx; previous_time=$now

  local boot uptime model os_version architecture hostname battery
  boot=$(/usr/sbin/sysctl -n kern.boottime 2>/dev/null | /usr/bin/awk -F'[=,]' '{gsub(/ /,"",$2); print $2}')
  uptime=$(( EPOCHSECONDS - ${boot:-EPOCHSECONDS} ))
  model=$(/usr/sbin/sysctl -n hw.model 2>/dev/null || print unknown)
  os_version=$(/usr/bin/sw_vers -productVersion 2>/dev/null || print unknown)
  architecture=$(/usr/bin/uname -m)
  hostname=$(/bin/hostname -s 2>/dev/null || print Mac)
  battery=$(/usr/bin/pmset -g batt 2>/dev/null | /usr/bin/awk -F"'" 'NR==1 {source=$2} /%/ {match($0,/[0-9]+%/); percent=substr($0,RSTART,RLENGTH)} END {if(percent) printf "%s, %s",percent,source; else printf "Desktop power"}')

  local inner=$(( columns - 4 )) bar_width=$(( columns / 4 ))
  (( bar_width < 12 )) && bar_width=12
  (( bar_width > 28 )) && bar_width=28
  local rule=${(l:$inner::-:)}

  (( once )) || printf '\e[H\e[2J'
  printf '%s%s TERMATICA / SYSTEM MONITOR%s\n' "$accent" "$strong" "$reset"
  printf '%s%s%s\n' "$muted" "$rule" "$reset"
  printf '%s%-10s%s %s  macOS %s  %s  uptime %s\n' "$muted" DEVICE "$reset" "$hostname" "$os_version" "$architecture" "$(human_duration "$uptime")"
  printf '%s%-10s%s %s  %s\n\n' "$muted" HARDWARE "$reset" "$model" "$battery"

  printf '%s%-10s%s ' "$strong" CPU "$reset"; bar "$cpu_total" "$bar_width"; printf ' %5.1f%%   %sload%s %s\n' "$cpu_total" "$muted" "$reset" "$load"
  printf '%s%-10s%s ' "$strong" MEMORY "$reset"; bar "$memory_used" "$bar_width"; printf ' %5.1f%%   %sused%s %s / %s\n' "$memory_used" "$muted" "$reset" "$(human_bytes $(( memory_total * memory_used / 100 )))" "$(human_bytes "$memory_total")"
  printf '%s%-10s%s ' "$strong" STORAGE "$reset"; bar "${disk_percent:-0}" "$bar_width"; printf ' %5.1f%%   %sused%s %s / %s\n' "${disk_percent:-0}" "$muted" "$reset" "$(human_bytes $(( ${disk_used_k:-0} * 1024 )))" "$(human_bytes $(( ${disk_total_k:-0} * 1024 )))"
  printf '%s%-10s%s %sdown%s %-11s  %sup%s %-11s  %stotal%s %s / %s\n' "$strong" NETWORK "$reset" "$muted" "$reset" "$(human_bytes "$rx_rate")/s" "$muted" "$reset" "$(human_bytes "$tx_rate")/s" "$muted" "$reset" "$(human_bytes "$rx")" "$(human_bytes "$tx")"

  printf '\n%s%s TOP PROCESSES / %s%s\n' "$accent" "$strong" "${sort_mode:u}" "$reset"
  printf '%s%s%s\n' "$muted" "$rule" "$reset"
  printf '%s%6s  %6s  %8s  %s%s\n' "$muted" PID CPU% MEMORY COMMAND "$reset"
  local process_rows=$(( rows - 14 )); (( process_rows < 4 )) && process_rows=4; (( process_rows > 12 )) && process_rows=12
  local ps_flag=-r
  [[ "$sort_mode" == memory ]] && ps_flag=-m
  /bin/ps -A -o pid=,pcpu=,rss=,comm= "$ps_flag" 2>/dev/null | /usr/bin/head -n "$process_rows" | while read pid pcpu rss command; do
    local command_width=$(( columns - 29 )); (( command_width < 20 )) && command_width=20
    command=${command:t}
    printf '%6s  %6s  %8s  %s\n' "$pid" "$pcpu" "$(human_bytes $(( rss * 1024 )))" "${command[1,$command_width]}"
  done

  printf '%s%s%s\n' "$muted" "$rule" "$reset"
  if (( once )); then
    printf '%sSnapshot complete.%s\n' "$muted" "$reset"
  else
    printf '%sQ%s quit   %sP%s %s   %sC%s CPU sort   %sM%s memory sort   %sR%s refresh\n' "$accent" "$reset" "$accent" "$reset" "$([[ $paused == 1 ]] && print resume || print pause)" "$accent" "$reset" "$accent" "$reset" "$accent" "$reset"
  fi
}

while true; do
  (( paused )) || render
  (( once )) && break
  key=''
  read -rsk1 -t 1 key 2>/dev/null || true
  case "${key:l}" in
    q) break ;;
    p) paused=$(( 1 - paused )); (( paused )) || render ;;
    c) sort_mode=cpu; paused=0; render ;;
    m) sort_mode=memory; paused=0; render ;;
    r) paused=0; render ;;
  esac
done
