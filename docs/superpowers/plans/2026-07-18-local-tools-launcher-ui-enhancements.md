# LocalToolsLauncher UI 拡張 (select 型パラメータ + perf-monitor Start/Stop) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Windows GUI ツールランチャー(`LocalToolsLauncher.ps1`)に、カタログ駆動のプルダウン選択パラメータ(`type: select`)と、perf-monitor 専用の Start/Stop パネルを追加する。

**Architecture:** 既存の「スナップショット一括実行」専用パネルと同じパターン(ヘッダー直下の固定パネル + `Invoke-ToolExecution -ToolArgsFactory` による非同期実行)を踏襲する。`select` 型はカタログの `parameters[].type` に追加する新しい列挙型で、既存の text/number/checkbox/hidden と同じ枠組みで `ComboBox` を描画する。perf-monitor の Start/Stop は、実行完了後に `artifacts` 配下へ作成された新規セッションディレクトリを検出し、専用パネルと汎用実行パネルの両方から参照できるよう `$script:LastPerfSessionDir` で一方向同期する。

**Tech Stack:** PowerShell 5.1 + WPF (XAML)、Pester 5(既存の `tests/Xaml.Tests.ps1` / `tests/Syntax.Tests.ps1`)。

**設計の参照元:** `docs/superpowers/specs/2026-07-18-local-tools-launcher-ui-enhancements-design.md`(architect サブエージェントによるレビュー反映済み)

## Global Constraints

- PowerShell 5.1 互換必須。`??` / `?:` / `?.` は使用禁止
- `.ps1` は UTF-8 BOM 付きで保存(CP932 環境での文字化け回避)。`Edit` ツールでの編集は既存ファイルの BOM を保持する
- `.xaml` は UTF-8 BOM **なし**で保存(既存 `LocalToolsLauncher.xaml` の規約に合わせる)
- 新規関数は PSScriptAnalyzer `PSUseApprovedVerbs` に適合する承認済み動詞を使う(`Get-`, `Invoke-`)
- `Invoke-ToolExecution` の `-ToolArgsFactory` は `& $ToolArgsFactory $runDir` と位置引数で呼ばれるため、渡す scriptblock は必ず `param($runDir)` を明示する
- このリポジトリの `LocalToolsLauncher.ps1` は関数定義後に GUI を起動する実行コードを含み、dot-source 単体でのユニットテストは行えない(既存の慣習)。検証は (a) `tests/Syntax.Tests.ps1`(構文チェック)、(b) `tests/Xaml.Tests.ps1`(XAML 読み込み + コントロール存在チェック)、(c) 最終タスクでの実機起動確認、の3段で行う

---

## Task 1: カタログスキーマに `select` 型を追加し、パーサーで読めるようにする

**Files:**
- Modify: `tools/tool-catalog.yaml`(server-snapshot, perf-monitor の `command` パラメータ)
- Modify: `LocalToolsLauncher.ps1:182-191`(`Read-ToolCatalog` の `$currentParam` 初期化)
- Modify: `LocalToolsLauncher.ps1:236-245`(`Read-ToolCatalog` の switch-case)

**Interfaces:**
- Consumes: なし(カタログパーサーの独立変更)
- Produces: `Read-ToolCatalog` が返す各パラメータオブジェクトに `Options`(string, カンマ区切り)プロパティが追加される。Task 2 の select レンダラーがこの `Options` プロパティを読む。

- [ ] **Step 1: `tools/tool-catalog.yaml` の server-snapshot / perf-monitor の `command` パラメータを `select` 型に変更する**

`tools/tool-catalog.yaml` の server-snapshot エントリ内、現在の

```yaml
      - key: command
        label: アクション
        type: text
        width: short
        argument: ""
        default: collect
```

を、以下に置き換える(`server-snapshot` 用):

```yaml
      - key: command
        label: アクション
        type: select
        width: short
        argument: ""
        options: "collect,before,after,compare,list"
        default: collect
```

同様に perf-monitor エントリ内、現在の

```yaml
      - key: command
        label: アクション
        type: text
        width: short
        argument: ""
        default: status
```

を、以下に置き換える(`perf-monitor` 用):

```yaml
      - key: command
        label: アクション
        type: select
        width: short
        argument: ""
        options: "start,stop,report,status,list"
        default: status
```

- [ ] **Step 2: `Read-ToolCatalog` の `$currentParam` 初期化に `Options` フィールドを追加する**

`LocalToolsLauncher.ps1` の以下の箇所(182〜191行目付近):

```powershell
            $currentParam = [ordered]@{
                Key = ConvertFrom-ToolCatalogScalar $Matches[2]
                Label = ''
                Type = 'text'
                Width = ''
                Argument = ''
                Default = ''
                Value = ''
                Required = $false
            }
```

を、以下に置き換える:

```powershell
            $currentParam = [ordered]@{
                Key = ConvertFrom-ToolCatalogScalar $Matches[2]
                Label = ''
                Type = 'text'
                Width = ''
                Argument = ''
                Default = ''
                Value = ''
                Required = $false
                Options = ''
            }
```

- [ ] **Step 3: `Read-ToolCatalog` の switch-case に `options` キーを追加する**

同ファイルの以下の箇所(236〜245行目付近):

```powershell
                switch ($key) {
                    'label' { $currentParam.Label = $value }
                    'type' { $currentParam.Type = $value }
                    'width' { $currentParam.Width = $value }
                    'argument' { $currentParam.Argument = $value }
                    'default' { $currentParam.Default = $value }
                    'value' { $currentParam.Value = $value }
                    'required' { $currentParam.Required = ($value -eq 'true') }
                }
```

を、以下に置き換える:

```powershell
                switch ($key) {
                    'label' { $currentParam.Label = $value }
                    'type' { $currentParam.Type = $value }
                    'width' { $currentParam.Width = $value }
                    'argument' { $currentParam.Argument = $value }
                    'default' { $currentParam.Default = $value }
                    'value' { $currentParam.Value = $value }
                    'required' { $currentParam.Required = ($value -eq 'true') }
                    'options' { $currentParam.Options = $value }
                }
```

- [ ] **Step 4: 構文チェックを実行する**

Run: `powershell -NoProfile -Command "Invoke-Pester -Path tests/Syntax.Tests.ps1 -Output Detailed"`
Expected: すべて `Passed`(`LocalToolsLauncher.ps1` の構文エラーなし)

- [ ] **Step 5: コミット**

```bash
git add tools/tool-catalog.yaml LocalToolsLauncher.ps1
git commit -m "feat: tool-catalog に select 型パラメータを追加し LocalToolsLauncher でパース可能にする"
```

---

## Task 2: `select` 型パラメータを ComboBox として描画する

**Files:**
- Modify: `LocalToolsLauncher.ps1:399-408`(`Get-ParameterValueByKey`)
- Modify: `LocalToolsLauncher.ps1:16-31`(スクリプトトップレベルの `$script:` 変数宣言)
- Modify: `LocalToolsLauncher.ps1:775-912`(`Set-ParameterDefaults`)

**Interfaces:**
- Consumes: Task 1 で追加された `$paramDef.Options`(string, カンマ区切り)
- Produces: `$script:SelectParameterControls`(`@({Parameter=<param>; Control=<ComboBox>}, ...)` 形式のリスト)。`Get-ParameterValueByKey -Key <key>` が select 型パラメータの現在値(string)を返せるようになる。`Get-ToolArguments` / `Update-CommandPreview` はこの戻り値を経由するだけで変更不要。

- [ ] **Step 1: スクリプトトップレベルに `$script:SelectParameterControls` を宣言する**

`LocalToolsLauncher.ps1` の以下の行(19行目付近、`$script:TextParameterControls = @()` の直後):

```powershell
$script:TextParameterControls = @()
$script:CheckParameterControls = @()
```

を、以下に置き換える:

```powershell
$script:TextParameterControls = @()
$script:CheckParameterControls = @()
$script:SelectParameterControls = @()
```

- [ ] **Step 2: `Set-ParameterDefaults` 冒頭のリセット処理に追加する**

同ファイルの以下の箇所(781〜783行目付近):

```powershell
    $script:TextParameterControls = @()
    $script:CheckParameterControls = @()
    $ParametersItems.Children.Clear()
```

を、以下に置き換える:

```powershell
    $script:TextParameterControls = @()
    $script:CheckParameterControls = @()
    $script:SelectParameterControls = @()
    $ParametersItems.Children.Clear()
```

- [ ] **Step 3: `Get-ParameterValueByKey` に select 用の分岐を追加する**

同ファイルの以下の関数全体(399〜408行目):

```powershell
function Get-ParameterValueByKey {
    param([string]$Key)
    foreach ($binding in $script:TextParameterControls) {
        if ($binding.Parameter.Key -eq $Key) { return $binding.Control.Text.Trim() }
    }
    foreach ($binding in $script:CheckParameterControls) {
        if ($binding.Parameter.Key -eq $Key) { return [bool]$binding.Control.IsChecked }
    }
    return $null
}
```

を、以下に置き換える:

```powershell
function Get-ParameterValueByKey {
    param([string]$Key)
    foreach ($binding in $script:TextParameterControls) {
        if ($binding.Parameter.Key -eq $Key) { return $binding.Control.Text.Trim() }
    }
    foreach ($binding in $script:CheckParameterControls) {
        if ($binding.Parameter.Key -eq $Key) { return [bool]$binding.Control.IsChecked }
    }
    foreach ($binding in $script:SelectParameterControls) {
        if ($binding.Parameter.Key -eq $Key) {
            $sel = $binding.Control.SelectedItem
            if ($null -eq $sel) { return '' }
            return [string]$sel
        }
    }
    return $null
}
```

- [ ] **Step 4: `compactFields` のレンダリングループに select 分岐を追加する**

同ファイルの以下の箇所(872〜895行目、`Set-ParameterDefaults` 内):

```powershell
    # --- compact fields: numbers + short text (WrapPanel auto-wraps) ---
    if ($compactFields.Count -gt 0) {
        $wrap = New-Object System.Windows.Controls.WrapPanel
        $wrap.Margin = '0,0,0,4'
        foreach ($cfld in $compactFields) {
            $p = $cfld.Param
            $cell = New-Object System.Windows.Controls.StackPanel
            $cell.Orientation = 'Horizontal'
            $cell.Margin = '0,0,18,4'
            $lbl = New-Object System.Windows.Controls.TextBlock
            $lbl.Text = [string]$p.Label
            $lbl.Style = $window.FindResource('FieldLabel')
            $lbl.Margin = '0,0,6,0'
            [void]$cell.Children.Add($lbl)
            $box = New-Object System.Windows.Controls.TextBox
            $box.Width = [double]$cfld.BoxWidth
            $box.Text = Expand-LauncherValue -Value ([string]$p.Default) -Tool $Tool -RunDir $sampleRun
            $box.Add_TextChanged({ Update-CommandPreview })
            [void]$cell.Children.Add($box)
            [void]$wrap.Children.Add($cell)
            $script:TextParameterControls += [pscustomobject]@{ Parameter = $p; Control = $box }
        }
        [void]$ParametersItems.Children.Add($wrap)
    }
```

を、以下に置き換える:

```powershell
    # --- compact fields: numbers + short text + select (WrapPanel auto-wraps) ---
    if ($compactFields.Count -gt 0) {
        $wrap = New-Object System.Windows.Controls.WrapPanel
        $wrap.Margin = '0,0,0,4'
        foreach ($cfld in $compactFields) {
            $p = $cfld.Param
            $cell = New-Object System.Windows.Controls.StackPanel
            $cell.Orientation = 'Horizontal'
            $cell.Margin = '0,0,18,4'
            $lbl = New-Object System.Windows.Controls.TextBlock
            $lbl.Text = [string]$p.Label
            $lbl.Style = $window.FindResource('FieldLabel')
            $lbl.Margin = '0,0,6,0'
            [void]$cell.Children.Add($lbl)
            if ([string]$p.Type -eq 'select') {
                $box = New-Object System.Windows.Controls.ComboBox
                $box.Width = [double]$cfld.BoxWidth
                $opts = @(([string]$p.Options) -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                $box.ItemsSource = $opts
                $defaultVal = [string]$p.Default
                if ($opts -contains $defaultVal) {
                    $box.SelectedItem = $defaultVal
                } elseif ($opts.Count -gt 0) {
                    $box.SelectedIndex = 0
                }
                $box.Add_SelectionChanged({ Update-CommandPreview })
                [void]$cell.Children.Add($box)
                $script:SelectParameterControls += [pscustomobject]@{ Parameter = $p; Control = $box }
            } else {
                $box = New-Object System.Windows.Controls.TextBox
                $box.Width = [double]$cfld.BoxWidth
                $box.Text = Expand-LauncherValue -Value ([string]$p.Default) -Tool $Tool -RunDir $sampleRun
                $box.Add_TextChanged({ Update-CommandPreview })
                [void]$cell.Children.Add($box)
                $script:TextParameterControls += [pscustomobject]@{ Parameter = $p; Control = $box }
            }
            [void]$wrap.Children.Add($cell)
        }
        [void]$ParametersItems.Children.Add($wrap)
    }
```

- [ ] **Step 5: 構文チェックを実行する**

Run: `powershell -NoProfile -Command "Invoke-Pester -Path tests/Syntax.Tests.ps1 -Output Detailed"`
Expected: すべて `Passed`

- [ ] **Step 6: コミット**

```bash
git add LocalToolsLauncher.ps1
git commit -m "feat: select 型パラメータを ComboBox として描画する"
```

---

## Task 3: XAML に perf-monitor 専用パネルを追加する

**Files:**
- Modify: `LocalToolsLauncher.xaml:271-278`(`Grid.RowDefinitions`)
- Modify: `LocalToolsLauncher.xaml`(新規 Border パネル挿入、既存 `Grid.Row` の繰り下げ)
- Modify: `tests/Xaml.Tests.ps1:75-86`(`LocalToolsLauncher control inventory` の対象リスト)

**Interfaces:**
- Consumes: なし
- Produces: XAML 名前付き要素 `PerfIntervalTextBox`, `PerfDurationTextBox`, `PerfStartButton`, `PerfSessionDirTextBox`, `BrowsePerfSessionDirButton`, `OpenPerfSessionDirButton`, `PerfStopButton`。Task 4 がこれらを `$window.FindName(...)` で取得する。

- [ ] **Step 1: (テストを先に赤くする) `tests/Xaml.Tests.ps1` の control inventory に新規7要素を追加する**

`tests/Xaml.Tests.ps1` の以下の箇所(75〜83行目):

```powershell
    It 'contains required control <_>' -ForEach @(
        'HeaderAwsProfileComboBox', 'OpenOutputButton', 'OpenLogButton', 'OpenSettingsButton',
        'ToolListBox', 'ToolTitleText', 'ToolDescriptionText', 'CommandPreviewTextBox',
        'LogTextBox', 'StatusText', 'RunButton', 'StopButton',
        'RunProgressBar', 'OpenLastRunButton', 'ClearLogButton',
        'SnapshotLabelTextBox', 'SnapshotZipTextBox', 'SnapshotCompareZipTextBox',
        'SnapshotDiffOnlyCheckBox', 'RunCollectSnapshotButton', 'RunSnapshotReportButton',
        'BrowseSnapshotZipButton', 'BrowseSnapshotCompareZipButton',
        'ConfigFilesPanel', 'ConfigFilesItems', 'ParametersItems'
    ) {
        $script:LauncherWindow.FindName($_) | Should -Not -BeNullOrEmpty
    }
```

を、以下に置き換える:

```powershell
    It 'contains required control <_>' -ForEach @(
        'HeaderAwsProfileComboBox', 'OpenOutputButton', 'OpenLogButton', 'OpenSettingsButton',
        'ToolListBox', 'ToolTitleText', 'ToolDescriptionText', 'CommandPreviewTextBox',
        'LogTextBox', 'StatusText', 'RunButton', 'StopButton',
        'RunProgressBar', 'OpenLastRunButton', 'ClearLogButton',
        'SnapshotLabelTextBox', 'SnapshotZipTextBox', 'SnapshotCompareZipTextBox',
        'SnapshotDiffOnlyCheckBox', 'RunCollectSnapshotButton', 'RunSnapshotReportButton',
        'BrowseSnapshotZipButton', 'BrowseSnapshotCompareZipButton',
        'ConfigFilesPanel', 'ConfigFilesItems', 'ParametersItems',
        'PerfIntervalTextBox', 'PerfDurationTextBox', 'PerfStartButton',
        'PerfSessionDirTextBox', 'BrowsePerfSessionDirButton', 'OpenPerfSessionDirButton',
        'PerfStopButton'
    ) {
        $script:LauncherWindow.FindName($_) | Should -Not -BeNullOrEmpty
    }
```

- [ ] **Step 2: テストを実行して失敗を確認する**

Run: `powershell -NoProfile -Command "Invoke-Pester -Path tests/Xaml.Tests.ps1 -Output Detailed"`
Expected: `LocalToolsLauncher control inventory` の新規7項目が `FAIL`(まだ XAML に存在しないため)。他の項目は `Passed`。

- [ ] **Step 3: `Grid.RowDefinitions` に新規行を追加する**

`LocalToolsLauncher.xaml` の以下の箇所(271〜278行目):

```xml
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto" />
            <RowDefinition Height="Auto" />
            <RowDefinition Height="*" MinHeight="260" />
            <RowDefinition Height="Auto" />
            <RowDefinition Height="180" MinHeight="90" />
            <RowDefinition Height="Auto" />
        </Grid.RowDefinitions>
```

を、以下に置き換える(3行目に新規 `Auto` 行を挿入):

```xml
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto" />
            <RowDefinition Height="Auto" />
            <RowDefinition Height="Auto" />
            <RowDefinition Height="*" MinHeight="260" />
            <RowDefinition Height="Auto" />
            <RowDefinition Height="180" MinHeight="90" />
            <RowDefinition Height="Auto" />
        </Grid.RowDefinitions>
```

- [ ] **Step 4: 既存4箇所の `Grid.Row` を1つずつ繰り下げる**

以下の4箇所を、それぞれ置き換える。

(a) ツール一覧+詳細パネルのラッパー Grid(380行目付近):

```xml
        <Grid Grid.Row="2" Margin="16,12,16,0">
```

を、以下に置き換える:

```xml
        <Grid Grid.Row="3" Margin="16,12,16,0">
```

(b) GridSplitter(454行目付近):

```xml
        <GridSplitter Grid.Row="3"
```

を、以下に置き換える:

```xml
        <GridSplitter Grid.Row="4"
```

(c) ログパネル(462行目付近):

```xml
        <Border Grid.Row="4" Style="{StaticResource PanelBorder}" Margin="16,0,16,0">
```

を、以下に置き換える:

```xml
        <Border Grid.Row="5" Style="{StaticResource PanelBorder}" Margin="16,0,16,0">
```

(d) ステータスバー(484行目付近):

```xml
        <Border Grid.Row="5" Background="#0B1220" BorderBrush="#263247" BorderThickness="0,1,0,0" Padding="14,7" Margin="0,10,0,0">
```

を、以下に置き換える:

```xml
        <Border Grid.Row="6" Background="#0B1220" BorderBrush="#263247" BorderThickness="0,1,0,0" Padding="14,7" Margin="0,10,0,0">
```

- [ ] **Step 5: perf-monitor 専用パネルを挿入する**

「スナップショット一括実行」パネルの `</Border>` 閉じタグ(377行目付近、`<!-- ============ ツール一覧 + 詳細 ============ -->` コメントの直前)の直後に、以下のブロックを挿入する:

```xml
        <!-- ============ パフォーマンス監視 (perf-monitor) ============ -->
        <Border Grid.Row="2" Style="{StaticResource PanelBorder}" Margin="16,12,16,0">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto" />
                    <RowDefinition Height="Auto" />
                    <RowDefinition Height="Auto" />
                </Grid.RowDefinitions>
                <TextBlock Text="パフォーマンス監視(perf-monitor)" FontWeight="SemiBold" FontSize="15" Foreground="#BAE6FD" />

                <Grid Grid.Row="1" Margin="0,10,0,0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="80" />
                        <ColumnDefinition Width="70" />
                        <ColumnDefinition Width="80" />
                        <ColumnDefinition Width="90" />
                        <ColumnDefinition Width="120" />
                    </Grid.ColumnDefinitions>
                    <TextBlock Text="間隔(秒)" Style="{StaticResource FieldLabel}" ToolTip="収集間隔(秒)" />
                    <TextBox x:Name="PerfIntervalTextBox" Grid.Column="1" Text="5" Margin="0,0,12,0" ToolTip="収集間隔(秒)" />
                    <TextBlock Grid.Column="2" Text="時間(秒)" Style="{StaticResource FieldLabel}" ToolTip="収集時間(秒)。空欄なら「停止」を押すまで収集し続ける" />
                    <TextBox x:Name="PerfDurationTextBox" Grid.Column="3" Margin="0,0,12,0" ToolTip="収集時間(秒)。空欄なら「停止」を押すまで収集し続ける" />
                    <Button x:Name="PerfStartButton" Grid.Column="4" Content="開始" Style="{StaticResource PrimaryButton}" ToolTip="バックグラウンドで収集を開始する" />
                </Grid>

                <Grid Grid.Row="2" Margin="0,8,0,0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="80" />
                        <ColumnDefinition Width="*" />
                        <ColumnDefinition Width="44" />
                        <ColumnDefinition Width="60" />
                        <ColumnDefinition Width="90" />
                    </Grid.ColumnDefinitions>
                    <TextBlock Text="セッション" Style="{StaticResource FieldLabel}" ToolTip="収集セッションのディレクトリ。「開始」を押すと自動入力される" />
                    <TextBox x:Name="PerfSessionDirTextBox" Grid.Column="1" Margin="0,0,4,0" ToolTip="収集セッションのディレクトリ。「開始」を押すと自動入力される" />
                    <Button x:Name="BrowsePerfSessionDirButton" Grid.Column="2" Content="..." Style="{StaticResource SmallBrowseButton}" Margin="0,0,4,0" ToolTip="セッションディレクトリをエクスプローラから選択" />
                    <Button x:Name="OpenPerfSessionDirButton" Grid.Column="3" Content="開く" Margin="0,0,12,0" ToolTip="セッションディレクトリをエクスプローラで開く" />
                    <Button x:Name="PerfStopButton" Grid.Column="4" Content="停止" Style="{StaticResource DangerButton}" ToolTip="このセッションの収集を停止する" />
                </Grid>
            </Grid>
        </Border>

```

- [ ] **Step 6: テストを実行して成功を確認する**

Run: `powershell -NoProfile -Command "Invoke-Pester -Path tests/Xaml.Tests.ps1 -Output Detailed"`
Expected: すべて `Passed`(新規7項目を含む)

- [ ] **Step 7: コミット**

```bash
git add LocalToolsLauncher.xaml tests/Xaml.Tests.ps1
git commit -m "feat: perf-monitor 専用パネルを XAML に追加する"
```

---

## Task 4: perf-monitor パネルの PowerShell ロジックを実装する

**Files:**
- Modify: `LocalToolsLauncher.ps1:16-31`(スクリプトトップレベルの `$script:` 変数宣言に `$script:LastPerfSessionDir` を追加)
- Modify: `LocalToolsLauncher.ps1`(`Invoke-SnapshotReport` の直後に新規関数4つを追加)
- Modify: `LocalToolsLauncher.ps1:1345-1370`(`$window.FindName(...)` ブロック)
- Modify: `LocalToolsLauncher.ps1:1435-1445`(ボタンクリックハンドラの登録ブロック)

**Interfaces:**
- Consumes: Task 3 の XAML 名前付き要素(`PerfIntervalTextBox` 等7個)、既存 `Get-ToolById` / `Invoke-ToolExecution` / `Add-ArgumentValue` / `Add-ConfigFileArgs` / `Get-ArtifactsDir` / `Select-FolderDialog` / `Set-Status`
- Produces: `Invoke-PerfMonitorStart`, `Invoke-PerfMonitorStop`(ボタンから呼ばれる)。`$script:LastPerfSessionDir`(Task 5 が読む)

- [ ] **Step 1: `$script:LastPerfSessionDir` をスクリプトトップレベルに追加する**

`LocalToolsLauncher.ps1` の以下の行(31行目付近、`$script:ConfigFileOverrides = @{}` の直後):

```powershell
$script:ConfigFileOverrides = @{}   # "<toolId>::<label>" -> user-selected absolute path
```

を、以下に置き換える:

```powershell
$script:ConfigFileOverrides = @{}   # "<toolId>::<label>" -> user-selected absolute path
$script:LastPerfSessionDir = ''     # perf-monitor: 直近開始したセッションディレクトリ(専用パネルと汎用パネルで共有)
```

- [ ] **Step 2: perf-monitor 用の引数生成・実行関数を追加する**

`Invoke-SnapshotReport` 関数の閉じ `}`(1234行目付近、`Select-FolderDialog` 関数定義の直前)の直後に、以下を挿入する:

```powershell
function Get-PerfMonitorStartArguments {
    param([string]$RunDir, $Tool)
    $argList = New-Object System.Collections.Generic.List[string]
    [void]$argList.Add('start')
    Add-ArgumentValue -Arguments $argList -Name '-Interval' -Value $PerfIntervalTextBox.Text
    Add-ArgumentValue -Arguments $argList -Name '-Duration' -Value $PerfDurationTextBox.Text
    $artifacts = Get-ArtifactsDir -RunDir $RunDir
    Add-ArgumentValue -Arguments $argList -Name '-OutputDir' -Value $artifacts
    Add-ConfigFileArgs -Arguments $argList -Tool $Tool
    return $argList.ToArray()
}

function Get-PerfMonitorStopArguments {
    param([string]$RunDir)
    $argList = New-Object System.Collections.Generic.List[string]
    [void]$argList.Add('stop')
    [void]$argList.Add($PerfSessionDirTextBox.Text.Trim())
    return $argList.ToArray()
}

function Invoke-PerfMonitorStart {
    $tool = Get-ToolById -ToolId 'perf-monitor'
    if ($null -eq $tool) {
        [System.Windows.MessageBox]::Show('perf-monitor がカタログに見つかりません。', 'ツールランチャー') | Out-Null
        return
    }
    Invoke-ToolExecution -Tool $tool -ToolArgsFactory { param($runDir) Get-PerfMonitorStartArguments -RunDir $runDir -Tool $tool }
}

function Invoke-PerfMonitorStop {
    if (-not $PerfSessionDirTextBox.Text.Trim()) {
        [System.Windows.MessageBox]::Show('セッションディレクトリを指定してください(開始後に自動入力されます)。', 'ツールランチャー') | Out-Null
        return
    }
    $tool = Get-ToolById -ToolId 'perf-monitor'
    if ($null -eq $tool) {
        [System.Windows.MessageBox]::Show('perf-monitor がカタログに見つかりません。', 'ツールランチャー') | Out-Null
        return
    }
    Invoke-ToolExecution -Tool $tool -ToolArgsFactory { param($runDir) Get-PerfMonitorStopArguments -RunDir $runDir }
}
```

- [ ] **Step 3: `$window.FindName(...)` ブロックに新規7要素を追加する**

`LocalToolsLauncher.ps1` の以下の行(1370行目付近、`$ParametersItems = $window.FindName('ParametersItems')` の直後):

```powershell
$ParametersItems = $window.FindName('ParametersItems')
```

を、以下に置き換える:

```powershell
$ParametersItems = $window.FindName('ParametersItems')
$PerfIntervalTextBox = $window.FindName('PerfIntervalTextBox')
$PerfDurationTextBox = $window.FindName('PerfDurationTextBox')
$PerfStartButton = $window.FindName('PerfStartButton')
$PerfSessionDirTextBox = $window.FindName('PerfSessionDirTextBox')
$BrowsePerfSessionDirButton = $window.FindName('BrowsePerfSessionDirButton')
$OpenPerfSessionDirButton = $window.FindName('OpenPerfSessionDirButton')
$PerfStopButton = $window.FindName('PerfStopButton')
```

- [ ] **Step 4: ボタンのクリックハンドラを登録する**

`LocalToolsLauncher.ps1` の以下の行(1436行目付近、`$RunSnapshotReportButton.Add_Click({ Invoke-SnapshotReport })` の直後):

```powershell
$RunSnapshotReportButton.Add_Click({ Invoke-SnapshotReport })
```

を、以下に置き換える:

```powershell
$RunSnapshotReportButton.Add_Click({ Invoke-SnapshotReport })
$PerfStartButton.Add_Click({ Invoke-PerfMonitorStart })
$PerfStopButton.Add_Click({ Invoke-PerfMonitorStop })
$BrowsePerfSessionDirButton.Add_Click({
    $sel = Select-FolderDialog -InitialPath $PerfSessionDirTextBox.Text -Description 'セッションディレクトリを選択'
    if ($sel) {
        $PerfSessionDirTextBox.Text = $sel
        $script:LastPerfSessionDir = $sel
    }
})
$OpenPerfSessionDirButton.Add_Click({
    $dir = $PerfSessionDirTextBox.Text.Trim()
    if (-not $dir -or -not (Test-Path -LiteralPath $dir)) {
        Set-Status 'セッションディレクトリがありません(開始後に自動入力されます)'
        return
    }
    Start-Process explorer.exe -ArgumentList $dir
})
```

- [ ] **Step 5: 構文チェックを実行する**

Run: `powershell -NoProfile -Command "Invoke-Pester -Path tests/Syntax.Tests.ps1 -Output Detailed"`
Expected: すべて `Passed`

- [ ] **Step 6: コミット**

```bash
git add LocalToolsLauncher.ps1
git commit -m "feat: perf-monitor 専用パネルの Start/Stop ロジックを実装する"
```

---

## Task 5: セッションディレクトリの自動検出と汎用パネルとの初期値共有

**Files:**
- Modify: `LocalToolsLauncher.ps1`(`Complete-ToolExecution` 内、`collect-snapshot` 自動反映ブロックの直後)
- Modify: `LocalToolsLauncher.ps1:803-812`(`Set-ParameterDefaults` の textParams ループ、`sessionDir` 初期値の特別分岐)

**Interfaces:**
- Consumes: Task 4 の `$script:LastPerfSessionDir`、Task 4 の `$PerfSessionDirTextBox`
- Produces: `Complete-ToolExecution` 完了時に `$script:LastPerfSessionDir` が更新される。`Set-ParameterDefaults` が perf-monitor の汎用 `sessionDir` 欄の初期値として `$script:LastPerfSessionDir` を使うようになる。

- [ ] **Step 1: `Complete-ToolExecution` に perf-monitor 用のセッション自動検出ブロックを追加する**

`LocalToolsLauncher.ps1` の `collect-snapshot` 専用の自動反映ブロック(以下、1149〜1159行目付近):

```powershell
            if ($ctx.ToolId -eq 'collect-snapshot' -and $null -ne $SnapshotZipTextBox) {
                $artifactsDir = Join-Path $ctx.RunDir 'artifacts'
                if (Test-Path -LiteralPath $artifactsDir) {
                    $producedZip = Get-ChildItem -LiteralPath $artifactsDir -Filter '*.zip' -File -ErrorAction SilentlyContinue |
                        Sort-Object LastWriteTime -Descending | Select-Object -First 1
                    if ($null -ne $producedZip) {
                        $SnapshotZipTextBox.Text = $producedZip.FullName
                        Add-LogLine "出力対象ZIPに自動設定: $($producedZip.FullName)"
                    }
                }
            }
```

の直後(同じ `if ($null -ne $ctx) { ... }` ブロック内)に、以下を追加する:

```powershell
            if ($ctx.ToolId -eq 'perf-monitor' -and $null -ne $PerfSessionDirTextBox) {
                $artifactsDir = Join-Path $ctx.RunDir 'artifacts'
                if (Test-Path -LiteralPath $artifactsDir) {
                    $sessionSubDir = Get-ChildItem -LiteralPath $artifactsDir -Directory -ErrorAction SilentlyContinue |
                        Sort-Object LastWriteTime -Descending | Select-Object -First 1
                    if ($null -ne $sessionSubDir) {
                        $PerfSessionDirTextBox.Text = $sessionSubDir.FullName
                        $script:LastPerfSessionDir = $sessionSubDir.FullName
                        Add-LogLine "セッションディレクトリを自動設定: $($sessionSubDir.FullName)"
                    }
                }
            }
```

(`stop` 実行時は `artifacts` 配下に新規ディレクトリが作られないため、このブロックは自然に no-op になる。)

- [ ] **Step 2: `Set-ParameterDefaults` の textParams ループに `sessionDir` 初期値の特別分岐を追加する**

`LocalToolsLauncher.ps1` の以下の箇所(803〜812行目付近):

```powershell
    foreach ($p in $textParams) {
        $key = [string]$p.Key
        $cf = $null
        if ($paramCfgMap.ContainsKey($key)) { $cf = $paramCfgMap[$key] }
        if ($null -ne $cf) {
            $initial = Get-ConfigFileEffectivePath -ToolId $toolId -ConfigFile $cf
        } else {
            $initial = Expand-LauncherValue -Value ([string]$p.Default) -Tool $Tool -RunDir $sampleRun
        }
```

を、以下に置き換える:

```powershell
    foreach ($p in $textParams) {
        $key = [string]$p.Key
        $cf = $null
        if ($paramCfgMap.ContainsKey($key)) { $cf = $paramCfgMap[$key] }
        if ($null -ne $cf) {
            $initial = Get-ConfigFileEffectivePath -ToolId $toolId -ConfigFile $cf
        } elseif ($key -eq 'sessionDir' -and $toolId -eq 'perf-monitor' -and $script:LastPerfSessionDir) {
            $initial = $script:LastPerfSessionDir
        } else {
            $initial = Expand-LauncherValue -Value ([string]$p.Default) -Tool $Tool -RunDir $sampleRun
        }
```

- [ ] **Step 3: 構文チェックを実行する**

Run: `powershell -NoProfile -Command "Invoke-Pester -Path tests/Syntax.Tests.ps1 -Output Detailed"`
Expected: すべて `Passed`

- [ ] **Step 4: コミット**

```bash
git add LocalToolsLauncher.ps1
git commit -m "feat: perf-monitor のセッションディレクトリを専用パネルと汎用パネルで共有する"
```

---

## Task 6: 実機起動による統合検証

**Files:** なし(検証のみ、コード変更なし)

**Interfaces:**
- Consumes: Task 1〜5 の全実装
- Produces: 検証結果(完了報告に記載)

- [ ] **Step 1: Pester テストスイート全体を実行する**

Run: `powershell -NoProfile -Command "Invoke-Pester -Path tests/ -Output Detailed"`
Expected: すべて `Passed`(既存テストを含め回帰なし)

- [ ] **Step 2: PSScriptAnalyzer lint を実行する**

Run:
```powershell
powershell -NoProfile -Command "
$excluded = @('PSReviewUnusedParameter','PSAvoidUsingEmptyCatchBlock','PSUseSingularNouns','PSUseShouldProcessForStateChangingFunctions','PSAvoidUsingInvokeExpression','PSUseDeclaredVarsMoreThanAssignments')
Invoke-ScriptAnalyzer -Path LocalToolsLauncher.ps1 -Severity Warning -ExcludeRule $excluded
"
```
Expected: 出力なし(警告 0 件)。新規関数(`Get-PerfMonitorStartArguments` 等)はすべて承認済み動詞を使用しているため、`PSUseApprovedVerbs` を含め既存の除外リストのままで通るはずである。

- [ ] **Step 3: 実機で `LocalToolsLauncher.ps1` を起動する**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File LocalToolsLauncher.ps1`

確認項目:
- 起動時にエラーダイアログが出ないこと
- ツール一覧で `server-snapshot` を選択し、「アクション」欄がテキストボックスではなく `collect/before/after/compare/list` を選べるプルダウンになっていること
- 同様に `perf-monitor` を選択し、「アクション」欄がプルダウンになっていること
- ヘッダー直下、「スナップショット一括実行」パネルの下に「パフォーマンス監視(perf-monitor)」パネルが表示されていること
- パネルの「開始」ボタンを押すと、収集が開始され(ログにコマンドプレビューと `ExitCode: 0` が表示される)、完了後に「セッション」欄へパスが自動入力されること
- ツール一覧で `perf-monitor` を選び直し、「アクション」を `status` にして「実行」ボタンを押すと、汎用パラメータ欄の「セッション」に直前の開始で使われたパスが初期値として入っていること、実行結果のログにアクティブなセッションの状態が表示されること
- 専用パネルの「停止」ボタンを押すと、収集が停止されること(ログに `ExitCode: 0` が表示される)
- 「セッション」欄の「...」でフォルダ選択ダイアログが開くこと、「開く」でエクスプローラが開くこと(セッションディレクトリが存在する場合)

Expected: 上記すべてが期待通りに動作する。

- [ ] **Step 4: 検証結果を完了報告にまとめる**

実施できた項目・できなかった項目(AWS SSO 未ログイン環境等の制約がある場合)を明記する。

---

## Self-Review Notes

- **spec カバレッジ**: spec §2(select 型)→ Task 1・2、spec §3.2(XAML)→ Task 3、spec §3.3(PowerShell ロジック)→ Task 4、spec §3.4(セッション自動検出+汎用パネル共有)→ Task 5、spec §3.5(スコープ外の担保)→ Task 6 の実機確認で検証。spec §4(変更しない事項)は本計画でも変更していない。
- **プレースホルダー確認**: 各ステップに実コードを記載済み。「TODO」「後で実装」等の記述なし。
- **型・シグネチャの一貫性**: `Get-PerfMonitorStartArguments -RunDir -Tool` / `Get-PerfMonitorStopArguments -RunDir` の呼び出し側(Task 4 Step 2 の `Invoke-PerfMonitorStart` / `Invoke-PerfMonitorStop`)とシグネチャが一致している。`$script:LastPerfSessionDir` の宣言(Task 4 Step 1)、更新箇所(Task 5 Step 1、Task 4 Step 4 のブラウズボタン)、参照箇所(Task 5 Step 2)で変数名が一貫している。
