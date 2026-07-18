#!/usr/bin/env bash
# ============================================================================
# linux-launcher-smoke.sh - local-tools-launcher.sh v2 の smoke テスト
#
# 実行方法: bash tests/linux-launcher-smoke.sh
# 依存: bash 4+, awk, tar(ランチャー本体と同じ)。ツールは実行しない
# (--dry-run と list、および対話メニューの描画のみを検証する)。
# ============================================================================
set -u

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LAUNCHER="${REPO_ROOT}/local-tools-launcher.sh"

PASS=0
FAIL=0

# テスト用の設定を隔離(XDG_CONFIG_HOME を一時領域へ)
TMP_HOME=$(mktemp -d)
trap 'rm -rf "$TMP_HOME"' EXIT
export XDG_CONFIG_HOME="$TMP_HOME/config"
export NO_COLOR=1
mkdir -p "$XDG_CONFIG_HOME/aws-ec2-manager"
cat > "$XDG_CONFIG_HOME/aws-ec2-manager/local-tools-launcher.conf" <<EOF
TOOLS_ROOT='${REPO_ROOT}/tools'
OUTPUT_ROOT='${TMP_HOME}/reports'
DEFAULT_AWS_PROFILE=''
LAST_RUN_DIR=''
EOF

assert() {
  # name, condition(0=ok)
  local name="$1" rc="$2"
  if [ "$rc" -eq 0 ]; then
    printf '[ok]   %s\n' "$name"
    PASS=$((PASS+1))
  else
    printf '[FAIL] %s\n' "$name"
    FAIL=$((FAIL+1))
  fi
}

# ── 1) help / 不明サブコマンド ───────────────────────────────────────────────
bash "$LAUNCHER" help > /dev/null 2>&1
assert "help が exit 0" $?

bash "$LAUNCHER" no-such-subcommand > /dev/null 2>&1
[ $? -eq 2 ]; assert "不明サブコマンドは exit 2" $?

# ── 2) list ──────────────────────────────────────────────────────────────────
LIST_OUT=$(bash "$LAUNCHER" list 2>/dev/null)
assert "list が exit 0" $?

LIST_COUNT=$(printf '%s\n' "$LIST_OUT" | grep -c .)
[ "$LIST_COUNT" -ge 5 ]; assert "list が 5 ツール以上を返す (実際: $LIST_COUNT)" $?

printf '%s\n' "$LIST_OUT" | awk -F'\t' 'NF != 3 { exit 1 }'
assert "list が 3 列 TSV" $?

# ── 3) run --dry-run(全ツール) ─────────────────────────────────────────────
while IFS=$'\t' read -r id name desc; do
  [ -n "$id" ] || continue
  PREVIEW=$(bash "$LAUNCHER" run "$id" --dry-run 2>/dev/null)
  rc=$?
  assert "run $id --dry-run が exit 0" "$rc"
  printf '%s' "$PREVIEW" | grep -q "bash "
  assert "run $id --dry-run が bash コマンドを出力" $?
  # テンプレート変数が未展開のまま残っていないこと
  if printf '%s' "$PREVIEW" | grep -qE '\{(ToolDir|RunDir|ArtifactsDir|AwsProfile)\}'; then
    assert "run $id --dry-run にテンプレート残骸なし" 1
  else
    assert "run $id --dry-run にテンプレート残骸なし" 0
  fi
done <<EOF_LIST
$LIST_OUT
EOF_LIST

# ── 4) linuxArgument が使われること(PS 形式引数が混入しない) ────────────────
PREVIEW=$(bash "$LAUNCHER" run cert-check --dry-run 2>/dev/null)
printf '%s' "$PREVIEW" | grep -q -- '--target-list'
assert "cert-check: linuxArgument (--target-list) を使用" $?
printf '%s' "$PREVIEW" | grep -q -- '-TargetList'
[ $? -ne 0 ]; assert "cert-check: PS 形式 (-TargetList) が混入しない" $?

PREVIEW=$(bash "$LAUNCHER" run network-check --dry-run 2>/dev/null)
printf '%s' "$PREVIEW" | grep -qE ' -l '
assert "network-check: linuxArgument (-l) を使用" $?

# ── 5) --set 上書き / 不正キー ───────────────────────────────────────────────
PREVIEW=$(bash "$LAUNCHER" run cert-check --dry-run --set timeoutSec=5 2>/dev/null)
printf '%s' "$PREVIEW" | grep -q -- '--timeout 5'
assert "--set timeoutSec=5 が --timeout 5 に反映" $?

PREVIEW=$(bash "$LAUNCHER" run cert-check --dry-run --set failOnly=true 2>/dev/null)
printf '%s' "$PREVIEW" | grep -q -- '--fail-only'
assert "--set failOnly=true が --fail-only に反映" $?

bash "$LAUNCHER" run cert-check --dry-run --set nosuchkey=1 > /dev/null 2>&1
[ $? -eq 2 ]; assert "不明な --set キーは exit 2" $?

bash "$LAUNCHER" run no-such-tool --dry-run > /dev/null 2>&1
[ $? -eq 2 ]; assert "不明ツール ID は exit 2" $?

# ── 6) 必須パラメーター(collect-snapshot-report は linuxPath 無し) ──────────
bash "$LAUNCHER" run collect-snapshot-report --dry-run > /dev/null 2>&1
[ $? -eq 2 ]; assert "linuxPath 無しツールは exit 2" $?

# ── 7) 対話メニューの描画(選択せず終了) ────────────────────────────────────
MENU_OUT=$(printf 'q\n' | bash "$LAUNCHER" 2>&1)
assert "対話メニューが q で正常終了" $?
printf '%s' "$MENU_OUT" | grep -q "ツール個別実行"
assert "メニューにツール一覧見出しが出る" $?
printf '%s' "$MENU_OUT" | grep -q "cert-check"
assert "メニューに cert-check が出る" $?

# ── 8) 対話フロー: ツール選択 → 中止 ────────────────────────────────────────
FLOW_OUT=$(printf '1\nn\nq\n' | bash "$LAUNCHER" 2>&1)
assert "ツール選択→中止→終了が正常" $?
printf '%s' "$FLOW_OUT" | grep -q "コマンドプレビュー"
assert "選択後にコマンドプレビューが表示される" $?
printf '%s' "$FLOW_OUT" | grep -q "中止しました"
assert "n で中止できる" $?

# ── 9) 実実行(無害なダミーツールを一時カタログで実行) ───────────────────────
FAKE_ROOT="$TMP_HOME/faketools"
mkdir -p "$FAKE_ROOT/hello"
cat > "$FAKE_ROOT/hello/hello.sh" <<'EOF_TOOL'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out) out="$2"; shift 2 ;;
    --warn) echo "NG found" ; exit 1 ;;
    *) shift ;;
  esac
done
echo "hello stdout"
echo "hello stderr" >&2
if [ -n "$out" ]; then mkdir -p "$(dirname "$out")"; echo "<html>ok</html>" > "$out"; fi
exit 0
EOF_TOOL
cat > "$FAKE_ROOT/tool-catalog.yaml" <<'EOF_CAT'
tools:
  - id: hello
    name: Hello
    description: smoke 用ダミー
    menu: true
    windowsPath: hello/hello.ps1
    linuxPath: hello/hello.sh
    parameters:
      - key: outFile
        label: 出力
        type: hidden
        argument: -Out
        linuxArgument: --out
        value: "{ArtifactsDir}/hello.html"
      - key: warn
        label: warn にする
        type: checkbox
        argument: -Warn
        linuxArgument: --warn
        default: false
EOF_CAT
mkdir -p "$XDG_CONFIG_HOME/aws-ec2-manager"
cat > "$XDG_CONFIG_HOME/aws-ec2-manager/local-tools-launcher.conf" <<EOF
TOOLS_ROOT='${FAKE_ROOT}'
OUTPUT_ROOT='${TMP_HOME}/reports'
DEFAULT_AWS_PROFILE=''
LAST_RUN_DIR=''
EOF
# ランチャーはカタログを SCRIPT_DIR/tools 固定で読むため、リポジトリ一式を模した
# 一時ディレクトリにランチャーをコピーして実行する
FAKE_REPO="$TMP_HOME/fakerepo"
mkdir -p "$FAKE_REPO"
cp "$LAUNCHER" "$FAKE_REPO/local-tools-launcher.sh"
cp -r "$FAKE_ROOT" "$FAKE_REPO/tools"

RUN_OUT=$(bash "$FAKE_REPO/local-tools-launcher.sh" run hello 2>/dev/null)
rc=$?
assert "ダミーツール実行が exit 0" "$rc"
RUN_DIR="$RUN_OUT"
[ -d "$RUN_DIR" ]; assert "run が run ディレクトリを stdout に出力" $?
[ -f "$RUN_DIR/exit-code.txt" ] && [ "$(cat "$RUN_DIR/exit-code.txt")" = "0" ]
assert "exit-code.txt が 0" $?
grep -q "hello stdout" "$RUN_DIR/stdout.log" 2>/dev/null
assert "stdout.log に出力が保存される" $?
[ -f "$RUN_DIR/artifacts/hello.html" ]
assert "artifacts に成果物が生成される" $?

bash "$FAKE_REPO/local-tools-launcher.sh" run hello --set warn=true > /dev/null 2>&1
[ $? -eq 1 ]; assert "NG 検出 (exit 1) が透過される" $?

TGZ_OUT=$(bash "$FAKE_REPO/local-tools-launcher.sh" archive hello 2>/dev/null | tail -n 1)
rc=$?
assert "archive が exit 0" "$rc"
[ -f "$TGZ_OUT" ]; assert "archive が tar.gz を作成しパスを出力" $?

# ── 結果 ─────────────────────────────────────────────────────────────────────
echo ""
echo "==== smoke result: pass=$PASS fail=$FAIL ===="
[ "$FAIL" -eq 0 ]
