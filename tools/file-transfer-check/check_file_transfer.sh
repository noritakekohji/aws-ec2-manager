#!/usr/bin/env bash
set -u

LIST="$(cd "$(dirname "$0")" && pwd)/shares.lst"
SIZE_MB=10
TIMEOUT_SEC=60
HTML=""
FAIL_ONLY=0

while getopts "l:s:t:o:fh" opt; do
  case "$opt" in
    l) LIST="$OPTARG" ;;
    s) SIZE_MB="$OPTARG" ;;
    t) TIMEOUT_SEC="$OPTARG" ;;
    o) HTML="$OPTARG" ;;
    f) FAIL_ONLY=1 ;;
    h) echo "Usage: $0 [-l list] [-s sizeMB] [-t timeoutSec] [-o html] [-f]"; exit 0 ;;
    *) echo "Unknown option"; exit 2 ;;
  esac
done

command -v smbclient >/dev/null 2>&1 || { echo "[ERROR] smbclient が見つかりません"; exit 10; }
command -v sha256sum >/dev/null 2>&1 || { echo "[ERROR] sha256sum が見つかりません"; exit 10; }
command -v dd >/dev/null 2>&1 || { echo "[ERROR] dd が見つかりません"; exit 10; }
[ -f "$LIST" ] || { echo "[ERROR] 共有リストが見つかりません: $LIST"; exit 2; }

declare -A CRED_CACHE
OK=0; NG=0; WARN=0
ROWS=""
CURRENT_AUTHFILE=""
trap 'rm -f "${CURRENT_AUTHFILE:-}" 2>/dev/null' EXIT INT TERM

# UNC(\\srv\share\sub or //srv/share/sub) -> service + relpath
normalize_share() {
  local s="${1//\\//}"          # backslash -> slash
  s="${s#//}"                   # strip leading //
  local host="${s%%/*}"; s="${s#*/}"
  local share="${s%%/*}"
  local rel=""
  if [ "$s" != "$share" ]; then rel="${s#*/}"; fi
  echo "//${host}/${share}|${rel}"
}

html_escape() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

get_password() {
  local user="$1"
  if [ -n "${CRED_CACHE[$user]:-}" ]; then printf '%s' "${CRED_CACHE[$user]}"; return; fi
  local pw
  read -r -s -p "パスワードを入力してください ($user): " pw </dev/tty; echo >&2
  CRED_CACHE[$user]="$pw"
  printf '%s' "$pw"
}

run_share() {
  local share="$1" user="$2" expected="$3" desc="$4"
  local parsed service rel
  parsed="$(normalize_share "$share")"
  service="${parsed%|*}"; rel="${parsed#*|}"

  local tmp_src tmp_dst authfile
  tmp_src="$(mktemp)"; tmp_dst="$(mktemp)"
  dd if=/dev/urandom of="$tmp_src" bs=1M count="$SIZE_MB" status=none
  local srch; srch="$(sha256sum "$tmp_src" | awk '{print $1}')"
  local remote="conntest_$(date +%Y%m%d-%H%M%S)_$RANDOM.tmp"

  local auth_args=()
  if [ -z "$user" ]; then
    if klist -s 2>/dev/null; then
      auth_args=(-k)
    else
      rm -f "$tmp_src" "$tmp_dst"
      echo "[SHARE] $share  ($desc)"
      echo "  Result  : WARN  Linux では username 指定が必要 (統合認証不可)"
      echo ""
      WARN=$((WARN+1))
      ROWS="${ROWS}<tr class='warn'><td>$(html_escape "$share")</td><td>$(html_escape "$desc")</td><td></td><td>-</td><td>-</td><td>-</td><td>WARN</td><td>username 必要</td></tr>"
      return
    fi
  else
    local pw; pw="$(get_password "$user")"
    authfile="$(mktemp)"; chmod 600 "$authfile"
    CURRENT_AUTHFILE="$authfile"
    printf 'username=%s\npassword=%s\n' "$user" "$pw" > "$authfile"
    auth_args=(-A "$authfile")
  fi

  local cdcmd=""
  [ -n "$rel" ] && cdcmd="cd \"$rel\"; "

  # Upload
  local up_start up_end up_sec up_ok=0 dn_ok=0 vf_ok=0 msg=""
  up_start="$(date +%s.%N)"
  if timeout "$TIMEOUT_SEC" smbclient "$service" "${auth_args[@]}" \
       -c "${cdcmd}put \"$tmp_src\" \"$remote\"" >/dev/null 2>&1; then
    up_ok=1
  else
    msg="アップロード失敗"
  fi
  up_end="$(date +%s.%N)"
  up_sec="$(awk "BEGIN{print $up_end-$up_start}")"

  # Download
  local dn_start dn_end dn_sec
  dn_start="$(date +%s.%N)"
  if [ "$up_ok" -eq 1 ] && timeout "$TIMEOUT_SEC" smbclient "$service" "${auth_args[@]}" \
       -c "${cdcmd}get \"$remote\" \"$tmp_dst\"" >/dev/null 2>&1; then
    dn_ok=1
  elif [ "$up_ok" -eq 1 ]; then
    msg="ダウンロード失敗"
  fi
  dn_end="$(date +%s.%N)"
  dn_sec="$(awk "BEGIN{print $dn_end-$dn_start}")"

  # Verify
  if [ "$dn_ok" -eq 1 ]; then
    local dsth; dsth="$(sha256sum "$tmp_dst" | awk '{print $1}')"
    if [ "$srch" = "$dsth" ]; then vf_ok=1; else msg="ハッシュ不一致"; fi
  fi

  # Cleanup remote
  local cleanup_warn=0
  timeout "$TIMEOUT_SEC" smbclient "$service" "${auth_args[@]}" \
      -c "${cdcmd}del \"$remote\"" >/dev/null 2>&1 || cleanup_warn=1

  [ -n "${authfile:-}" ] && rm -f "$authfile"
  CURRENT_AUTHFILE=""
  rm -f "$tmp_src" "$tmp_dst"

  # Evaluate
  local success=0
  [ "$up_ok" -eq 1 ] && [ "$dn_ok" -eq 1 ] && [ "$vf_ok" -eq 1 ] && success=1
  local verdict
  case "$expected" in
    ok) [ "$success" -eq 1 ] && verdict="OK" || verdict="NG" ;;
    ng) [ "$success" -eq 1 ] && verdict="NG" || verdict="OK" ;;
    *)  [ "$success" -eq 1 ] && verdict="OK" || verdict="WARN" ;;
  esac
  [ "$cleanup_warn" -eq 1 ] && [ "$verdict" = "OK" ] && verdict="WARN"

  local up_mbps="0" dn_mbps="0"
  [ "$up_ok" -eq 1 ] && up_mbps="$(awk "BEGIN{if($up_sec>0)printf \"%.2f\", $SIZE_MB/$up_sec; else print 0}")"
  [ "$dn_ok" -eq 1 ] && dn_mbps="$(awk "BEGIN{if($dn_sec>0)printf \"%.2f\", $SIZE_MB/$dn_sec; else print 0}")"

  case "$verdict" in OK) OK=$((OK+1));; NG) NG=$((NG+1));; WARN) WARN=$((WARN+1));; esac

  if [ "$FAIL_ONLY" -eq 0 ] || [ "$verdict" != "OK" ]; then
    echo "[SHARE] $share  ($desc)"
    echo "  Auth    : ${user:-integrated}"
    [ "$up_ok" -eq 1 ] && echo "  Upload  : OK   ${up_mbps} MB/s" || echo "  Upload  : NG   $msg"
    [ "$dn_ok" -eq 1 ] && echo "  Download: OK   ${dn_mbps} MB/s"
    [ "$up_ok" -eq 1 ] && [ "$dn_ok" -eq 1 ] && { [ "$vf_ok" -eq 1 ] && echo "  Verify  : OK   (SHA-256 一致)" || echo "  Verify  : NG   (SHA-256 不一致)"; }
    [ "$cleanup_warn" -eq 1 ] && echo "  Cleanup : WARN 削除失敗"
    echo "  Result  : $verdict   expected=$expected"
    echo ""
  fi

  local cls="warn"; [ "$verdict" = "OK" ] && cls="ok"; [ "$verdict" = "NG" ] && cls="ng"
  local verify_cell="-"
  if [ "$up_ok" -eq 1 ] && [ "$dn_ok" -eq 1 ]; then
    if [ "$vf_ok" -eq 1 ]; then verify_cell="OK"; else verify_cell="NG"; fi
  fi
  ROWS="${ROWS}<tr class='${cls}'><td>$(html_escape "$share")</td><td>$(html_escape "$desc")</td><td>$(html_escape "$user")</td><td>${up_mbps}</td><td>${dn_mbps}</td><td>${verify_cell}</td><td>${verdict}</td><td>$(html_escape "$msg")</td></tr>"
}

# Parse list and iterate
while IFS= read -r raw || [ -n "$raw" ]; do
  line="${raw%%#*}"
  line="$(echo "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [ -z "$line" ] && continue
  IFS=',' read -r f_share f_user f_exp f_desc <<< "$line"
  f_share="$(echo "$f_share" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  f_user="$(echo "${f_user:-}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  f_exp="$(echo "${f_exp:--}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | tr 'A-Z' 'a-z')"
  case "$f_exp" in ok|ng|-) : ;; *) f_exp="-" ;; esac
  f_desc="$(echo "${f_desc:-}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [ -z "$f_desc" ] && f_desc="$f_share"
  [ -z "$f_share" ] && continue
  run_share "$f_share" "$f_user" "$f_exp" "$f_desc"
done < "$LIST"

echo "--------------------------------------------------"
TOTAL=$((OK+NG+WARN))
echo "  Shares: $TOTAL   OK: $OK   NG: $NG   Warning: $WARN"

if [ -n "$HTML" ]; then
  {
    echo "<!DOCTYPE html><html lang='ja'><head><meta charset='utf-8'><title>File Transfer Check</title>"
    echo "<style>body{font-family:sans-serif;margin:20px}table{border-collapse:collapse;width:100%}th,td{border:1px solid #ccc;padding:6px 10px}th{background:#f0f0f0}tr.ng{background:#fdecec}tr.warn{background:#fff7e0}</style></head><body>"
    echo "<h1>File Transfer Check</h1><p>生成: $(date '+%Y-%m-%d %H:%M:%S') / テストサイズ: ${SIZE_MB} MB</p>"
    echo "<table><thead><tr><th>共有</th><th>説明</th><th>ユーザー</th><th>上り MB/s</th><th>下り MB/s</th><th>整合性</th><th>判定</th><th>備考</th></tr></thead><tbody>"
    echo "$ROWS"
    echo "</tbody></table></body></html>"
  } > "$HTML"
  echo "  HTML: $HTML"
fi

if [ $((NG+WARN)) -gt 0 ]; then exit 1; else exit 0; fi
