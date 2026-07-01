#!/usr/bin/env bash
# ============================================================================
# local-tools-launcher.sh  -  Interactive CUI launcher for the local tools
#
# Colored, drill-down menu that reads tools/tool-catalog.yaml and lets you:
#   - pick a tool (numbered selection)
#   - set each parameter interactively (per-parameter prompts, type-aware)
#   - choose config files (middleware.conf / filelist.conf / *.lst ...)
#   - preview the command, run it, and optionally tar.gz the run for transfer
#
# Reports are NOT generated here — copy the run output (or the collect-snapshot
# ZIP) to Windows and use the Windows "スナップショット一括実行" report feature.
#
# Requires: bash 4+, awk, tar (for archiving). No ncurses/whiptail dependency.
# ============================================================================
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CATALOG_PATH="${SCRIPT_DIR}/tools/tool-catalog.yaml"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/aws-ec2-manager"
CONFIG_PATH="${CONFIG_DIR}/local-tools-launcher.conf"
DEFAULT_TOOLS_ROOT="${SCRIPT_DIR}/tools"
DEFAULT_OUTPUT_ROOT="${SCRIPT_DIR}/reports/local-tools"

TOOLS_ROOT=""
OUTPUT_ROOT=""
DEFAULT_AWS_PROFILE=""
declare -A CFG_OVERRIDE   # "toolid::label" -> chosen absolute path

# ── Colors ──────────────────────────────────────────────────────────────────
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_MAGENTA=$'\033[35m'; C_CYAN=$'\033[36m'
else
  C_RESET=''; C_BOLD=''; C_DIM=''
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_MAGENTA=''; C_CYAN=''
fi

say()  { printf '%s\n' "$*"; }
hr()   { printf '%s%s%s\n' "$C_DIM" "----------------------------------------------------------------" "$C_RESET"; }
title(){ printf '%s%s%s\n' "$C_BOLD$C_CYAN" "$*" "$C_RESET"; }
info() { printf '%s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }
ok()   { printf '%s%s%s\n' "$C_GREEN" "$*" "$C_RESET"; }
warn() { printf '%s%s%s\n' "$C_YELLOW" "$*" "$C_RESET"; }
err()  { printf '%s%s%s\n' "$C_RED" "$*" "$C_RESET"; }

read_value() {
  # prompt, default -> echoes chosen value (prompt goes to stderr so command
  # substitution captures only the value)
  local prompt="$1" default_value="$2" value
  printf '%s%s%s [%s%s%s]: ' "$C_BOLD" "$prompt" "$C_RESET" "$C_YELLOW" "$default_value" "$C_RESET" >&2
  read -r value
  [ -z "$value" ] && value="$default_value"
  printf '%s' "$value"
}

# ── Config ──────────────────────────────────────────────────────────────────
quote_config_value() { printf "%s" "$1" | sed "s/'/'\\\\''/g"; }

save_config() {
  mkdir -p "$CONFIG_DIR"
  {
    printf "TOOLS_ROOT='%s'\n" "$(quote_config_value "$TOOLS_ROOT")"
    printf "OUTPUT_ROOT='%s'\n" "$(quote_config_value "$OUTPUT_ROOT")"
    printf "DEFAULT_AWS_PROFILE='%s'\n" "$(quote_config_value "$DEFAULT_AWS_PROFILE")"
    local k
    for k in "${!CFG_OVERRIDE[@]}"; do
      printf "CFG_OVERRIDE[%s]='%s'\n" "'$(quote_config_value "$k")'" "$(quote_config_value "${CFG_OVERRIDE[$k]}")"
    done
  } > "$CONFIG_PATH"
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
  [ -z "${OUTPUT_ROOT:-}" ] && OUTPUT_ROOT="$DEFAULT_OUTPUT_ROOT"
  [ -z "${TOOLS_ROOT:-}" ]  && TOOLS_ROOT="$DEFAULT_TOOLS_ROOT"
}

# ── Catalog parser ────────────────────────────────────────────────────────────
# Emits tab-separated typed rows:
#   TOOL  <id> <name> <description> <menu> <linuxPath> <defaultArgs>
#   PARAM <id> <key> <label> <type> <width> <argument> <default> <value> <required>
#   CFG   <id> <label> <path> <envVar> <argName> <paramKey>
catalog_all() {
  awk '
    function trim(s){ sub(/^[ \t\r]+/,"",s); sub(/[ \t\r]+$/,"",s); return s }
    function scalar(s,   q){
      s=trim(s)
      q=substr(s,1,1)
      if((q=="\"" && substr(s,length(s),1)=="\"")||(q=="'"'"'" && substr(s,length(s),1)=="'"'"'"))
        s=substr(s,2,length(s)-2)
      return s
    }
    function emit_tool(){ if(t_id!="") print "TOOL", t_id, t_name, t_desc, t_menu, t_lin, t_args }
    function emit_param(){ if(p_key!="") print "PARAM", t_id, p_key, p_label, p_type, p_width, p_arg, p_def, p_val, p_req; p_key="" }
    function emit_cfg(){ if(c_label!="") print "CFG", t_id, c_label, c_path, c_env, c_argn, c_pk; c_label="" }
    function reset_param(){ p_key="";p_label="";p_type="text";p_width="";p_arg="";p_def="";p_val="";p_req="false" }
    function reset_cfg(){ c_label="";c_path="";c_env="";c_argn="";c_pk="" }

    BEGIN{ OFS=sprintf("%c",31); t_id="";section="";reset_param();reset_cfg() }

    /^  -[ \t]+id:/ {
      emit_param(); emit_cfg(); emit_tool()
      t_id=scalar(substr($0,index($0,"id:")+3))
      t_name="";t_desc="";t_menu="true";t_lin="";t_args=""
      section=""; reset_param(); reset_cfg()
      next
    }
    t_id=="" { next }

    /^      -[ \t]+key:/ {
      if(section=="pm"){ emit_param(); reset_param(); p_key=scalar(substr($0,index($0,"key:")+4)) }
      next
    }
    /^      -[ \t]+label:/ {
      if(section=="cf"){ emit_cfg(); reset_cfg(); c_label=scalar(substr($0,index($0,"label:")+6)) }
      next
    }
    /^        [A-Za-z0-9_]+:/ {
      key=$0; sub(/^[ \t]+/,"",key); sub(/:.*/,"",key)
      val=$0; sub(/^[ \t]+[A-Za-z0-9_]+:[ \t]*/,"",val); val=scalar(val)
      if(section=="pm"){
        if(key=="label")p_label=val
        else if(key=="type")p_type=val
        else if(key=="width")p_width=val
        else if(key=="argument")p_arg=val
        else if(key=="default")p_def=val
        else if(key=="value")p_val=val
        else if(key=="required")p_req=val
      } else if(section=="cf"){
        if(key=="path")c_path=val
        else if(key=="envVar")c_env=val
        else if(key=="argName")c_argn=val
        else if(key=="paramKey")c_pk=val
      }
      next
    }
    /^    [A-Za-z0-9_]+:/ {
      emit_param(); emit_cfg(); reset_param(); reset_cfg()
      key=$0; sub(/^[ \t]+/,"",key); sub(/:.*/,"",key)
      val=$0; sub(/^[ \t]+[A-Za-z0-9_]+:[ \t]*/,"",val); val=scalar(val)
      if(key=="configFiles"){ section="cf" }
      else if(key=="parameters"){ section="pm" }
      else {
        section=""
        if(key=="name")t_name=val
        else if(key=="description")t_desc=val
        else if(key=="menu")t_menu=val
        else if(key=="linuxPath")t_lin=val
        else if(key=="defaultArgs")t_args=val
      }
      next
    }
    END{ emit_param(); emit_cfg(); emit_tool() }
  ' "$CATALOG_PATH"
}

# ── Expansion ─────────────────────────────────────────────────────────────────
expand_tpl() {
  # template, tool_dir, run_dir
  local tpl="$1" tool_dir="$2" run_dir="$3" out
  out="$tpl"
  out=${out//\{ToolDir\}/$tool_dir}
  out=${out//\{RunDir\}/$run_dir}
  out=${out//\{ArtifactsDir\}/$run_dir/artifacts}
  out=${out//\{AwsProfile\}/$DEFAULT_AWS_PROFILE}
  printf '%s' "$out"
}

cfg_default_path() { printf '%s' "${TOOLS_ROOT}/$1"; }   # relative path -> abs
cfg_effective_path() {
  # toolid, label, relpath
  local key="$1::$2"
  if [ -n "${CFG_OVERRIDE[$key]:-}" ]; then printf '%s' "${CFG_OVERRIDE[$key]}"; else cfg_default_path "$3"; fi
}

# ── Menu: tool list ───────────────────────────────────────────────────────────
declare -a MENU_IDS MENU_NAMES MENU_LINS
declare -A MENU_NAMES_BY_ID
build_menu() {
  MENU_IDS=(); MENU_NAMES=(); MENU_LINS=(); MENU_NAMES_BY_ID=()
  local kind id name desc menu lin args
  while IFS=$'\037' read -r kind id name desc menu lin args; do
    [ "$kind" = "TOOL" ] || continue
    [ "$menu" = "true" ] || continue
    MENU_IDS+=("$id"); MENU_NAMES+=("$name"); MENU_LINS+=("$lin")
    MENU_NAMES_BY_ID["$id"]="$name"
  done < <(catalog_all)
}

# ── Run a selected tool ───────────────────────────────────────────────────────
run_tool() {
  local id="$1" lin="$2"
  local tool_dir="${TOOLS_ROOT}/$(dirname "$lin")"
  local entry="${TOOLS_ROOT}/${lin}"
  if [ ! -f "$entry" ]; then err "エントリが見つかりません: $entry"; return; fi

  # Load PARAM / CFG rows for this tool
  local -a P_KEY P_LABEL P_TYPE P_WIDTH P_ARG P_DEF P_VAL P_REQ
  local -a CF_LABEL CF_PATH CF_ENV CF_ARGN CF_PK
  P_KEY=(); P_LABEL=(); P_TYPE=(); P_WIDTH=(); P_ARG=(); P_DEF=(); P_VAL=(); P_REQ=()
  CF_LABEL=(); CF_PATH=(); CF_ENV=(); CF_ARGN=(); CF_PK=()
  local kind rid a b c d e f g h
  while IFS=$'\037' read -r kind rid a b c d e f g h; do
    [ "$rid" = "$id" ] || continue
    if [ "$kind" = "PARAM" ]; then
      P_KEY+=("$a"); P_LABEL+=("$b"); P_TYPE+=("$c"); P_WIDTH+=("$d")
      P_ARG+=("$e"); P_DEF+=("$f"); P_VAL+=("$g"); P_REQ+=("$h")
    elif [ "$kind" = "CFG" ]; then
      CF_LABEL+=("$a"); CF_PATH+=("$b"); CF_ENV+=("$c"); CF_ARGN+=("$d"); CF_PK+=("$e")
    fi
  done < <(catalog_all)

  # Map paramKey -> cfg index
  local -A PK_TO_CFG
  local i
  for i in "${!CF_LABEL[@]}"; do
    [ -n "${CF_PK[$i]}" ] && PK_TO_CFG["${CF_PK[$i]}"]="$i"
  done

  local stamp run_dir
  stamp=$(date '+%Y%m%d-%H%M%S')
  run_dir="${OUTPUT_ROOT}/${id}/${stamp}"
  mkdir -p "${run_dir}/artifacts"

  say ""
  title "▶ ${MENU_NAMES_BY_ID[$id]:-$id}  ($id)"
  hr

  local -a ARGS ENVS
  ARGS=(); ENVS=()

  # 1) config files WITHOUT paramKey (envVar / argName) -> prompt + route
  local shown_cfg_header="no"
  for i in "${!CF_LABEL[@]}"; do
    [ -z "${CF_PK[$i]}" ] || continue
    if [ "$shown_cfg_header" = "no" ]; then info "設定ファイル:"; shown_cfg_header="yes"; fi
    local eff val
    eff=$(cfg_effective_path "$id" "${CF_LABEL[$i]}" "${CF_PATH[$i]}")
    val=$(read_value "  ${CF_LABEL[$i]}" "$eff")
    if [ "$val" != "$(cfg_default_path "${CF_PATH[$i]}")" ]; then
      CFG_OVERRIDE["$id::${CF_LABEL[$i]}"]="$val"; save_config
    else
      unset "CFG_OVERRIDE[$id::${CF_LABEL[$i]}]" 2>/dev/null || true; save_config
    fi
    if [ -n "${CF_ENV[$i]}" ]; then ENVS+=("${CF_ENV[$i]}=$val")
    elif [ -n "${CF_ARGN[$i]}" ]; then ARGS+=("${CF_ARGN[$i]}" "$val"); fi
  done

  # 2) parameters
  local shown_param_header="no"
  for i in "${!P_KEY[@]}"; do
    local type="${P_TYPE[$i]}" key="${P_KEY[$i]}" label="${P_LABEL[$i]}"
    local arg="${P_ARG[$i]}" def="${P_DEF[$i]}" pval="${P_VAL[$i]}"
    if [ "$type" = "hidden" ]; then
      local hv; hv=$(expand_tpl "$pval" "$tool_dir" "$run_dir")
      [ -n "$arg" ] && ARGS+=("$arg")
      [ -n "$hv" ] && ARGS+=("$hv")
      continue
    fi
    if [ "$shown_param_header" = "no" ]; then say ""; info "実行パラメーター:"; shown_param_header="yes"; fi

    if [ "$type" = "checkbox" ]; then
      local dflt="N"; [ "$def" = "true" ] && dflt="Y"
      local ans; ans=$(read_value "  ${label}? (y/n)" "$dflt")
      case "$ans" in
        y|Y|yes|YES)
          [ -n "$arg" ] && ARGS+=("$arg")
          if [ -n "$pval" ]; then local cv; cv=$(expand_tpl "$pval" "$tool_dir" "$run_dir"); ARGS+=("$cv"); fi
          ;;
      esac
      continue
    fi

    # text / number: paramKey config uses effective path as default
    local initial cfgidx=""
    if [ -n "${PK_TO_CFG[$key]:-}" ]; then
      cfgidx="${PK_TO_CFG[$key]}"
      initial=$(cfg_effective_path "$id" "${CF_LABEL[$cfgidx]}" "${CF_PATH[$cfgidx]}")
    else
      initial=$(expand_tpl "$def" "$tool_dir" "$run_dir")
    fi
    local v; v=$(read_value "  ${label}" "$initial")
    if [ "${P_REQ[$i]}" = "true" ] && [ -z "$v" ]; then
      warn "  （必須ですが空です）"
    fi
    if [ -n "$cfgidx" ]; then
      if [ "$v" != "$(cfg_default_path "${CF_PATH[$cfgidx]}")" ]; then
        CFG_OVERRIDE["$id::${CF_LABEL[$cfgidx]}"]="$v"; save_config
      else
        unset "CFG_OVERRIDE[$id::${CF_LABEL[$cfgidx]}]" 2>/dev/null || true; save_config
      fi
    fi
    if [ -n "$v" ]; then
      [ -n "$arg" ] && ARGS+=("$arg")
      ARGS+=("$v")
    fi
  done

  # 3) preview
  say ""
  info "コマンドプレビュー:"
  local preview="" a e
  for e in ${ENVS[@]+"${ENVS[@]}"}; do preview+="$e "; done
  preview+="bash $(printf '%q' "$entry")"
  for a in ${ARGS[@]+"${ARGS[@]}"}; do preview+=" $(printf '%q' "$a")"; done
  printf '%s%s%s\n' "$C_CYAN" "$preview" "$C_RESET"
  printf '%s\n' "$preview" > "${run_dir}/command.txt"

  say ""
  local go; go=$(read_value "実行しますか? (y/n)" "y")
  case "$go" in
    y|Y|yes|YES) ;;
    *) warn "キャンセルしました。"; return ;;
  esac

  # 4) execute
  say ""
  info "実行中..."
  local rc
  if [ "${#ENVS[@]}" -gt 0 ]; then
    ( cd "$tool_dir" && env "${ENVS[@]}" bash "$entry" ${ARGS[@]+"${ARGS[@]}"} ) \
      > "${run_dir}/stdout.log" 2> "${run_dir}/stderr.log"
  else
    ( cd "$tool_dir" && bash "$entry" ${ARGS[@]+"${ARGS[@]}"} ) \
      > "${run_dir}/stdout.log" 2> "${run_dir}/stderr.log"
  fi
  rc=$?
  printf '%s\n' "$rc" > "${run_dir}/exit-code.txt"

  if [ "$rc" -eq 0 ]; then ok "完了 (exit=$rc)"; else err "エラー (exit=$rc)"; fi
  info "出力: $run_dir"
  if [ -s "${run_dir}/stdout.log" ]; then say ""; info "--- stdout (末尾) ---"; tail -n 30 "${run_dir}/stdout.log"; fi
  if [ -s "${run_dir}/stderr.log" ]; then say ""; warn "--- stderr (末尾) ---"; tail -n 30 "${run_dir}/stderr.log"; fi

  # 5) offer archive for transfer to Windows
  say ""
  local arch; arch=$(read_value "この run を tar.gz にまとめますか? (Windows へ転送用) (y/n)" "n")
  case "$arch" in
    y|Y|yes|YES)
      local tgz="${OUTPUT_ROOT}/${id}_${stamp}.tar.gz"
      if tar -czf "$tgz" -C "${OUTPUT_ROOT}/${id}" "$stamp" 2>/dev/null; then
        ok "作成: $tgz"
      else
        err "tar.gz の作成に失敗しました。"
      fi
      ;;
  esac
}

# ── collect-snapshot 一括収集 (delegates to its own --menu) ────────────────────
run_collect_snapshot() {
  local entry="${TOOLS_ROOT}/collect-snapshot/collect_snapshot.sh"
  if [ ! -f "$entry" ]; then err "collect_snapshot.sh が見つかりません: $entry"; return; fi
  say ""
  title "▶ スナップショット一括収集"
  info "collect_snapshot.sh の対話モードを起動します（ZIP を生成し Windows へ持ち帰り）。"
  hr
  ( cd "${TOOLS_ROOT}/collect-snapshot" && bash "$entry" --menu )
}

# ── Settings ──────────────────────────────────────────────────────────────────
settings_menu() {
  say ""
  title "設定"
  TOOLS_ROOT=$(read_value "ToolsRoot" "$TOOLS_ROOT")
  OUTPUT_ROOT=$(read_value "OutputRoot" "$OUTPUT_ROOT")
  DEFAULT_AWS_PROFILE=$(read_value "DefaultAwsProfile" "$DEFAULT_AWS_PROFILE")
  save_config
  ok "保存しました: $CONFIG_PATH"
}

# ── Main menu ─────────────────────────────────────────────────────────────────
main_menu() {
  build_menu
  local i choice
  while true; do
    say ""
    title "==== Local Tools Launcher (Linux) ===="
    info "ToolsRoot : $TOOLS_ROOT"
    info "OutputRoot: $OUTPUT_ROOT"
    [ -n "$DEFAULT_AWS_PROFILE" ] && info "AWS Profile: $DEFAULT_AWS_PROFILE"
    say ""
    printf '%s c)%s %sスナップショット一括収集%s  %s(ZIP を作成し Windows でレポート化)%s\n' \
      "$C_BOLD$C_MAGENTA" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_DIM" "$C_RESET"
    say ""
    info "ツール個別実行:"
    for i in "${!MENU_IDS[@]}"; do
      printf '%s%2d)%s %-22s %s%s%s\n' \
        "$C_BOLD$C_GREEN" "$((i+1))" "$C_RESET" "${MENU_IDS[$i]}" "$C_DIM" "${MENU_NAMES[$i]}" "$C_RESET"
    done
    say ""
    printf '  %ss)%s 設定   %sq)%s 終了\n' "$C_YELLOW" "$C_RESET" "$C_YELLOW" "$C_RESET"
    printf '%s選択:%s ' "$C_BOLD" "$C_RESET"
    read -r choice
    case "$choice" in
      q|Q) break ;;
      c|C) run_collect_snapshot ;;
      s|S) settings_menu ;;
      ''|*[!0-9]*) err "無効な選択です。" ;;
      *)
        local idx=$((choice-1))
        if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#MENU_IDS[@]}" ]; then
          run_tool "${MENU_IDS[$idx]}" "${MENU_LINS[$idx]}"
        else
          err "無効な選択です。"
        fi
        ;;
    esac
  done
}

# ── Entry ─────────────────────────────────────────────────────────────────────
if [ ! -f "$CATALOG_PATH" ]; then err "カタログが見つかりません: $CATALOG_PATH"; exit 1; fi
load_config
mkdir -p "$OUTPUT_ROOT"
main_menu
