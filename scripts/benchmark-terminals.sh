#!/bin/zsh
set -euo pipefail

root=${0:A:h:h}
term_app=${TERM_APP:-"$root/build/Termatica.app"}
ghostty_app=${GHOSTTY_APP:-/Applications/Ghostty.app}
kitty_app=${KITTY_APP:-/Applications/kitty.app}
output=${BENCHMARK_OUTPUT:-/tmp/termatica-benchmark-results}
repetitions=${BENCHMARK_REPETITIONS:-10}
kitten="$kitty_app/Contents/MacOS/kitten"
kitty="$kitty_app/Contents/MacOS/kitty"
ghostty="$ghostty_app/Contents/MacOS/ghostty"
term="$term_app/Contents/MacOS/Termatica"
term_cli="$term_app/Contents/MacOS/termatica"
probe="$root/scripts/benchmark_probe.py"
config=/tmp/termatica-benchmark-config

for required in "$term" "$term_cli" "$ghostty" "$kitty" "$kitten" "$probe"; do
  if [[ ! -x "$required" ]]; then
    print -u2 "missing executable: $required"
    exit 2
  fi
done

mkdir -p "$output" "$config"
pids=()
cleanup() {
  for pid in $pids; do
    kill "$pid" 2>/dev/null || true
  done
}
trap cleanup EXIT INT TERM

wait_for_file() {
  local file_path=$1
  for _ in {1..240}; do
    [[ -s "$file_path" ]] && return 0
    sleep 0.25
  done
  print -u2 "timed out waiting for $file_path"
  return 1
}

configure_term_command() {
  local command=$1
  TERMATICA_CONFIG_DIR="$config" "$term_cli" config set shell '"/bin/zsh"' >/dev/null
  TERMATICA_CONFIG_DIR="$config" "$term_cli" config set shellArguments \
    "[\"-lc\",\"${command//\"/\\\"}\"]" >/dev/null
}

run_official() {
  local render_flag=$1 suffix=$2 command
  command="$kitten __benchmark__ $render_flag --repetitions $repetitions ascii unicode csi"

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
  open -n "$ghostty_app" --args --config-file=/dev/null --font-family=Monaco \
    --font-size=11 -e /bin/zsh -lc "$command > '$output/ghostty-$suffix.txt' 2>&1; exit"
  wait_for_file "$output/ghostty-$suffix.txt"
  local ghost_pid
  ghost_pid=$(ps -axo pid=,command= | awk -v marker="$output/ghostty-$suffix.txt" \
    'index($0, marker) && index($0, "Ghostty.app/Contents/MacOS/ghostty") && !found {print $1; found=1}')
  [[ -n "$ghost_pid" ]] && kill "$ghost_pid" 2>/dev/null || true
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
    else
      open -n "$ghostty_app" --args --config-file=/dev/null --font-family=Monaco \
        --font-size=11 -e /usr/bin/python3 "$probe" "$stamp"
      pid=
    fi
    wait_for_file "$stamp"
    child=$(<"$stamp")
    /usr/bin/python3 -c "print(round(($child-$start)/1_000_000, 3))" >> "$result"
    if [[ -n "${pid:-}" ]]; then
      kill "$pid" 2>/dev/null || true
    else
      pid=$(ps -axo pid=,command= | awk -v marker="$stamp" \
        'index($0, marker) && index($0, "Ghostty.app/Contents/MacOS/ghostty") && !found {print $1; found=1}')
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
  else
    open -n "$ghostty_app" --args --config-file=/dev/null --font-family=Monaco \
      --font-size=11 -e /usr/bin/python3 "$probe" "$stamp"
    wait_for_file "$stamp"
    pid=$(ps -axo pid=,command= | awk -v marker="$stamp" \
      'index($0, marker) && index($0, "Ghostty.app/Contents/MacOS/ghostty") && !found {print $1; found=1}')
  fi
  wait_for_file "$stamp"
  sleep 1
  {
    ps -o pid=,rss=,vsz=,command= -p "$pid"
    vmmap -summary "$pid" 2>/dev/null | grep -E \
      'Physical footprint:|Physical footprint \\(peak\\):'
  } > "$output/$name-memory.txt"
  kill "$pid" 2>/dev/null || true
}

{
  print "terminal\tversion\tbundle_kib"
  print "termatica\t$("$term" --version | awk 'NR==1{print}')\t$(( $(du -sk "$term_app" | awk '{print $1}') ))"
  print "ghostty\t$("$ghostty" +version | awk 'NR==1{print}')\t$(( $(du -sk "$ghostty_app" | awk '{print $1}') ))"
  print "kitty\t$("$kitty" --version)\t$(( $(du -sk "$kitty_app" | awk '{print $1}') ))"
} > "$output/environment.tsv"

run_official "" parser
run_official "--render" render
TERMATICA_CONFIG_DIR="$config" "$term" --benchmark-core 33554432 > "$output/termatica-core.json"
TERMATICA_CONFIG_DIR="$config" "$term" --benchmark-experience 240 3 > "$output/termatica-experience.json"
measure_memory termatica
measure_memory kitty
measure_memory ghostty
measure_startup termatica ""
measure_startup kitty ""
measure_startup ghostty ""

print "Benchmark results: $output"
