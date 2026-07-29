#!/bin/zsh
set -euo pipefail

root=${0:A:h:h}
term_app=${TERM_APP:-"$root/build/Termatica.app"}
ghostty_app=${GHOSTTY_APP:-/Applications/Ghostty.app}
kitty_app=${KITTY_APP:-/Applications/kitty.app}
output=${BENCHMARK_OUTPUT:-/tmp/termatica-benchmark-results}
repetitions=${BENCHMARK_REPETITIONS:-10}
benchmark_cases=${BENCHMARK_CASES:-"ascii unicode unique_unicode csi images long_escape_codes"}
benchmark_timeout_seconds=${BENCHMARK_TIMEOUT_SECONDS:-300}
kitten="$kitty_app/Contents/MacOS/kitten"
kitty="$kitty_app/Contents/MacOS/kitty"
ghostty="$ghostty_app/Contents/MacOS/ghostty"
term="$term_app/Contents/MacOS/Termatica"
term_cli="$term_app/Contents/MacOS/termatica"
term_bench=${TERM_BENCHMARK:-"$root/build/TermaticaBenchmark"}
probe="$root/scripts/benchmark_probe.py"
config=/tmp/termatica-benchmark-config

for required in "$term" "$term_cli" "$term_bench" "$ghostty" "$kitty" "$kitten" "$probe"; do
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

configure_term_command() {
  local command=$1
  TERMATICA_CONFIG_DIR="$config" "$term_cli" config set shell '"/bin/zsh"' >/dev/null
  TERMATICA_CONFIG_DIR="$config" "$term_cli" config set shellArguments \
    "[\"-lc\",\"${command//\"/\\\"}\"]" >/dev/null
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
  open -n "$ghostty_app" --args --config-file=/dev/null --font-family=Monaco \
    --font-size=11 -e /bin/zsh -lc "$command > '$output/ghostty-$suffix.txt' 2>&1; exit"
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
    else
      open -n "$ghostty_app" --args --config-file=/dev/null --font-family=Monaco \
        --font-size=11 -e /usr/bin/python3 "$probe" "$stamp"
      pid=$(wait_for_ghostty_process "$stamp")
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
  else
    open -n "$ghostty_app" --args --config-file=/dev/null --font-family=Monaco \
      --font-size=11 -e /usr/bin/python3 "$probe" "$stamp"
    pid=$(wait_for_ghostty_process "$stamp")
    pids+=($pid)
    wait_for_file "$stamp"
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
} > "$output/environment.tsv"

run_official "" parser
run_official "--render" render
run_official "--with-scrollback" scrollback "ascii unicode csi"
TERMATICA_CONFIG_DIR="$config" "$term_bench" --benchmark-decoder 33554432 > "$output/termatica-decoder.json"
TERMATICA_CONFIG_DIR="$config" "$term_bench" --benchmark-core 33554432 > "$output/termatica-core.json"
TERMATICA_CONFIG_DIR="$config" "$term_bench" --benchmark-experience 240 3 > "$output/termatica-experience.json"
measure_memory termatica
measure_memory kitty
measure_memory ghostty
measure_startup termatica ""
measure_startup kitty ""
measure_startup ghostty ""

print "Benchmark results: $output"
