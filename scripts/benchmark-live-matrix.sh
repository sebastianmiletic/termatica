#!/bin/zsh
set -u
set -o pipefail

benchmark_mode=${1:-termatica}
font_name=${2:-Monaco}
font_size=${3:-11}
term_exec=${4:-}
active_config=${5:-}
result_path=${6:-}
repetitions=${TERMATICA_BENCHMARK_REPETITIONS:-1}
timeout_seconds=${TERMATICA_BENCHMARK_TIMEOUT:-180}
total_terminals=$([[ ${1:-termatica} == all ]] && print 6 || print 1)
cache_root=${TERMATICA_BENCHMARK_OUTPUT_ROOT:-"$HOME/Library/Caches/Termatica/Benchmarks"}
run_stamp=$(date -u +%Y%m%dT%H%M%SZ)
output="$cache_root/$run_stamp-$$"
latest="$cache_root/latest"
work=$(mktemp -d "${TMPDIR:-/tmp}/termatica-live-benchmark.XXXXXX") || exit 1

kitty_app=/Applications/Kitty.app
[[ -d $kitty_app ]] || kitty_app=/Applications/kitty.app
kitten="$kitty_app/Contents/MacOS/kitten"
kitty="$kitty_app/Contents/MacOS/kitty"
ghostty_app=/Applications/Ghostty.app
ghostty="$ghostty_app/Contents/MacOS/ghostty"
alacritty_app=/Applications/Alacritty.app
alacritty="$alacritty_app/Contents/MacOS/alacritty"
wezterm_app=/Applications/WezTerm.app
wezterm="$wezterm_app/Contents/MacOS/wezterm"
rio_app=/Applications/Rio.app
rio="$rio_app/Contents/MacOS/rio"

typeset -a launched_pids
typeset -A parser_files render_files states versions
typeset -A source_kinds source_times
stop_pid() {
  local pid=${1:-}
  [[ $pid == <-> ]] || return 0
  kill "$pid" 2>/dev/null || return 0
  local index
  for index in {1..40}; do
    kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null || true; return 0; }
    sleep 0.05
  done
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

cleanup() {
  printf '\033[r\033[0m\033[?25h'
  local pid
  for pid in $launched_pids; do stop_pid "$pid"; done
  rm -rf -- "$work"
}
trap cleanup EXIT INT TERM HUP

mkdir -p "$output" || exit 1
# Isolated benchmark terminals never need the caller's working directory. This
# also prevents a run started in Desktop, Documents, or Downloads from causing
# an unrelated macOS protected-folder access request.
cd "$work" || exit 1

if [[ $benchmark_mode != termatica && $benchmark_mode != all ]]; then
  print -u2 "termatica benchmark: expected mode 'termatica' or 'all'"
  exit 2
fi

if [[ ! -x $kitten ]]; then
  print -u2 "termatica benchmark: Kitty's kitten benchmark driver is not installed."
  print -u2 "Install Kitty to run the fresh cross-terminal matrix. No saved values were used."
  exit 2
fi

cases=(ascii unicode unique_unicode csi long_escape_codes images)

write_runner() {
  local runner=$1 parser=$2 render=$3 started_file=$4 done_file=$5 status_file=$6
  {
    print '#!/bin/zsh'
    print 'set +e'
    printf ': > %q\n' "$started_file"
    printf '%q __benchmark__ --repetitions %q' "$kitten" "$repetitions"
    printf ' %q' $cases
    printf ' > %q 2>&1\n' "$parser"
    print 'parser_status=$?'
    printf '%q __benchmark__ --render --repetitions %q' "$kitten" "$repetitions"
    printf ' %q' $cases
    printf ' > %q 2>&1\n' "$render"
    print 'render_status=$?'
    printf "printf '%%s %%s\\n' \"\$parser_status\" \"\$render_status\" > %q\n" "$status_file"
    printf ': > %q\n' "$done_file"
    print 'exit 0'
  } > "$runner"
  chmod 700 "$runner"
}

find_ghostty_process() {
  local marker=$1
  ps -axo pid=,command= | awk -v marker="$marker" \
    'index($0, marker) && index($0, "Ghostty.app/Contents/MacOS/ghostty") && !index($0, "awk -v marker=") && !found {print $1; found=1}'
}

wait_for_ghostty_process() {
  local marker=$1 pid index
  for index in {1..100}; do
    pid=$(find_ghostty_process "$marker")
    [[ -n $pid ]] && { print "$pid"; return 0; }
    sleep 0.1
  done
  return 1
}

wait_for_done() {
  local done_file=$1 pid=${2:-} ticks=$((timeout_seconds * 4)) index
  for ((index=0; index<ticks; index++)); do
    [[ -e $done_file ]] && return 0
    if [[ $pid == <-> ]] && ! kill -0 "$pid" 2>/dev/null; then return 1; fi
    sleep 0.25
  done
  return 1
}

wait_for_started() {
  local started_file=$1 ticks=60 index
  for ((index=0; index<ticks; index++)); do
    [[ -e $started_file ]] && return 0
    sleep 0.25
  done
  return 1
}

run_external() {
  local name=$1 number=$2 executable=$3 app=$4
  local parser="$output/$name-parser.txt" render="$output/$name-render.txt"
  local runner="$work/$name-runner.zsh" started_file="$work/$name.started" done_file="$work/$name.done" status_file="$work/$name.status"
  local pid= launch_log="$output/$name-app.log"
  parser_files[$name]=$parser
  render_files[$name]=$render
  if [[ ! -x $executable ]]; then
    states[$name]=MISSING
    return 0
  fi
  write_runner "$runner" "$parser" "$render" "$started_file" "$done_file" "$status_file"
  printf '\r  [%s/%s] %-10s starting fresh workloads...\033[K' "$number" "$total_terminals" "${(C)name}"
  case $name in
    termatica)
      if [[ ! -f $active_config ]]; then
        states[$name]=FAILED
        printf '\r  [%s/%s] %-10s %s\033[K\n' "$number" "$total_terminals" "${(C)name}" "${states[$name]}"
        return 0
      fi
      mkdir -p "$work/termatica-config"
      cp "$active_config" "$work/termatica-config/config.json"
      TERMATICA_CONFIG_DIR="$work/termatica-config" "$term_exec" config set shell '"/bin/zsh"' >/dev/null
      TERMATICA_CONFIG_DIR="$work/termatica-config" "$term_exec" config set shellArguments "[\"$runner\"]" >/dev/null
      TERMATICA_CONFIG_DIR="$work/termatica-config" TERMATICA_NO_BLUR=1 "$term_exec" >"$launch_log" 2>&1 &
      pid=$!
      ;;
    kitty)
      "$executable" --config NONE -o "font_family=$font_name" -o "font_size=$font_size" /bin/zsh "$runner" >"$launch_log" 2>&1 &
      pid=$!
      ;;
    ghostty)
      open -na "$app" --args --config-default-files=false --font-family="$font_name" --font-size="$font_size" "--initial-command=/bin/zsh $runner" >"$launch_log" 2>&1
      pid=$(wait_for_ghostty_process "$runner")
      ;;
    alacritty)
      "$executable" --config-file /dev/null -o "font.normal.family=\"$font_name\"" -o "font.size=$font_size" -e /bin/zsh "$runner" >"$launch_log" 2>&1 &
      pid=$!
      ;;
    wezterm)
      print "local wezterm = require 'wezterm'\nreturn { font = wezterm.font('$font_name'), font_size = $font_size, enable_tab_bar = false, window_close_confirmation = 'NeverPrompt' }" > "$work/wezterm.lua"
      "$executable" --config-file "$work/wezterm.lua" start --always-new-process -- /bin/zsh "$runner" >"$launch_log" 2>&1 &
      pid=$!
      ;;
    rio)
      mkdir -p "$work/rio/rio"
      print "[fonts]\nfamily = \"$font_name\"\nsize = $font_size" > "$work/rio/rio/config.toml"
      XDG_CONFIG_HOME="$work/rio" "$executable" -e /bin/zsh "$runner" >"$launch_log" 2>&1 &
      pid=$!
      ;;
  esac
  if [[ $pid == <-> ]]; then launched_pids+=($pid); fi
  if ! wait_for_started "$started_file"; then
    stop_pid "$pid"
    launched_pids=(${launched_pids:#$pid})
    if [[ $name == ghostty ]]; then
      open -Fna "$app" --args --config-default-files=false --font-family="$font_name" --font-size="$font_size" "--initial-command=/bin/zsh $runner" >>"$launch_log" 2>&1
      pid=$(wait_for_ghostty_process "$runner")
      [[ $pid == <-> ]] && launched_pids+=($pid)
    else
      states[$name]=LAUNCH-FAILED
      printf '\r  [%s/%s] %-10s %s\033[K\n' "$number" "$total_terminals" "${(C)name}" "${states[$name]}"
      return 0
    fi
  fi
  if ! wait_for_started "$started_file"; then
    states[$name]=LAUNCH-FAILED
    stop_pid "$pid"
    launched_pids=(${launched_pids:#$pid})
    printf '\r  [%s/%s] %-10s %s\033[K\n' "$number" "$total_terminals" "${(C)name}" "${states[$name]}"
    return 0
  fi
  if wait_for_done "$done_file" "$pid"; then
    local pair
    pair=$(<"$status_file")
    [[ $pair == '0 0' ]] && states[$name]=OK || states[$name]=FAILED
  else
    states[$name]=TIMEOUT
  fi
  stop_pid "$pid"
  launched_pids=(${launched_pids:#$pid})
  printf '\r  [%s/%s] %-10s %s\033[K\n' "$number" "$total_terminals" "${(C)name}" "${states[$name]}"
}

extract_rate() {
  local file=$1 label=$2
  [[ -s $file ]] || { print n/a; return; }
  awk -v label="$label" '
    index($0,label) {
      line=$0
      gsub(sprintf("%c\\[[0-9;]*m",27),"",line)
      sub(/^.*@[[:space:]]*/,"",line)
      sub(/[[:space:]]*MB\/s.*$/,"",line)
      print line
      found=1
      exit
    }
    END {if(!found) print "n/a"}
  ' "$file"
}

geometric_mean() {
  awk 'BEGIN {for(i=1;i<ARGC;i++){if(ARGV[i]!="n/a"&&ARGV[i]+0>0){sum+=log(ARGV[i]);count++}}if(count==ARGC-1&&count)printf "%.1f",exp(sum/count);else printf "n/a"}' "$@"
}

load_saved() {
  local name=$1 directory="$latest/$1"
  if [[ -s "$directory/parser.txt" && -s "$directory/render.txt" && -s "$directory/meta.tsv" ]]; then
    parser_files[$name]="$directory/parser.txt"
    render_files[$name]="$directory/render.txt"
    states[$name]=OK
    source_kinds[$name]=SAVED
    source_times[$name]=$(awk -F '\t' '$1=="timestamp_utc"{print $2;exit}' "$directory/meta.tsv")
    versions[$name]=$(awk -F '\t' '$1=="version"{print $2;exit}' "$directory/meta.tsv")
  else
    states[$name]=NO-CACHE
    source_kinds[$name]=NONE
  fi
}

save_successful_result() {
  local name=$1 directory="$latest/$1"
  [[ ${states[$name]:-} == OK && ${source_kinds[$name]:-} == FRESH ]] || return 0
  mkdir -p "$directory"
  cp "${parser_files[$name]}" "$directory/parser.txt"
  cp "${render_files[$name]}" "$directory/render.txt"
  {
    printf 'timestamp_utc\t%s\n' "$run_stamp"
    printf 'version\t%s\n' "${versions[$name]:-unavailable}"
    printf 'font\t%s %s\n' "$font_name" "$font_size"
    printf 'repetitions\t%s\n' "$repetitions"
  } > "$directory/meta.tsv"
}

if [[ $benchmark_mode == all ]]; then
  print 'FRESH ALL-TERMINAL BENCHMARK'
  print 'Every numeric row is being measured now; successful results refresh the saved cache.'
else
  print 'FRESH TERMATICA BENCHMARK'
  print 'Termatica is measured now; competitor columns use their latest successful saved runs.'
fi
printf 'Repetitions: %s per workload.\n' "$repetitions"
print 'Only isolated processes started by this run will close.'
print
run_external termatica 1 "$term_exec" "${term_exec:h:h:h}"
source_kinds[termatica]=FRESH
source_times[termatica]=$run_stamp
if [[ $benchmark_mode == all ]]; then
  run_external kitty 2 "$kitty" "$kitty_app"
  run_external ghostty 3 "$ghostty" "$ghostty_app"
  run_external alacritty 4 "$alacritty" "$alacritty_app"
  run_external wezterm 5 "$wezterm" "$wezterm_app"
  run_external rio 6 "$rio" "$rio_app"
  for name in kitty ghostty alacritty wezterm rio; do source_kinds[$name]=FRESH; source_times[$name]=$run_stamp; done
else
  for name in kitty ghostty alacritty wezterm rio; do load_saved "$name"; done
fi

terminals=(termatica kitty ghostty alacritty wezterm rio)
labels=('ASCII' 'Unicode' 'Unique graphemes' 'CSI-heavy' 'Long escapes' 'Image stream')
source_labels=('Only ASCII chars' 'Unicode chars' 'Unique multi-codepoint Unicode cells' 'CSI codes with few chars' 'Long escape codes' 'Images')

versions[termatica]=$($term_exec --version 2>/dev/null | head -1)
if [[ $benchmark_mode == all ]]; then
  versions[kitty]=$($kitty --version 2>/dev/null | head -1)
  versions[ghostty]=$($ghostty +version 2>/dev/null | head -1)
  versions[alacritty]=$($alacritty --version 2>/dev/null | head -1)
  versions[wezterm]=$($wezterm --version 2>/dev/null | head -1)
  versions[rio]=$($rio --version 2>/dev/null | head -1)
fi
for name in $terminals; do save_successful_result "$name"; done

typeset -A all_rates
: > "$output/matrix.tsv"
print -r -- $'mode\tworkload\ttermatica\tkitty\tghostty\talacritty\twezterm\trio' >> "$output/matrix.tsv"
for mode in parser render; do
  for index in {1..6}; do
    row="$mode ${labels[$index]}"
    typeset -a values
    values=()
    for name in $terminals; do
      if [[ $mode == parser ]]; then file=${parser_files[$name]:-}; else file=${render_files[$name]:-}; fi
      value=$(extract_rate "$file" "${source_labels[$index]}")
      [[ ${states[$name]:-FAILED} == OK || ${states[$name]:-FAILED} == SAVED ]] || value=n/a
      values+=($value)
      all_rates["$name-$mode-$index"]=$value
    done
    { printf '%s\t%s' "$mode" "${labels[$index]}"; printf '\t%s' $values; printf '\n'; } >> "$output/matrix.tsv"
  done
done

typeset -a means
means=()
for name in $terminals; do
  typeset -a values
  values=()
  for mode in parser render; do
    for index in {1..6}; do values+=("${all_rates["$name-$mode-$index"]}"); done
  done
  means+=("$(geometric_mean $values)")
done
{ printf 'summary\t12-workload geo mean'; printf '\t%s' $means; printf '\n'; } >> "$output/matrix.tsv"

{
  print "timestamp_utc\t$run_stamp"
  print "repetitions\t$repetitions"
  print "font\t$font_name $font_size"
  print "mode\t$benchmark_mode"
  for name in $terminals; do print "$name\t${states[$name]:-FAILED}\t${source_kinds[$name]:-NONE}\t${source_times[$name]:--}\t${versions[$name]:-unavailable}"; done
} > "$output/manifest.tsv"

print
print '12-WORKLOAD ACCEPTED THROUGHPUT · MiB/s higher is better'
if [[ -t 1 ]]; then table_bold=1; else table_bold=0; fi
awk -F '\t' -v bold="$table_bold" '
  BEGIN {
    keys[1]="termatica"; names[1]="Termatica"
    keys[2]="kitty"; names[2]="Kitty"
    keys[3]="ghostty"; names[3]="Ghostty"
    keys[4]="alacritty"; names[4]="Alacritty"
    keys[5]="wezterm"; names[5]="WezTerm"
    keys[6]="rio"; names[6]="Rio"
  }
  FNR==NR {
    if (FNR==1) next
    mode=$1
    for (i=1;i<=6;i++) {
      value=$(i+2)
      if (mode=="summary") combined[i]=value
      else {
        rates[mode,i,workload_count[mode]+1]=value
        if (value!="n/a" && value+0>0) { logs[mode,i]+=log(value+0); counts[mode,i]++ }
      }
    }
    if (mode!="summary") workload_count[mode]++
    next
  }
  $1=="termatica"||$1=="kitty"||$1=="ghostty"||$1=="alacritty"||$1=="wezterm"||$1=="rio" { sources[$1]=$3 }
  function repeat(character,count, result) { result=""; while(count-->0)result=result character; return result }
  function print_mode(mode,title, i,column,position,value,winner) {
    print title " · MiB/s"
    mode_headers[1]="TERM"; mode_headers[2]="ASCII"; mode_headers[3]="UNICODE"; mode_headers[4]="GRAPHEME"; mode_headers[5]="CSI"; mode_headers[6]="ESCAPES"; mode_headers[7]="IMAGES"; mode_headers[8]="GEO"
    delete mode_widths; delete mode_maximum
    for(column=1;column<=8;column++)mode_widths[column]=length(mode_headers[column])
    for(i=1;i<=6;i++) {
      mode_cells[i,1]=names[i]
      for(position=1;position<=6;position++)mode_cells[i,position+1]=rates[mode,i,position]!=""?rates[mode,i,position]:"n/a"
      mode_cells[i,8]=counts[mode,i]==6?sprintf("%.1f",exp(logs[mode,i]/6)):"n/a"
      mode_geo[mode,i]=mode_cells[i,8]
      for(column=1;column<=8;column++) {
        if(length(mode_cells[i,column])>mode_widths[column])mode_widths[column]=length(mode_cells[i,column])
        if(column>1&&mode_cells[i,column]!="n/a"&&mode_cells[i,column]+0>mode_maximum[column])mode_maximum[column]=mode_cells[i,column]+0
      }
    }
    printf "%-*s",mode_widths[1],mode_headers[1]; for(column=2;column<=8;column++)printf " |%*s",mode_widths[column],mode_headers[column]; printf "\n"
    printf "%s",repeat("-",mode_widths[1]); for(column=2;column<=8;column++)printf "+%s",repeat("-",mode_widths[column]+1); printf "\n"
    for(i=1;i<=6;i++) {
      printf "%-*s",mode_widths[1],mode_cells[i,1]
      for(column=2;column<=8;column++) {
        value=mode_cells[i,column];winner=value!="n/a"&&mode_maximum[column]>0&&(value+0)==mode_maximum[column]
        printf " |";if(bold&&winner)printf "\033[1m";printf "%*s",mode_widths[column],value;if(bold&&winner)printf "\033[0m"
      }
      printf "\n"
    }
    print ""
  }
  function print_summary( i,column,winner) {
    print "SUMMARY · 12-workload geometric mean"
    headers[1]="TERM"; headers[2]="PARSE"; headers[3]="RENDER"; headers[4]="MB/s"; headers[5]="MS/MiB"; headers[6]="SCORE"; headers[7]="SRC"
    for (column=1;column<=7;column++) widths[column]=length(headers[column])
    maximum=0
    for (i=1;i<=6;i++) if (combined[i]!="n/a" && combined[i]+0>maximum) maximum=combined[i]+0
    for (i=1;i<=6;i++) {
      cells[i,1]=names[i]
      cells[i,2]=mode_geo["parser",i]
      cells[i,3]=mode_geo["render",i]
      cells[i,4]=combined[i]!="n/a"?sprintf("%.1f",combined[i]+0):"n/a"
      cells[i,5]=combined[i]!="n/a"&&combined[i]+0>0?sprintf("%.2f",1000/(combined[i]+0)):"n/a"
      cells[i,6]=combined[i]!="n/a"&&maximum>0?sprintf("%.0f",100*(combined[i]+0)/maximum):"n/a"
      cells[i,7]=sources[keys[i]]!=""?sources[keys[i]]:"NONE"
      for(column=1;column<=7;column++)if(length(cells[i,column])>widths[column])widths[column]=length(cells[i,column])
    }
    printf "%-*s",widths[1],headers[1]; for(column=2;column<=7;column++)printf " |%*s",widths[column],headers[column]; printf "\n"
    printf "%s",repeat("-",widths[1]); for(column=2;column<=7;column++)printf "+%s",repeat("-",widths[column]+1); printf "\n"
    for(i=1;i<=6;i++) {
      winner=combined[i]!="n/a"&&maximum>0&&(combined[i]+0)==maximum
      if(bold&&winner)printf "\033[1m"
      printf "%-*s",widths[1],cells[i,1]; for(column=2;column<=7;column++)printf " |%*s",widths[column],cells[i,column]; if(bold&&winner)printf "\033[0m"; printf "\n"
    }
  }
  END { print_mode("parser","PARSER"); print_mode("render","RENDER"); print_summary() }
' "$output/matrix.tsv" "$output/manifest.tsv"

if [[ -n $result_path ]]; then
  umask 077
  print -r -- "$output" > "$result_path"
fi

print
print "Run artifacts: $output"
print 'Results will open in Termatica’s native benchmark window.'
print 'Scope: Kitty kitten parser acceptance and asynchronous render-enabled throughput.'
print 'This does not measure visual correctness, displayed-frame completion, or key-to-photon latency.'

if [[ $benchmark_mode == all ]]; then
  for name in $terminals; do [[ ${states[$name]:-FAILED} == OK ]] || exit 1; done
else
  [[ ${states[termatica]:-FAILED} == OK ]] || exit 1
fi
exit 0
