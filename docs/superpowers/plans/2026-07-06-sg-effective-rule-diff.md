# SG 実効ルール差分 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** SG の付け外しを、instance として実際に増減する「実効ルール（Direction/Protocol/Port/Target）」のネット差分として提示する。

**Architecture:** 差分計算のコアを純粋関数 `Get-SgRuleDiff` として `AwsManager.psm1` に切り出し Pester でテストする。App.ps1 の `Get-SgDiffData` が既存の `Get-SgRuleRowsForItems` で before/after のルール行を作り、この関数に渡して `AddedRules`/`RemovedRules` を得る。画面パネル・テキスト・HTML の 3 出力に実効ルール差分セクションを追加する。

**Tech Stack:** PowerShell 5.1（互換必須。`??`/`?:`/`?.` 禁止）、WPF、Pester 5、PSScriptAnalyzer。

**エンコーディング注意:** `.ps1`/`.psm1` は **UTF-8 BOM 付き**。既存ファイルは Edit で部分修正し BOM を保持する（全書き換えで BOM を落とさない）。

---

## File Structure

- `AwsManager.psm1`（Modify）: 純粋関数 `Get-SgRuleDiff` と private ヘルパー `Get-SgRuleContentKey` / `Get-SgNetRuleList` を追加。`Export-ModuleMember` に `Get-SgRuleDiff` を追記。
- `tests/AwsManager.Tests.ps1`（Modify）: `Get-SgRuleDiff` の Context を追加。
- `App.ps1`（Modify）:
  - `Get-SgDiffData`: `AddedRules`/`RemovedRules` を出力に追加。
  - `Format-SgNetRuleLine`（新規、整形ヘルパー）。
  - `Render-SgDiffPanel`: 先頭に実効ルール差分セクション。
  - `Format-SgDiffText`: 実効ルール差分セクション。
  - `New-SgReportHtml`: 実効ルール差分パネル。
- `CHANGELOG.md`（Modify）: `[Unreleased]` に追記。

---

### Task 1: 純粋関数 `Get-SgRuleDiff`（module + テスト）

**Files:**
- Modify: `AwsManager.psm1`（`Export-ModuleMember`(674行) の直前に関数追加、674行に追記）
- Test: `tests/AwsManager.Tests.ps1`

- [ ] **Step 1: 失敗するテストを書く**

`tests/AwsManager.Tests.ps1` の `AfterAll { ... }`（10-11行）ブロックの後、最初の `Context`（13行）の前に以下の Context を挿入する。

```powershell
    Context 'Get-SgRuleDiff' {
        It 'reports rules present only in the after set as Added' {
            $before = @(
                [PSCustomObject]@{ Direction = 'Inbound'; Protocol = 'tcp'; Port = '22'; Target = '10.0.0.0/8'; Description = 'ssh'; SecurityGroup = 'base (sg-1)' }
            )
            $after = @(
                [PSCustomObject]@{ Direction = 'Inbound'; Protocol = 'tcp'; Port = '22'; Target = '10.0.0.0/8'; Description = 'ssh'; SecurityGroup = 'base (sg-1)' },
                [PSCustomObject]@{ Direction = 'Inbound'; Protocol = 'tcp'; Port = '443'; Target = '0.0.0.0/0'; Description = 'https'; SecurityGroup = 'web (sg-2)' }
            )
            $diff = Get-SgRuleDiff -BeforeRules $before -AfterRules $after
            @($diff.Added).Count | Should -Be 1
            $diff.Added[0].Port | Should -Be '443'
            @($diff.Removed).Count | Should -Be 0
        }

        It 'reports rules present only in the before set as Removed' {
            $before = @(
                [PSCustomObject]@{ Direction = 'Inbound'; Protocol = 'tcp'; Port = '3389'; Target = '10.0.0.0/8'; Description = 'rdp'; SecurityGroup = 'old (sg-1)' }
            )
            $after = @()
            $diff = Get-SgRuleDiff -BeforeRules $before -AfterRules $after
            @($diff.Removed).Count | Should -Be 1
            $diff.Removed[0].Port | Should -Be '3389'
            @($diff.Added).Count | Should -Be 0
        }

        It 'treats identical rule content from different SGs (and different memo) as unchanged' {
            $before = @([PSCustomObject]@{ Direction = 'Inbound'; Protocol = 'tcp'; Port = '443'; Target = '0.0.0.0/0'; Description = 'old memo'; SecurityGroup = 'old-sg (sg-1)' })
            $after = @([PSCustomObject]@{ Direction = 'Inbound'; Protocol = 'tcp'; Port = '443'; Target = '0.0.0.0/0'; Description = 'new memo'; SecurityGroup = 'new-sg (sg-2)' })
            $diff = Get-SgRuleDiff -BeforeRules $before -AfterRules $after
            @($diff.Added).Count | Should -Be 0
            @($diff.Removed).Count | Should -Be 0
        }

        It 'aggregates source SGs for a duplicated added rule' {
            $before = @()
            $after = @(
                [PSCustomObject]@{ Direction = 'Inbound'; Protocol = 'tcp'; Port = '443'; Target = '0.0.0.0/0'; Description = ''; SecurityGroup = 'web-a (sg-1)' },
                [PSCustomObject]@{ Direction = 'Inbound'; Protocol = 'tcp'; Port = '443'; Target = '0.0.0.0/0'; Description = ''; SecurityGroup = 'web-b (sg-2)' }
            )
            $diff = Get-SgRuleDiff -BeforeRules $before -AfterRules $after
            @($diff.Added).Count | Should -Be 1
            @($diff.Added[0].SourceSgs).Count | Should -Be 2
            $diff.Added[0].SourceSgs | Should -Contain 'web-a (sg-1)'
            $diff.Added[0].SourceSgs | Should -Contain 'web-b (sg-2)'
        }
    }
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `Invoke-Pester -Path tests/AwsManager.Tests.ps1`
Expected: `Get-SgRuleDiff` の 4 テストが FAIL（`Get-SgRuleDiff` は未定義で CommandNotFoundException）。既存テストは PASS のまま。

- [ ] **Step 3: 最小実装を書く**

`AwsManager.psm1` の `Export-ModuleMember`（674行）の**直前**に以下を追加する。

```powershell
function Get-SgRuleContentKey {
    param($Rule)
    return (('{0}|{1}|{2}|{3}' -f [string]$Rule.Direction, [string]$Rule.Protocol, [string]$Rule.Port, [string]$Rule.Target)).ToLowerInvariant()
}

function Get-SgNetRuleList {
    param(
        [object[]]$SourceRules,
        [hashtable]$ExcludeKeys
    )
    $list = New-Object System.Collections.Generic.List[PSCustomObject]
    $byKey = @{}
    foreach ($r in @($SourceRules)) {
        if ($null -eq $r) { continue }
        $key = Get-SgRuleContentKey -Rule $r
        if ($ExcludeKeys.ContainsKey($key)) { continue }
        $label = [string]$r.SecurityGroup
        if ($byKey.ContainsKey($key)) {
            $entry = $byKey[$key]
            if (-not [string]::IsNullOrWhiteSpace($label) -and -not $entry.SourceSgs.Contains($label)) { $entry.SourceSgs.Add($label) }
            continue
        }
        $sources = New-Object System.Collections.Generic.List[string]
        if (-not [string]::IsNullOrWhiteSpace($label)) { $sources.Add($label) }
        $entry = [PSCustomObject]@{
            Direction = [string]$r.Direction
            Protocol  = [string]$r.Protocol
            Port      = [string]$r.Port
            Target    = [string]$r.Target
            SourceSgs = $sources
        }
        $byKey[$key] = $entry
        $list.Add($entry)
    }
    return $list.ToArray()
}

function Get-SgRuleDiff {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [object[]]$BeforeRules,
        [object[]]$AfterRules
    )

    $beforeKeys = @{}
    foreach ($r in @($BeforeRules)) { if ($null -ne $r) { $beforeKeys[(Get-SgRuleContentKey -Rule $r)] = $true } }
    $afterKeys = @{}
    foreach ($r in @($AfterRules)) { if ($null -ne $r) { $afterKeys[(Get-SgRuleContentKey -Rule $r)] = $true } }

    return [PSCustomObject]@{
        Added   = @(Get-SgNetRuleList -SourceRules $AfterRules -ExcludeKeys $beforeKeys)
        Removed = @(Get-SgNetRuleList -SourceRules $BeforeRules -ExcludeKeys $afterKeys)
    }
}
```

次に 674行の `Export-ModuleMember` に `Get-SgRuleDiff` を追記する。

```powershell
Export-ModuleMember -Function Get-Ec2Instances, Get-SsmInstanceInformation, Start-Ec2Instance, Stop-Ec2Instance, Restart-Ec2Instance, Get-VpcSecurityGroups, Set-InstanceSecurityGroups, Invoke-SsmTask, ConvertFrom-MinimalYaml, Get-SgRuleDiff
```

- [ ] **Step 4: テストが通ることを確認**

Run: `Invoke-Pester -Path tests/AwsManager.Tests.ps1`
Expected: 全テスト PASS（`Get-SgRuleDiff` の 4 件含む）。

- [ ] **Step 5: Lint**

Run: `Invoke-ScriptAnalyzer -Path AwsManager.psm1`
Expected: 新規追加分に起因する Warning/Error なし（既存の抑制済み項目のみ）。

- [ ] **Step 6: Commit**

```bash
git add AwsManager.psm1 tests/AwsManager.Tests.ps1
git commit -m "feat: add Get-SgRuleDiff for effective SG rule diff"
```

---

### Task 2: `Get-SgDiffData` に実効ルール差分を組み込む（App.ps1）

**Files:**
- Modify: `App.ps1`（`Get-SgDiffData` 1177-1213行）

- [ ] **Step 1: before/after のルール行を作り Get-SgRuleDiff を呼ぶ**

`Get-SgDiffData` 内、`$removedSgs` を組み立てるループ（1199-1202行）の後、`[PSCustomObject]@{ ... }`（1204行）の**前**に以下を追加する。

```powershell
    $beforeRules = @(Get-SgRuleRowsForItems -Items $originalItems)
    $afterRules = @(Get-SgRuleRowsForItems -Items $currentItems)
    $ruleDiff = Get-SgRuleDiff -BeforeRules $beforeRules -AfterRules $afterRules
    $addedRules = @($ruleDiff.Added)
    $removedRules = @($ruleDiff.Removed)
```

- [ ] **Step 2: 出力オブジェクトにフィールドを追加**

`Get-SgDiffData` の戻り値（1204-1212行）を以下に置き換える。

```powershell
    [PSCustomObject]@{
        BeforeIds    = $originalIds
        AfterIds     = $currentIds
        AddedSgs     = $addedSgs
        RemovedSgs   = $removedSgs
        ExistingSgs  = $existingSgs
        ChangedSgs   = @($addedSgs + $removedSgs)
        Changed      = (($addedSgs.Count -gt 0) -or ($removedSgs.Count -gt 0))
        AddedRules   = $addedRules
        RemovedRules = $removedRules
    }
```

- [ ] **Step 3: 構文チェック**

Run: `powershell -NoProfile -Command "[System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw ./App.ps1), [ref]$null) | Out-Null; 'OK'"`
Expected: `OK`（構文エラーなし）。

- [ ] **Step 4: 既存テストが壊れていないことを確認**

Run: `Invoke-Pester -Path tests/`
Expected: 全 PASS（App.ps1 は UI のため直接テスト対象外だが、モジュール側の回帰がないこと）。

- [ ] **Step 5: Commit**

```bash
git add App.ps1
git commit -m "feat: wire effective rule diff into Get-SgDiffData"
```

---

### Task 3: 整形ヘルパー `Format-SgNetRuleLine`（App.ps1）

**Files:**
- Modify: `App.ps1`（`Format-SgRuleLine` 1215-1220行 の直後に追加）

- [ ] **Step 1: 実装を追加**

`Format-SgRuleLine` 関数（1215-1220行）の閉じ `}` の直後に以下を追加する。

```powershell
function Format-SgNetRuleLine {
    param(
        [Parameter(Mandatory = $true)]$Rule
    )
    $src = ''
    $labels = @($Rule.SourceSgs)
    if ($labels.Count -gt 0) {
        $first = [string]$labels[0]
        if ($labels.Count -gt 1) { $src = " (from $first +$($labels.Count - 1))" }
        else { $src = " (from $first)" }
    }
    return ("{0,-8} {1,-7} {2,-9} {3}{4}" -f $Rule.Direction, $Rule.Protocol, $Rule.Port, $Rule.Target, $src)
}
```

- [ ] **Step 2: 構文チェック**

Run: `powershell -NoProfile -Command "[System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw ./App.ps1), [ref]$null) | Out-Null; 'OK'"`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add App.ps1
git commit -m "feat: add Format-SgNetRuleLine helper"
```

---

### Task 4: 画面パネルに実効ルール差分セクション（App.ps1）

**Files:**
- Modify: `App.ps1`（`Render-SgDiffPanel` 1041-1045行の間）

- [ ] **Step 1: パネル先頭にセクションを挿入**

`Render-SgDiffPanel` 内、「適用後SG」を表示する行（1043行）の直後、`Add-SgDiffText -Text 'Security Group 差分' ...`（1045行）の**前**に以下を挿入する。

```powershell
    Add-SgDiffText -Text '実効ルール差分（メモ欄は対象外）' -Color '#BAE6FD' -Bold $true -FontSize 14 | Out-Null
    $netAdded = @($Diff.AddedRules)
    $netRemoved = @($Diff.RemovedRules)
    if ($netAdded.Count -gt 0 -or $netRemoved.Count -gt 0) {
        foreach ($rule in $netAdded) {
            Add-SgDiffText -Text ('[+] ' + (Format-SgNetRuleLine -Rule $rule)) -Color '#38BDF8' | Out-Null
        }
        foreach ($rule in $netRemoved) {
            Add-SgDiffText -Text ('[-] ' + (Format-SgNetRuleLine -Rule $rule)) -Color '#F97373' | Out-Null
        }
    }
    else {
        Add-SgDiffText -Text '実効ルール差分なし（SGの組合せは変わっても開放ルールは同じです）' -Color '#94A3B8' | Out-Null
    }
    Add-SgDiffText -Text '' -Color '#94A3B8' -Bottom 6 | Out-Null

```

- [ ] **Step 2: 構文チェック**

Run: `powershell -NoProfile -Command "[System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw ./App.ps1), [ref]$null) | Out-Null; 'OK'"`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add App.ps1
git commit -m "feat: show effective rule diff section in preview panel"
```

---

### Task 5: テキスト出力に実効ルール差分（App.ps1）

**Files:**
- Modify: `App.ps1`（`Format-SgDiffText` 1261-1262行の間）

- [ ] **Step 1: ヘッダ直後にセクションを挿入**

`Format-SgDiffText` 内、`$lines += ''`（1261行、「適用後SG」の後の空行）の直後、`if (-not $Diff.Changed) {`（1262行）の**前**に以下を挿入する。

```powershell
    $lines += '[実効ルール差分（メモ欄は対象外）]'
    $netAddedRules = @($Diff.AddedRules)
    $netRemovedRules = @($Diff.RemovedRules)
    if ($netAddedRules.Count -gt 0 -or $netRemovedRules.Count -gt 0) {
        foreach ($rule in $netAddedRules) { $lines += ('  [+] ' + (Format-SgNetRuleLine -Rule $rule)) }
        foreach ($rule in $netRemovedRules) { $lines += ('  [-] ' + (Format-SgNetRuleLine -Rule $rule)) }
    }
    else {
        $lines += '  実効ルール差分なし'
    }
    $lines += ''
```

- [ ] **Step 2: 構文チェック**

Run: `powershell -NoProfile -Command "[System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw ./App.ps1), [ref]$null) | Out-Null; 'OK'"`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add App.ps1
git commit -m "feat: include effective rule diff in text output"
```

---

### Task 6: HTML 出力に実効ルール差分パネル（App.ps1）

**Files:**
- Modify: `App.ps1`（`New-SgReportHtml`: 1360行付近で行を組み立て、1389-1390行の間にパネル挿入）

- [ ] **Step 1: 実効ルール差分の行を組み立てる**

`New-SgReportHtml` 内、`$afterRows` を組み立てるループ（1359-1360行）の直後、`$html = @"`（1362行）の**前**に以下を追加する。

```powershell
    $netRuleRows = ''
    foreach ($rule in @($diff.AddedRules)) {
        $netRuleRows += "<tr><td class='added'>[+]</td><td>$(ConvertTo-HtmlText $rule.Direction)</td><td>$(ConvertTo-HtmlText $rule.Protocol)</td><td>$(ConvertTo-HtmlText $rule.Port)</td><td>$(ConvertTo-HtmlText $rule.Target)</td><td>$(ConvertTo-HtmlText ((@($rule.SourceSgs)) -join ', '))</td></tr>`r`n"
    }
    foreach ($rule in @($diff.RemovedRules)) {
        $netRuleRows += "<tr><td class='removed'>[-]</td><td>$(ConvertTo-HtmlText $rule.Direction)</td><td>$(ConvertTo-HtmlText $rule.Protocol)</td><td>$(ConvertTo-HtmlText $rule.Port)</td><td>$(ConvertTo-HtmlText $rule.Target)</td><td>$(ConvertTo-HtmlText ((@($rule.SourceSgs)) -join ', '))</td></tr>`r`n"
    }
    if ([string]::IsNullOrWhiteSpace($netRuleRows)) {
        $netRuleRows = "<tr><td colspan='6'>実効ルール差分なし</td></tr>`r`n"
    }
```

- [ ] **Step 2: HTML テンプレートにパネルを挿入**

`<div class="meta">...</div>`（1389行）の直後、`<div class="panel">`（1390行、`<h2>Security Group 差分</h2>` のパネル）の**前**に以下を挿入する。

```powershell
<div class="panel">
<h2>実効ルール差分（メモ欄は対象外）</h2>
<table>
<thead><tr><th>差分</th><th>方向</th><th>Protocol</th><th>Port</th><th>Source / Destination</th><th>由来SG</th></tr></thead>
<tbody>
$netRuleRows
</tbody>
</table>
</div>
```

- [ ] **Step 3: 構文チェック**

Run: `powershell -NoProfile -Command "[System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw ./App.ps1), [ref]$null) | Out-Null; 'OK'"`
Expected: `OK`

- [ ] **Step 4: Lint**

Run: `Invoke-ScriptAnalyzer -Path App.ps1`
Expected: 新規追加分に起因する Warning/Error なし。

- [ ] **Step 5: Commit**

```bash
git add App.ps1
git commit -m "feat: add effective rule diff panel to HTML report"
```

---

### Task 7: CHANGELOG 更新と手動確認

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: CHANGELOG の `[Unreleased]` に追記**

`CHANGELOG.md` の `[Unreleased]` セクション（`### Added` が無ければ作る）に以下を追加する。

```markdown
### Added
- セキュリティグループ適用プレビューに「実効ルール差分」を追加。付け外しする SG のルールを集約し、instance として実際に増減するルール（Direction/Protocol/Port/Target、メモ欄は対象外）だけをネット差分として表示。画面・テキスト・HTML 出力に対応。
```

- [ ] **Step 2: 手動確認**

`App.ps1` を起動 → Tab2 でインスタンスを選択 → SG を入れ替える（既存 SG と新規 SG に共通ルールがあるケースを含める）。

Expected:
- パネル上部に「実効ルール差分」が表示され、共通ルールは差分に出ず、増減したルールだけ `[+]`/`[-]` で色分け表示される。各行に `(from <SG>)` 注記が出る。
- SG 組合せは変わるが実効ルールが同じ場合「実効ルール差分なし」と出る。
- 「テキスト」表示と HTML 出力（レポート出力ボタン）でも同じ実効ルール差分が一致して見える。

検証できない場合（AWS 環境が無い等）は、その旨と残リスクを完了報告に明記する。

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs: changelog for effective SG rule diff"
```

---

## Self-Review メモ

- **Spec 全項目カバー:** 差分定義（Task 1）/ 純粋関数テスト（Task 1）/ Get-SgDiffData 連携（Task 2）/ 生成元SG注記（Task 3, 各表示）/ パネル（Task 4）/ テキスト（Task 5）/ HTML（Task 6）/ 「実効差分なし」シグナル（Task 4,5,6）/ CHANGELOG（Task 7）。
- **型整合:** ルール行の `SecurityGroup`（ラベル）を注記に使用。差分エントリは `Direction/Protocol/Port/Target/SourceSgs` を全 Task で一貫使用。`Get-SgDiffData` の新フィールドは `AddedRules/RemovedRules`。
- **PS5.1 互換:** 三項/null 合体演算子は未使用。
