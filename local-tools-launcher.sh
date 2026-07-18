#!/usr/bin/env bash
# ============================================================================
# local-tools-launcher.sh  -  Local tools launcher for Linux (v2)
#
# 対話メニュー(既定)と非対話サブコマンドの両対応:
#   local-tools-launcher.sh                  # 対話メニュー
#   local-tools-launcher.sh list             # ツール一覧 (TSV: id, name, description)
#   local-tools-launcher.sh run <tool-id> [--set key=value ...] [--dry-run]
#   local-tools-launcher.sh archive [<tool-id>]   # 直近 run を tar.gz 化
#
# 対話フロー(v2): ツール選択 → 既定値一覧 + コマンドプレビュー表示 →
#   Enter で即実行 / e で編集 / n で中止。実行中は stdout/stderr をライブ表示
#   しつつ run ディレクトリへ保存する。
#
# 終了ステータスの扱い(Windows 版と同じ意味論):
#   exit 0        → [ok]   完了
#   exit 1        → [warn] NG 検出またはエラー (cert-check / port-inventory 等)
#   exit 2 以上   → [FAIL] 失敗
#   exit 128 以上 → [warn] 中断 (シグナル)
#
# カタログ: tools/tool-catalog.yaml を Windows 版と共用。
#   Linux 用の引数名は parameters[].linuxArgument / configFiles[].linuxArgName
#   を優先し、無ければ argument / argName を使う。
#
# HTML レポートは Linux では開かない。run 出力(または collect-snapshot の ZIP)を
# Windows へ持ち帰り、Windows 版の「スナップショット一括実行 → レポート生成」で
# 表示する分業を維持する。
#
# Requires: bash 4+, awk, tar. ncurses / whiptail には依存しない。
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
LAST_RUN_DIR=""
declare -A CFG_OVERRIDE   # "toolid::label" -> chosen absolute path

# ── Colors (NO_COLOR / リダイレクト時は抑制) ────────────────────────────────
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
ok()   { printf '%s[ok]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
err()  { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$*"; }
# 非対話モードの進捗・診断は stderr へ(stdout はデータ専用)
note() { printf '%s\n' "$*" >&2; }

read_value() {
  # prompt, default -> echoes chosen value
  local prompt="$1" default_value="$2" value
  printf '%s%s%s [%s%s%s]: ' "$C_BOLD" "$prompt" "$C_RESET" "$C_YELLOW" "$default_value" "$C_RESET" >&2
  read -r value || value=""
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
    printf "LAST_RUN_DIR='%s'\n" "$(quote_config_value "$LAST_RUN_DIR")"
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
    DEFAULT_AWS_PROFILE=$(choose_aws_profile "$DEFAULT_AWS_PROFILE")
    save_config
  fi
  [ -z "${OUTPUT_ROOT:-}" ] && OUTPUT_ROOT="$DEFAULT_OUTPUT_ROOT"
  [ -z "${TOOLS_ROOT:-}" ]  && TOOLS_ROOT="$DEFAULT_TOOLS_ROOT"
}

# ── AWS profile chooser(~/.aws/config から抽出、無ければ自由入力) ─────────
list_aws_profiles() {
  local cfg="${AWS_CONFIG_FILE:-$HOME/.aws/config}"
  [ -f "$cfg" ] || return 0
  awk '
    /^\[default\]/ { print "default" }
    /^\[profile /  { p=$0; sub(/^\[profile[ \t]+/,"",p); sub(/\][ \t]*$/,"",p); if(p!="") print p }
  ' "$cfg"
}

choose_aws_profile() {
  # current -> echoes chosen profile (empty allowed)
  local current="$1"
  local -a profiles=()
  local p
  while IFS= read -r p; do [ -n "$p" ] && profiles+=("$p"); done < <(list_aws_profiles)
  if [ "${#profiles[@]}" -eq 0 ]; then
    read_value "AWS Profile (空欄可)" "$current"
    return
  fi
  {
    printf '%sAWS Profile を選択:%s\n' "$C_BOLD" "$C_RESET"
    local i
    for i in "${!profiles[@]}"; do
      printf '  %s%2d)%s %s\n' "$C_GREEN" "$((i+1))" "$C_RESET" "${profiles[$i]}"
    done
    printf '  %s 0)%s (未設定にする)\n' "$C_YELLOW" "$C_RESET"
  } >&2
  local choice
  choice=$(read_value "番号または名前" "$current")
  case "$choice" in
    0) printf '' ;;
    ''|*[!0-9]*) printf '%s' "$choice" ;;
    *)
      local idx=$((choice-1))
      if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#profiles[@]}" ]; then
        printf '%s' "${profiles[$idx]}"
      else
        printf '%s' "$current"
      fi
      ;;
  esac
}

# ── Catalog parser ────────────────────────────────────────────────────────────
# タブ区切り(US=0x1f)の型付き行を出力する:
#   TOOL  <id> <name> <description> <menu> <linuxPath> <defaultArgs>
#   PARAM <id> <key> <label> <type> <width> <argument> <linuxArgument> <default> <value> <required>
#   CFG   <id> <label> <path> <envVar> <argName> <linuxArgName> <paramKey>
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
    function emit_param(){ if(p_key!="") print "PARAM", t_id, p_key, p_label, p_type, p_width, p_arg, p_larg, p_def, p_val, p_req; p_key="" }
    function emit_cfg(){ if(c_label!="") print "CFG", t_id, c_label, c_path, c_env, c_argn, c_largn, c_pk; c_label="" }
    function reset_param(){ p_key="";p_label="";p_type="text";p_width="";p_arg="";p_larg="";p_def="";p_val="";p_req="false" }
    function reset_cfg(){ c_label="";c_path="";c_env="";c_argn="";c_largn="";c_pk="" }

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
        else if(key=="linuxArgument")p_larg=val
        else if(key=="default")p_def=val
        else if(key=="value")p_val=val
        else if(key=="required")p_req=val
      } else if(section=="cf"){
        if(key=="path")c_path=val
        else if(key=="envVar")c_env=val
        else if(key=="argName")c_argn=val
        else if(key=="linuxArgName")c_largn=val
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

# ── Tool metadata / menu ──────────────────────────────────────────────────────
declare -a MENU_IDS MENU_NAMES MENU_DESCS MENU_LINS
declare -A TOOL_NAME TOOL_DESC TOOL_LIN
build_menu() {
  MENU_IDS=(); MENU_NAMES=(); MENU_DESCS=(); MENU_LINS=()
  TOOL_NAME=(); TOOL_DESC=(); TOOL_LIN=()
  local kind id name desc menu lin args
  while IFS=$'\037' read -r kind id name desc menu lin args; do
    [ "$kind" = "TOOL" ] || continue
    TOOL_NAME["$id"]="$name"; TOOL_DESC["$id"]="$desc"; TOOL_LIN["$id"]="$lin"
    [ "$menu" = "true" ] || continue
    [ -n "$lin" ] || continue
    MENU_IDS+=("$id"); MENU_NAMES+=("$name"); MENU_DESCS+=("$desc"); MENU_LINS+=("$lin")
  done < <(catalog_all)
}

# ── Tool preparation(パラメータ・設定ファイルの読み込みと引数構築) ────────
# 読み込み結果はグローバル配列に置く(bash 関数から配列を返せないため)
declare -a P_KEY P_LABEL P_TYPE P_ARG P_DEF P_VAL P_REQ
declare -a CF_LABEL CF_PATH CF_ENV CF_ARGN CF_PK
declare -A PK_TO_CFG VAL

load_tool_defs() {
  # tool-id。PARAM/CFG 行をグローバル配列へ(linuxArgument/linuxArgName を優先解決)
  local id="$1"
  P_KEY=(); P_LABEL=(); P_TYPE=(); P_ARG=(); P_DEF=(); P_VAL=(); P_REQ=()
  CF_LABEL=(); CF_PATH=(); CF_ENV=(); CF_ARGN=(); CF_PK=()
  PK_TO_CFG=()
  local kind rid a b c d e f g h i2 j2
  while IFS=$'\037' read -r kind rid a b c d e f g h i2 j2; do
    [ "$rid" = "$id" ] || continue
    if [ "$kind" = "PARAM" ]; then
      # a=key b=label c=type d=width e=argument f=linuxArgument g=default h=value i2=required
      local effarg="$e"
      [ -n "$f" ] && effarg="$f"
      P_KEY+=("$a"); P_LABEL+=("$b"); P_TYPE+=("$c")
      P_ARG+=("$effarg"); P_DEF+=("$g"); P_VAL+=("$h"); P_REQ+=("$i2")
    elif [ "$kind" = "CFG" ]; then
      # a=label b=path c=envVar d=argName e=linuxArgName f=paramKey
      local effargn="$d"
      [ -n "$e" ] && effargn="$e"
      CF_LABEL+=("$a"); CF_PATH+=("$b"); CF_ENV+=("$c"); CF_ARGN+=("$effargn"); CF_PK+=("$f")
    fi
  done < <(catalog_all)
  local i
  for i in "${!CF_LABEL[@]}"; do
    [ -n "${CF_PK[$i]}" ] && PK_TO_CFG["${CF_PK[$i]}"]="$i"
  done
}

init_values() {
  # tool-id, tool_dir, run_dir: VAL[key] に既定値をセット(checkbox は true/false)
  local id="$1" tool_dir="$2" run_dir="$3"
  VAL=()
  local i key
  for i in "${!P_KEY[@]}"; do
    key="${P_KEY[$i]}"
    case "${P_TYPE[$i]}" in
      hidden) ;;  # 表示・編集対象外(build_args で value を展開)
      checkbox)
        if [ "${P_DEF[$i]}" = "true" ]; then VAL["$key"]="true"; else VAL["$key"]="false"; fi
        ;;
      *)
        if [ -n "${PK_TO_CFG[$key]:-}" ]; then
          local ci="${PK_TO_CFG[$key]}"
          VAL["$key"]=$(cfg_effective_path "$id" "${CF_LABEL[$ci]}" "${CF_PATH[$ci]}")
        else
          VAL["$key"]=$(expand_tpl "${P_DEF[$i]}" "$tool_dir" "$run_dir")
        fi
        ;;
    esac
  done
}

declare -a ARGS ENVS
build_args() {
  # tool-id, tool_dir, run_dir: VAL / CFG から ARGS・ENVS を構築
  local id="$1" tool_dir="$2" run_dir="$3"
  ARGS=(); ENVS=()
  local i
  # 1) paramKey の無い設定ファイル(envVar / argName ルート)
  for i in "${!CF_LABEL[@]}"; do
    [ -z "${CF_PK[$i]}" ] || continue
    local eff
    eff=$(cfg_effective_path "$id" "${CF_LABEL[$i]}" "${CF_PATH[$i]}")
    if [ -n "${CF_ENV[$i]}" ]; then ENVS+=("${CF_ENV[$i]}=$eff")
    elif [ -n "${CF_ARGN[$i]}" ]; then ARGS+=("${CF_ARGN[$i]}" "$eff"); fi
  done
  # 2) parameters
  for i in "${!P_KEY[@]}"; do
    local key="${P_KEY[$i]}" type="${P_TYPE[$i]}" arg="${P_ARG[$i]}"
    case "$type" in
      hidden)
        local hv
        hv=$(expand_tpl "${P_VAL[$i]}" "$tool_dir" "$run_dir")
        [ -n "$arg" ] && ARGS+=("$arg")
        [ -n "$hv" ] && ARGS+=("$hv")
        ;;
      checkbox)
        if [ "${VAL[$key]:-false}" = "true" ]; then
          [ -n "$arg" ] && ARGS+=("$arg")
          if [ -n "${P_VAL[$i]}" ]; then
            local cv
            cv=$(expand_tpl "${P_VAL[$i]}" "$tool_dir" "$run_dir")
            ARGS+=("$cv")
          fi
        fi
        ;;
      *)
        local v="${VAL[$key]:-}"
        if [ -n "$v" ]; then
          [ -n "$arg" ] && ARGS+=("$arg")
          ARGS+=("$v")
        fi
        ;;
    esac
  done
}

missing_required() {
  # -> 未入力の必須パラメーターのラベルを改行区切りで出力(無ければ空)
  local i
  for i in "${!P_KEY[@]}"; do
    [ "${P_REQ[$i]}" = "true" ] || continue
    [ "${P_TYPE[$i]}" = "hidden" ] && continue
    if [ -z "${VAL[${P_KEY[$i]}]:-}" ]; then printf '%s\n' "${P_LABEL[$i]}"; fi
  done
}

build_preview() {
  # entry -> echoes preview string(ARGS/ENVS 使用)
  local entry="$1" preview="" e a
  [ -n "$DEFAULT_AWS_PROFILE" ] && preview+="AWS_PROFILE=$DEFAULT_AWS_PROFILE "
  for e in ${ENVS[@]+"${ENVS[@]}"}; do preview+="$e "; done
  preview+="bash $(printf '%q' "$entry")"
  for a in ${ARGS[@]+"${ARGS[@]}"}; do preview+=" $(printf '%q' "$a")"; done
  printf '%s' "$preview"
}

print_result() {
  # rc, run_dir
  local rc="$1" run_dir="$2"
  if [ "$rc" -eq 0 ]; then
    ok "完了 (exit=0)  出力: $run_dir"
  elif [ "$rc" -ge 128 ]; then
    warn "中断されました (signal $((rc-128)))  出力: $run_dir"
  elif [ "$rc" -eq 1 ]; then
    warn "終了 (exit=1)  NG 検出またはエラー。stdout.log とレポートを確認してください: $run_dir"
  else
    err "失敗 (exit=$rc)  stderr.log を確認してください: $run_dir"
  fi
  # 成果物一覧(artifacts)
  if [ -d "${run_dir}/artifacts" ]; then
    local f listed=0
    while IFS= read -r f; do
      [ "$listed" -eq 0 ] && info "成果物:"
      info "  $f"
      listed=1
    done < <(find "${run_dir}/artifacts" -type f 2>/dev/null | sort)
    if [ "$listed" -eq 1 ]; then
      info "HTML レポートは Windows へ持ち帰り、ランチャーまたはブラウザで開いてください。"
    fi
  fi
}

execute_tool() {
  # tool-id, entry, tool_dir, run_dir, live(yes/no) -> rc
  local id="$1" entry="$2" tool_dir="$3" run_dir="$4" live="$5"
  local rc
  local -a envkv=()
  [ -n "$DEFAULT_AWS_PROFILE" ] && envkv+=("AWS_PROFILE=$DEFAULT_AWS_PROFILE")
  for e in ${ENVS[@]+"${ENVS[@]}"}; do envkv+=("$e"); done

  if [ "$live" = "yes" ]; then
    # ライブ表示 + ログ保存(stderr は画面では黄色にせずそのまま)
    ( cd "$tool_dir" && env ${envkv[@]+"${envkv[@]}"} bash "$entry" ${ARGS[@]+"${ARGS[@]}"} ) \
      2> >(tee "${run_dir}/stderr.log" >&2) | tee "${run_dir}/stdout.log"
    rc=${PIPESTATUS[0]}
    # プロセス置換(tee) の書き込み完了を待つ
    wait 2>/dev/null || true
  else
    ( cd "$tool_dir" && env ${envkv[@]+"${envkv[@]}"} bash "$entry" ${ARGS[@]+"${ARGS[@]}"} ) \
      > "${run_dir}/stdout.log" 2> "${run_dir}/stderr.log"
    rc=$?
  fi
  printf '%s\n' "$rc" > "${run_dir}/exit-code.txt"
  LAST_RUN_DIR="$run_dir"
  save_config
  return "$rc"
}

# ── Interactive: run a selected tool ─────────────────────────────────────────
show_values_table() {
  # 現在の VAL を一覧表示
  local i shown=0
  for i in "${!P_KEY[@]}"; do
    [ "${P_TYPE[$i]}" = "hidden" ] && continue
    [ "$shown" -eq 0 ] && info "パラメーター(既定値。e で編集):"
    shown=1
    local key="${P_KEY[$i]}" disp
    if [ "${P_TYPE[$i]}" = "checkbox" ]; then
      if [ "${VAL[$key]:-false}" = "true" ]; then disp="y"; else disp="n"; fi
    else
      disp="${VAL[$key]:-}"
    fi
    printf '  %-18s : %s\n' "${P_LABEL[$i]}" "$disp"
  done
  # envVar/argName ルートの設定ファイルも表示
  for i in "${!CF_LABEL[@]}"; do
    [ -z "${CF_PK[$i]}" ] || continue
    printf '  %-18s : %s\n' "${CF_LABEL[$i]}" "$(cfg_effective_path "$CURRENT_TOOL_ID" "${CF_LABEL[$i]}" "${CF_PATH[$i]}")"
  done
}

edit_values() {
  # tool-id: per-parameter プロンプトで VAL / CFG_OVERRIDE を更新
  local id="$1"
  local i
  # 設定ファイル(envVar/argName ルート)
  for i in "${!CF_LABEL[@]}"; do
    [ -z "${CF_PK[$i]}" ] || continue
    local eff val
    eff=$(cfg_effective_path "$id" "${CF_LABEL[$i]}" "${CF_PATH[$i]}")
    val=$(read_value "  ${CF_LABEL[$i]}" "$eff")
    if [ "$val" != "$(cfg_default_path "${CF_PATH[$i]}")" ]; then
      CFG_OVERRIDE["$id::${CF_LABEL[$i]}"]="$val"
    else
      unset "CFG_OVERRIDE[$id::${CF_LABEL[$i]}]" 2>/dev/null || true
    fi
    save_config
  done
  # parameters
  for i in "${!P_KEY[@]}"; do
    local key="${P_KEY[$i]}" type="${P_TYPE[$i]}" label="${P_LABEL[$i]}"
    [ "$type" = "hidden" ] && continue
    if [ "$type" = "checkbox" ]; then
      local dflt="n"; [ "${VAL[$key]:-false}" = "true" ] && dflt="y"
      local ans; ans=$(read_value "  ${label}? (y/n)" "$dflt")
      case "$ans" in
        y|Y|yes|YES) VAL["$key"]="true" ;;
        *) VAL["$key"]="false" ;;
      esac
      continue
    fi
    local v; v=$(read_value "  ${label}" "${VAL[$key]:-}")
    VAL["$key"]="$v"
    # paramKey ルートの設定ファイルは override も更新
    if [ -n "${PK_TO_CFG[$key]:-}" ]; then
      local ci="${PK_TO_CFG[$key]}"
      if [ "$v" != "$(cfg_default_path "${CF_PATH[$ci]}")" ]; then
        CFG_OVERRIDE["$id::${CF_LABEL[$ci]}"]="$v"
      else
        unset "CFG_OVERRIDE[$id::${CF_LABEL[$ci]}]" 2>/dev/null || true
      fi
      save_config
    fi
  done
}

CURRENT_TOOL_ID=""
run_tool_interactive() {
  local id="$1" lin="$2"
  CURRENT_TOOL_ID="$id"
  local tool_dir="${TOOLS_ROOT}/$(dirname "$lin")"
  local entry="${TOOLS_ROOT}/${lin}"
  if [ ! -f "$entry" ]; then err "エントリが見つかりません: $entry"; return; fi

  load_tool_defs "$id"
  local stamp run_dir
  stamp=$(date '+%Y%m%d-%H%M%S')
  run_dir="${OUTPUT_ROOT}/${id}/${stamp}"
  init_values "$id" "$tool_dir" "$run_dir"

  while true; do
    say ""
    title "▶ ${TOOL_NAME[$id]:-$id}  ($id)"
    [ -n "${TOOL_DESC[$id]:-}" ] && info "${TOOL_DESC[$id]}"
    hr
    show_values_table
    build_args "$id" "$tool_dir" "$run_dir"
    say ""
    info "コマンドプレビュー:"
    printf '%s%s%s\n' "$C_CYAN" "$(build_preview "$entry")" "$C_RESET"
    say ""
    printf '%sEnter) この内容で実行   e) 編集   n) 中止%s : ' "$C_BOLD" "$C_RESET"
    local go; read -r go || go="n"
    case "$go" in
      '' ) ;;
      e|E) edit_values "$id"; continue ;;
      *  ) warn "中止しました。"; return ;;
    esac

    # 必須チェック
    local missing
    missing=$(missing_required)
    if [ -n "$missing" ]; then
      err "必須パラメーターが未入力です:"
      printf '%s\n' "$missing" | sed 's/^/    /'
      continue
    fi
    break
  done

  mkdir -p "${run_dir}/artifacts"
  build_args "$id" "$tool_dir" "$run_dir"
  build_preview "$entry" > "${run_dir}/command.txt"
  printf '\n' >> "${run_dir}/command.txt"

  say ""
  info "実行中... (Ctrl-C で中断。出力はライブ表示され ${run_dir} に保存されます)"
  hr
  local rc=0
  execute_tool "$id" "$entry" "$tool_dir" "$run_dir" "yes" || rc=$?
  hr
  print_result "$rc" "$run_dir"

  say ""
  local arch; arch=$(read_value "この run を tar.gz にまとめますか? (Windows へ転送用) (y/n)" "n")
  case "$arch" in
    y|Y|yes|YES) archive_run_dir "$run_dir" ;;
  esac
}

archive_run_dir() {
  # run_dir -> tar.gz を作成しパスを stdout へ
  local run_dir="$1"
  if [ -z "$run_dir" ] || [ ! -d "$run_dir" ]; then
    err "run ディレクトリがありません: ${run_dir:-（未実行）}"
    return 1
  fi
  local parent stamp id_dir tgz
  stamp=$(basename "$run_dir")
  parent=$(dirname "$run_dir")
  id_dir=$(basename "$parent")
  tgz="${OUTPUT_ROOT}/${id_dir}_${stamp}.tar.gz"
  if tar -czf "$tgz" -C "$parent" "$stamp" 2>/dev/null; then
    ok "作成: $tgz"
    printf '%s\n' "$tgz"
    return 0
  fi
  err "tar.gz の作成に失敗しました。"
  return 1
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
  DEFAULT_AWS_PROFILE=$(choose_aws_profile "$DEFAULT_AWS_PROFILE")
  save_config
  ok "保存しました: $CONFIG_PATH"
}

# ── Main menu ─────────────────────────────────────────────────────────────────
main_menu() {
  build_menu
  local i choice
  while true; do
    say ""
    title "==== Local Tools Launcher (Linux) v2 ===="
    info "ToolsRoot : $TOOLS_ROOT"
    info "OutputRoot: $OUTPUT_ROOT"
    [ -n "$DEFAULT_AWS_PROFILE" ] && info "AWS Profile: $DEFAULT_AWS_PROFILE"
    say ""
    printf '%s c)%s %sスナップショット一括収集%s  %s(ZIP を作成し Windows でレポート化)%s\n' \
      "$C_BOLD$C_MAGENTA" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_DIM" "$C_RESET"
    say ""
    info "ツール個別実行:"
    for i in "${!MENU_IDS[@]}"; do
      printf '%s%2d)%s %-20s %s%s%s\n' \
        "$C_BOLD$C_GREEN" "$((i+1))" "$C_RESET" "${MENU_IDS[$i]}" "$C_BOLD" "${MENU_NAMES[$i]}" "$C_RESET"
      printf '     %s%s%s\n' "$C_DIM" "${MENU_DESCS[$i]}" "$C_RESET"
    done
    say ""
    printf '  %sa)%s 直近 run を tar.gz 化   %ss)%s 設定   %sq)%s 終了\n' \
      "$C_YELLOW" "$C_RESET" "$C_YELLOW" "$C_RESET" "$C_YELLOW" "$C_RESET"
    printf '%s選択:%s ' "$C_BOLD" "$C_RESET"
    read -r choice || break
    case "$choice" in
      q|Q) break ;;
      c|C) run_collect_snapshot ;;
      s|S) settings_menu ;;
      a|A) archive_run_dir "$LAST_RUN_DIR" >/dev/null || true ;;
      ''|*[!0-9]*) err "無効な選択です。" ;;
      *)
        local idx=$((choice-1))
        if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#MENU_IDS[@]}" ]; then
          run_tool_interactive "${MENU_IDS[$idx]}" "${MENU_LINS[$idx]}"
        else
          err "無効な選択です。"
        fi
        ;;
    esac
  done
}

# ── Non-interactive subcommands ──────────────────────────────────────────────
cmd_list() {
  build_menu
  local i
  for i in "${!MENU_IDS[@]}"; do
    printf '%s\t%s\t%s\n' "${MENU_IDS[$i]}" "${MENU_NAMES[$i]}" "${MENU_DESCS[$i]}"
  done
}

cmd_run() {
  # run <tool-id> [--set key=value ...] [--dry-run]
  local id="${1:-}"
  if [ -z "$id" ]; then note "usage: $0 run <tool-id> [--set key=value ...] [--dry-run]"; return 2; fi
  shift
  local dry="no"
  local -a sets=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry="yes"; shift ;;
      --set)
        if [ -z "${2:-}" ]; then note "[FAIL] --set には key=value を指定してください"; return 2; fi
        sets+=("$2"); shift 2 ;;
      *) note "[FAIL] 不明なオプション: $1"; return 2 ;;
    esac
  done

  build_menu
  local lin="${TOOL_LIN[$id]:-}"
  if [ -z "${TOOL_NAME[$id]:-}" ]; then note "[FAIL] 不明なツール ID: $id($0 list で確認できます)"; return 2; fi
  if [ -z "$lin" ]; then note "[FAIL] $id は Linux 用エントリ (linuxPath) がありません"; return 2; fi

  local tool_dir="${TOOLS_ROOT}/$(dirname "$lin")"
  local entry="${TOOLS_ROOT}/${lin}"
  if [ ! -f "$entry" ]; then note "[FAIL] エントリが見つかりません: $entry"; return 2; fi

  load_tool_defs "$id"
  local stamp run_dir
  stamp=$(date '+%Y%m%d-%H%M%S')
  run_dir="${OUTPUT_ROOT}/${id}/${stamp}"
  init_values "$id" "$tool_dir" "$run_dir"

  # --set の適用(key の存在チェック付き)
  local kv key val found i
  for kv in ${sets[@]+"${sets[@]}"}; do
    key="${kv%%=*}"; val="${kv#*=}"
    if [ "$key" = "$kv" ]; then note "[FAIL] --set は key=value 形式で指定してください: $kv"; return 2; fi
    found="no"
    for i in "${!P_KEY[@]}"; do
      [ "${P_KEY[$i]}" = "$key" ] || continue
      [ "${P_TYPE[$i]}" = "hidden" ] && continue
      found="yes"
      if [ "${P_TYPE[$i]}" = "checkbox" ]; then
        case "$val" in
          true|y|Y|yes|1) VAL["$key"]="true" ;;
          *) VAL["$key"]="false" ;;
        esac
      else
        VAL["$key"]="$val"
      fi
      break
    done
    if [ "$found" = "no" ]; then
      note "[FAIL] 不明なパラメーターキー: $key(有効: $(printf '%s ' "${P_KEY[@]}"))"
      return 2
    fi
  done

  local missing
  missing=$(missing_required)
  if [ -n "$missing" ]; then
    note "[FAIL] 必須パラメーターが未入力です: $(printf '%s ' $missing)"
    return 2
  fi

  build_args "$id" "$tool_dir" "$run_dir"
  if [ "$dry" = "yes" ]; then
    # dry-run: 実行せずプレビューを stdout へ(実行はしないので run_dir も作らない)
    build_preview "$entry"
    printf '\n'
    return 0
  fi

  mkdir -p "${run_dir}/artifacts"
  build_preview "$entry" > "${run_dir}/command.txt"
  printf '\n' >> "${run_dir}/command.txt"
  note "実行中: ${TOOL_NAME[$id]} ($id) -> $run_dir"
  local rc=0
  execute_tool "$id" "$entry" "$tool_dir" "$run_dir" "no" || rc=$?
  if [ "$rc" -eq 0 ]; then note "[ok] 完了 (exit=0)"
  elif [ "$rc" -eq 1 ]; then note "[warn] 終了 (exit=1) NG 検出またはエラー"
  else note "[FAIL] 失敗 (exit=$rc)"; fi
  # stdout はデータ専用: run ディレクトリを出力
  printf '%s\n' "$run_dir"
  return "$rc"
}

cmd_archive() {
  # archive [<tool-id>]: 指定 ID の最新 run(省略時は直近 run)を tar.gz 化
  local id="${1:-}"
  local target="$LAST_RUN_DIR"
  if [ -n "$id" ]; then
    target=$(find "${OUTPUT_ROOT}/${id}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -n 1)
  fi
  archive_run_dir "$target"
}

usage() {
  cat <<EOF
Local Tools Launcher (Linux) v2

usage:
  $(basename "$0")                  対話メニューを開く
  $(basename "$0") list             ツール一覧 (TSV: id, name, description)
  $(basename "$0") run <tool-id> [--set key=value ...] [--dry-run]
                                    既定値でツールを実行(--set で上書き)
  $(basename "$0") archive [<id>]   直近 run(または指定ツールの最新 run)を tar.gz 化
  $(basename "$0") help             このヘルプ

exit code: run はツールの exit code を透過する(0=OK, 1=NG 検出またはエラー, 2+=失敗)
EOF
}

# ── Entry ─────────────────────────────────────────────────────────────────────
if [ ! -f "$CATALOG_PATH" ]; then err "カタログが見つかりません: $CATALOG_PATH"; exit 1; fi

case "${1:-}" in
  list)    shift; load_config; cmd_list "$@" ;;
  run)     shift; load_config; mkdir -p "$OUTPUT_ROOT"; cmd_run "$@" ;;
  archive) shift; load_config; mkdir -p "$OUTPUT_ROOT"; cmd_archive "$@" ;;
  help|-h|--help) usage ;;
  '')      load_config; mkdir -p "$OUTPUT_ROOT"; main_menu ;;
  *)       err "不明なサブコマンド: $1"; usage >&2; exit 2 ;;
esac
