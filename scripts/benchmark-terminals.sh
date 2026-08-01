#!/bin/zsh
set -euo pipefail

root=${0:A:h:h}
term_app=${TERM_APP:-"$root/build/Termatica.app"}
ghostty_app=${GHOSTTY_APP:-/Applications/Ghostty.app}
kitty_app=${KITTY_APP:-/Applications/kitty.app}
alacritty_app=${ALACRITTY_APP:-/Applications/Alacritty.app}
wezterm_app=${WEZTERM_APP:-/Applications/WezTerm.app}
rio_app=${RIO_APP:-/Applications/Rio.app}
output=${BENCHMARK_OUTPUT:-/tmp/termatica-benchmark-results}
repetitions=${BENCHMARK_REPETITIONS:-10}
benchmark_cases=${BENCHMARK_CASES:-"ascii unicode unique_unicode csi images long_escape_codes"}
benchmark_timeout_seconds=${BENCHMARK_TIMEOUT_SECONDS:-300}
kitten="$kitty_app/Contents/MacOS/kitten"
kitty="$kitty_app/Contents/MacOS/kitty"
ghostty="$ghostty_app/Contents/MacOS/ghostty"
alacritty="$alacritty_app/Contents/MacOS/alacritty"
wezterm="$wezterm_app/Contents/MacOS/wezterm"
rio="$rio_app/Contents/MacOS/rio"
term="$term_app/Contents/MacOS/Termatica"
term_cli="$term_app/Contents/MacOS/termatica"
term_bench=${TERM_BENCHMARK:-"$root/build/TermaticaBenchmark"}
probe="$root/scripts/benchmark_probe.py"
if [[ -n "${BENCHMARK_CONFIG_DIR:-}" ]]; then
  config=$BENCHMARK_CONFIG_DIR
  temporary_config=0
else
  config=$(mktemp -d /tmp/termatica-benchmark-config.XXXXXX)
  temporary_config=1
fi

for required in "$term" "$term_cli" "$term_bench" "$ghostty" "$kitty" "$kitten" "$probe"; do
  if [[ ! -x "$required" ]]; then
    print -u2 "missing executable: $required"
    exit 2
  fi
done

mkdir -p "$output" "$config"
extra_terminals=()
[[ -x "$alacritty" ]] && extra_terminals+=(alacritty)
[[ -x "$wezterm" ]] && extra_terminals+=(wezterm)
[[ -x "$rio" ]] && extra_terminals+=(rio)
mkdir -p "$config/rio/rio"
print 'local wezterm = require "wezterm"\nreturn { font = wezterm.font("Monaco"), font_size = 11.0, enable_tab_bar = false, window_close_confirmation = "NeverPrompt" }' > "$config/wezterm.lua"
print '[fonts]\nfamily = "Monaco"\nsize = 11' > "$config/rio/rio/config.toml"
pids=()
cleanup() {
  for pid in $pids; do
    kill "$pid" 2>/dev/null || true
  done
  if (( temporary_config )); then
    rm -rf -- "$config"
  fi
}
trap cleanup EXIT INT TERM

wait_for_file() {
  local file_path=$1
  local attempts=$((benchmark_timeout_seconds * 4))
  for ((index = 0; index < attempts; index++)); do
    [[ -s "$file_path" ]] && return 0
    sleep 0.25
  done
  print -u2 "timed out waiting for $file_path"
  return 1
}

find_ghostty_process() {
  local marker=$1
  ps -axo pid=,command= | awk -v marker="$marker" \
    'index($0, marker) && index($0, "Ghostty.app/Contents/MacOS/ghostty") && !index($0, "awk -v marker=") && !found {print $1; found=1}'
}

wait_for_ghostty_process() {
  local marker=$1 pid
  for _ in {1..100}; do
    pid=$(find_ghostty_process "$marker")
    if [[ -n "$pid" ]]; then
      print "$pid"
      return 0
    fi
    sleep 0.1
  done
  print -u2 "timed out finding Ghostty process for $marker"
  return 1
}

launch_ghostty() {
  local command=$1 marker=$2
  local runner="$marker.ghostty.zsh"
  {
    print '#!/bin/zsh'
    print -r -- "$command"
  } > "$runner"
  chmod 700 "$runner"
  open -na "$ghostty_app" --args --config-file=/dev/null --font-family=Monaco \
    --font-size=11 "--command=/bin/zsh $runner"
}

configure_term_command() {
  local command=$1
  TERMATICA_CONFIG_DIR="$config" "$term_cli" config set shell '"/bin/zsh"' >/dev/null
  TERMATICA_CONFIG_DIR="$config" "$term_cli" config set shellArguments \
    "[\"-lc\",\"${command//\"/\\\"}\"]" >/dev/null
}

launch_extra() {
  local name=$1 command=$2 log=$3
  case "$name" in
    alacritty)
      "$alacritty" --config-file /dev/null -o 'font.normal.family="Monaco"' \
        -o font.size=11 -e /bin/zsh -lc "$command" >"$log" 2>&1 &
      ;;
    wezterm)
      "$wezterm" --config-file "$config/wezterm.lua" start --always-new-process -- \
        /bin/zsh -lc "$command" >"$log" 2>&1 &
      ;;
    rio)
      XDG_CONFIG_HOME="$config/rio" "$rio" -e /bin/zsh -lc "$command" >"$log" 2>&1 &
      ;;
  esac
  print $!
}

run_extra_official() {
  local name=$1 render_flag=$2 suffix=$3 cases=${4:-$benchmark_cases}
  local command="$kitten __benchmark__ $render_flag --repetitions $repetitions $cases"
  local result="$output/$name-$suffix.txt" pid
  : > "$result"
  pid=$(launch_extra "$name" "$command > '$result' 2>&1; exit" "$output/$name-$suffix-app.log")
  pids+=($pid)
  wait_for_file "$result"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pids=()
}

run_official() {
  local render_flag=$1 suffix=$2 cases=${3:-$benchmark_cases} command
  command="$kitten __benchmark__ $render_flag --repetitions $repetitions $cases"

  : > "$output/termatica-$suffix.txt"
  configure_term_command "$command > '$output/termatica-$suffix.txt' 2>&1; exit"
  TERMATICA_CONFIG_DIR="$config" TERMATICA_NO_BLUR=1 "$term" \
    >"$output/termatica-$suffix-app.log" 2>&1 &
  pids+=($!)
  wait_for_file "$output/termatica-$suffix.txt"
  kill "$pids[-1]" 2>/dev/null || true
  pids=()

  : > "$output/kitty-$suffix.txt"
  "$kitty" --config NONE -o font_family=Monaco -o font_size=11 \
    /bin/zsh -lc "$command > '$output/kitty-$suffix.txt' 2>&1; exit" \
    >"$output/kitty-$suffix-app.log" 2>&1 &
  pids+=($!)
  wait_for_file "$output/kitty-$suffix.txt"
  kill "$pids[-1]" 2>/dev/null || true
  pids=()

  : > "$output/ghostty-$suffix.txt"
  launch_ghostty "$command > '$output/ghostty-$suffix.txt' 2>&1; exit" \
    "$output/ghostty-$suffix.txt"
  local ghost_pid
  ghost_pid=$(wait_for_ghostty_process "$output/ghostty-$suffix.txt")
  pids+=($ghost_pid)
  wait_for_file "$output/ghostty-$suffix.txt"
  kill "$ghost_pid" 2>/dev/null || true
  pids=()
}

measure_startup() {
  local name=$1
  local result="$output/$name-startup-ms.txt"
  local stamp start pid child
  : > "$result"
  for index in {1..5}; do
    stamp="$output/$name-startup-$index.ns"
    pid=
    : > "$stamp"
    start=$(/usr/bin/python3 -c 'import time; print(time.monotonic_ns())')
    if [[ "$name" == termatica ]]; then
      configure_term_command "/usr/bin/python3 '$probe' '$stamp'"
      TERMATICA_CONFIG_DIR="$config" TERMATICA_NO_BLUR=1 "$term" >/dev/null 2>&1 &
      pid=$!
    elif [[ "$name" == kitty ]]; then
      "$kitty" --config NONE -o font_family=Monaco -o font_size=11 \
        /usr/bin/python3 "$probe" "$stamp" >/dev/null 2>&1 &
      pid=$!
    elif [[ "$name" == ghostty ]]; then
      launch_ghostty "/usr/bin/python3 '$probe' '$stamp'" "$stamp"
      pid=$(wait_for_ghostty_process "$stamp")
      pids+=($pid)
    else
      pid=$(launch_extra "$name" "/usr/bin/python3 '$probe' '$stamp'" "$output/$name-startup-$index.log")
      pids+=($pid)
    fi
    wait_for_file "$stamp"
    child=$(<"$stamp")
    /usr/bin/python3 -c "print(round(($child-$start)/1_000_000, 3))" >> "$result"
    if [[ -n "${pid:-}" ]]; then
      kill "$pid" 2>/dev/null || true
      pids=()
    else
      pid=$(find_ghostty_process "$stamp")
      [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    fi
  done
}

measure_memory() {
  local name=$1 stamp="$output/$1-memory-ready.ns" pid
  : > "$stamp"
  if [[ "$name" == termatica ]]; then
    configure_term_command "/usr/bin/python3 '$probe' '$stamp'"
    TERMATICA_CONFIG_DIR="$config" TERMATICA_NO_BLUR=1 "$term" >/dev/null 2>&1 &
    pid=$!
  elif [[ "$name" == kitty ]]; then
    "$kitty" --config NONE -o font_family=Monaco -o font_size=11 \
      /usr/bin/python3 "$probe" "$stamp" >/dev/null 2>&1 &
    pid=$!
  elif [[ "$name" == ghostty ]]; then
    launch_ghostty "/usr/bin/python3 '$probe' '$stamp'" "$stamp"
    pid=$(wait_for_ghostty_process "$stamp")
    pids+=($pid)
    wait_for_file "$stamp"
  else
    pid=$(launch_extra "$name" "/usr/bin/python3 '$probe' '$stamp'" "$output/$name-memory-app.log")
    pids+=($pid)
  fi
  wait_for_file "$stamp"
  sleep 1
  {
    ps -o pid=,rss=,vsz=,command= -p "$pid"
    vmmap -summary "$pid" 2>/dev/null | grep -E \
      'Physical footprint:|Physical footprint \\(peak\\):'
  } > "$output/$name-memory.txt"
  kill "$pid" 2>/dev/null || true
  pids=()
}

{
  print "terminal\tversion\tbundle_kib"
  print "termatica\t$("$term" --version | awk 'NR==1{print}')\t$(( $(du -sk "$term_app" | awk '{print $1}') ))"
  print "ghostty\t$("$ghostty" +version | awk 'NR==1{print}')\t$(( $(du -sk "$ghostty_app" | awk '{print $1}') ))"
  print "kitty\t$("$kitty" --version)\t$(( $(du -sk "$kitty_app" | awk '{print $1}') ))"
  [[ -x "$alacritty" ]] && print "alacritty\t$("$alacritty" --version | awk 'NR==1{print}')\t$(( $(du -sk "$alacritty_app" | awk '{print $1}') ))"
  [[ -x "$wezterm" ]] && print "wezterm\t$("$wezterm" --version | awk 'NR==1{print}')\t$(( $(du -sk "$wezterm_app" | awk '{print $1}') ))"
  [[ -x "$rio" ]] && print "rio\t$("$rio" --version | awk 'NR==1{print}')\t$(( $(du -sk "$rio_app" | awk '{print $1}') ))"
} > "$output/environment.tsv"

run_official "" parser
run_official "--render" render
run_official "--with-scrollback" scrollback "ascii unicode csi"
for name in $extra_terminals; do
  run_extra_official "$name" "" parser
  run_extra_official "$name" "--render" render
  run_extra_official "$name" "--with-scrollback" scrollback "ascii unicode csi"
done
TERMATICA_CONFIG_DIR="$config" "$term_bench" --benchmark-decoder 33554432 > "$output/termatica-decoder.json"
TERMATICA_CONFIG_DIR="$config" "$term_bench" --benchmark-core 33554432 > "$output/termatica-core.json"
TERMATICA_CONFIG_DIR="$config" "$term_bench" --benchmark-experience 240 3 > "$output/termatica-experience.json"
measure_memory termatica
measure_memory kitty
measure_memory ghostty
for name in $extra_terminals; do measure_memory "$name"; done
measure_startup termatica ""
measure_startup kitty ""
measure_startup ghostty ""
for name in $extra_terminals; do measure_startup "$name" ""; done

print "Benchmark results: $output"
