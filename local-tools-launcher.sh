#!/usr/bin/env bash
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CATALOG_PATH="${SCRIPT_DIR}/tools/tool-catalog.yaml"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/aws-ec2-manager"
CONFIG_PATH="${CONFIG_DIR}/local-tools-launcher.conf"
DEFAULT_TOOLS_ROOT="${SCRIPT_DIR}/tools"
DEFAULT_OUTPUT_ROOT="${SCRIPT_DIR}/reports/local-tools"
LAST_RUN_DIR=""

TOOLS_ROOT=""
OUTPUT_ROOT=""
DEFAULT_AWS_PROFILE=""

say() {
  printf '%s\n' "$*"
}

read_value() {
  prompt="$1"
  default_value="$2"
  printf '%s [%s]: ' "$prompt" "$default_value"
  read -r value
  if [ -z "$value" ]; then
    value="$default_value"
  fi
  printf '%s' "$value"
}

load_config() {
  if [ -f "$CONFIG_PATH" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_PATH"
  fi
  if [ -z "${TOOLS_ROOT:-}" ]; then
    mkdir -p "$CONFIG_DIR"
    TOOLS_ROOT=$(read_value "ToolsRoot" "$DEFAULT_TOOLS_ROOT")
    OUTPUT_ROOT=$(read_value "OutputRoot" "$DEFAULT_OUTPUT_ROOT")
    DEFAULT_AWS_PROFILE=$(read_value "DefaultAwsProfile" "")
    save_config
  fi
  if [ -z "${OUTPUT_ROOT:-}" ]; then
    OUTPUT_ROOT="$DEFAULT_OUTPUT_ROOT"
  fi
}

quote_config_value() {
  printf "%s" "$1" | sed "s/'/'\\\\''/g"
}

save_config() {
  mkdir -p "$CONFIG_DIR"
  {
    printf "TOOLS_ROOT='%s'\n" "$(quote_config_value "$TOOLS_ROOT")"
    printf "OUTPUT_ROOT='%s'\n" "$(quote_config_value "$OUTPUT_ROOT")"
    printf "DEFAULT_AWS_PROFILE='%s'\n" "$(quote_config_value "$DEFAULT_AWS_PROFILE")"
  } > "$CONFIG_PATH"
}

catalog_rows() {
  awk '
    function trim(s) {
      sub(/^[ \t\r\n]+/, "", s)
      sub(/[ \t\r\n]+$/, "", s)
      return s
    }
    function scalar(s) {
      s = trim(s)
      if ((substr(s, 1, 1) == "\"" && substr(s, length(s), 1) == "\"") ||
          (substr(s, 1, 1) == "'"'"'" && substr(s, length(s), 1) == "'"'"'")) {
        s = substr(s, 2, length(s) - 2)
      }
      return s
    }
    function emit() {
      if (id != "") {
        print id "\t" name "\t" description "\t" menu "\t" windowsPath "\t" linuxPath "\t" defaultArgs
      }
    }
    /^[ \t]*-[ \t]+id:/ {
      emit()
      id = scalar(substr($0, index($0, "id:") + 3))
      name = ""
      description = ""
      menu = "true"
      windowsPath = ""
      linuxPath = ""
      defaultArgs = ""
      next
    }
    /^[ \t]+[A-Za-z0-9_]+:/ {
      key = $0
      sub(/^[ \t]+/, "", key)
      sub(/:.*/, "", key)
      val = $0
      sub(/^[ \t]+[A-Za-z0-9_]+:[ \t]*/, "", val)
      val = scalar(val)
      if (key == "name") name = val
      else if (key == "description") description = val
      else if (key == "menu") menu = val
      else if (key == "windowsPath") windowsPath = val
      else if (key == "linuxPath") linuxPath = val
      else if (key == "defaultArgs") defaultArgs = val
      next
    }
    END { emit() }
  ' "$CATALOG_PATH"
}

list_tools() {
  i=1
  while IFS=$'\t' read -r id name description menu windows_path linux_path default_args; do
    if [ -n "$id" ] && [ "$menu" = "true" ]; then
      printf '%2d) %-24s %s\n' "$i" "$id" "$name"
      i=$((i + 1))
    fi
  done <<EOF
$(catalog_rows)
EOF
}

get_tool_by_index() {
  wanted="$1"
  i=1
  while IFS=$'\t' read -r id name description menu windows_path linux_path default_args; do
    if [ -z "$id" ] || [ "$menu" != "true" ]; then
      continue
    fi
    if [ "$i" = "$wanted" ]; then
      TOOL_ID="$id"
      TOOL_NAME="$name"
      TOOL_DESCRIPTION="$description"
      TOOL_LINUX_PATH="$linux_path"
      TOOL_DEFAULT_ARGS="$default_args"
      return 0
    fi
    i=$((i + 1))
  done <<EOF
$(catalog_rows)
EOF
  return 1
}

new_run_dir() {
  stamp=$(date '+%Y%m%d-%H%M%S')
  run_dir="${OUTPUT_ROOT}/${TOOL_ID}/${stamp}"
  mkdir -p "${run_dir}/artifacts"
  printf '%s' "$run_dir"
}

expand_args() {
  template="$1"
  run_dir="$2"
  tool_dir="${TOOLS_ROOT}/$(dirname "$TOOL_LINUX_PATH")"
  artifacts_dir="${run_dir}/artifacts"
  expanded=${template//\{ToolDir\}/$tool_dir}
  expanded=${expanded//\{RunDir\}/$run_dir}
  expanded=${expanded//\{ArtifactsDir\}/$artifacts_dir}
  expanded=${expanded//\{AwsProfile\}/$DEFAULT_AWS_PROFILE}
  printf '%s' "$expanded"
}

run_tool() {
  if [ -z "${TOOL_LINUX_PATH:-}" ]; then
    say "Linux entry is not defined for ${TOOL_ID}."
    return
  fi
  tool_dir="${TOOLS_ROOT}/$(dirname "$TOOL_LINUX_PATH")"
  entry="${TOOLS_ROOT}/${TOOL_LINUX_PATH}"
  if [ ! -f "$entry" ]; then
    say "Entry file not found: $entry"
    return
  fi
  run_dir=$(new_run_dir)
  LAST_RUN_DIR="$run_dir"
  default_args=$(expand_args "$TOOL_DEFAULT_ARGS" "$run_dir")
  say ""
  say "${TOOL_NAME}"
  say "${TOOL_DESCRIPTION}"
  say ""
  printf 'Arguments [%s]: ' "$default_args"
  read -r args
  if [ -z "$args" ]; then
    args="$default_args"
  fi
  command_text="cd \"$tool_dir\" && bash \"$entry\" $args"
  printf '%s\n' "$command_text" > "${run_dir}/command.txt"
  say ""
  say "Command:"
  say "$command_text"
  printf 'Run? [y/N]: '
  read -r answer
  case "$answer" in
    y|Y|yes|YES) ;;
    *) say "Canceled."; return ;;
  esac
  (
    cd "$tool_dir" || exit 98
    ENTRY_PATH="$entry" eval 'bash "$ENTRY_PATH" '"$args"
  ) > "${run_dir}/stdout.log" 2> "${run_dir}/stderr.log"
  exit_code=$?
  printf '%s\n' "$exit_code" > "${run_dir}/exit-code.txt"
  say "ExitCode: $exit_code"
  say "Output: $run_dir"
  if [ -s "${run_dir}/stdout.log" ]; then
    say "--- stdout ---"
    tail -n 40 "${run_dir}/stdout.log"
  fi
  if [ -s "${run_dir}/stderr.log" ]; then
    say "--- stderr ---"
    tail -n 40 "${run_dir}/stderr.log"
  fi
}

settings_menu() {
  say ""
  TOOLS_ROOT=$(read_value "ToolsRoot" "$TOOLS_ROOT")
  OUTPUT_ROOT=$(read_value "OutputRoot" "$OUTPUT_ROOT")
  DEFAULT_AWS_PROFILE=$(read_value "DefaultAwsProfile" "$DEFAULT_AWS_PROFILE")
  save_config
  say "Saved: $CONFIG_PATH"
}

main_menu() {
  while true; do
    say ""
    say "Local Tools Launcher"
    say "ToolsRoot : $TOOLS_ROOT"
    say "OutputRoot: $OUTPUT_ROOT"
    say ""
    list_tools
    say " s) settings"
    say " q) quit"
    printf 'Select: '
    read -r choice
    case "$choice" in
      q|Q) break ;;
      s|S) settings_menu ;;
      ''|*[!0-9]*) say "Invalid selection." ;;
      *)
        if get_tool_by_index "$choice"; then
          run_tool
        else
          say "Invalid selection."
        fi
        ;;
    esac
  done
}

if [ ! -f "$CATALOG_PATH" ]; then
  say "Catalog not found: $CATALOG_PATH"
  exit 1
fi

load_config
mkdir -p "$OUTPUT_ROOT"
main_menu
