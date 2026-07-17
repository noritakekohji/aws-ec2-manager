#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

$xamlFiles = Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '..') -Filter '*.xaml' -File

Describe 'XAML files load without error' {
    BeforeAll {
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
    }

    # XAML は UTF-8 想定（BOM の有無は混在: MainWindow.xaml は BOM 付き、
    # LocalToolsLauncher*.xaml は BOM なし）。PS 5.1 既定のエンコーディング検出だと
    # BOM なしファイルが CP932 として読まれ日本語が文字化けするため、
    # 実アプリの読み込みコードと同じく -Encoding UTF8 を明示する。
    It 'loads <_.Name> via XamlReader without throwing' -ForEach $xamlFiles {
        $xamlPath = $_.FullName
        {
            [xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
            $reader = New-Object System.Xml.XmlNodeReader $xaml
            [Windows.Markup.XamlReader]::Load($reader) | Out-Null
        } | Should -Not -Throw
    }
}

Describe 'MainWindow control inventory' {
    BeforeAll {
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
        $xamlPath = Join-Path $PSScriptRoot '..\MainWindow.xaml'
        [xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
        $reader = New-Object System.Xml.XmlNodeReader $xaml
        $script:MainWindow = [Windows.Markup.XamlReader]::Load($reader)
    }

    # src/*.ps1 が Find-Control で参照するコントロールが揃っていることの担保。
    # 名前を変えた場合はここも合わせて更新する。
    It 'contains required control <_>' -ForEach @(
        # ヘッダー
        'ProfileComboBox', 'ProfileInfoText', 'CheckTokenButton', 'SsoLoginButton',
        'OpenSsoButton', 'LogButton', 'SettingsButton',
        # 左ペイン
        'InstanceFilterBox', 'InstanceFilterHint', 'InstancesGrid', 'InstanceEmptyText',
        'InstanceListProgressBar', 'InstanceCountText', 'RefreshInstancesButton',
        'StartInstanceButton', 'StopInstanceButton', 'RestartInstanceButton',
        'LockInstanceButton', 'UnlockInstanceButton',
        # 右ペイン共通
        'SelectedInstanceHeaderText', 'SelectedInstanceSubText', 'DetailTabs', 'NoSelectionOverlay',
        # 詳細タブ
        'DetailGrid',
        # SG タブ
        'ReloadSgButton', 'SgStatusText', 'ExportSgReportButton', 'ApplySgButton',
        'AppliedSgList', 'AvailableSgList', 'MoveToAppliedButton', 'MoveToAvailableButton', 'SgDiffPanel',
        # ロールタブ
        'ReloadRoleButton', 'RoleStatusText', 'ApplyRoleButton',
        'AppliedRoleList', 'AvailableRoleList', 'MoveRoleToAppliedButton', 'MoveRoleToAvailableButton', 'RoleDiffPanel',
        # ツール実行タブ
        'RescanYamlButton', 'OpenYamlFolderButton', 'SsmPlatformText', 'AddYamlButton',
        'YamlListBox', 'YamlInfoText', 'YamlScriptPreviewText', 'SaveYamlButton', 'RunSsmButton', 'SsmOutputText',
        # ステータスバー
        'StatusBarText', 'TaskProgressBar', 'CancelTaskButton'
    ) {
        $script:MainWindow.FindName($_) | Should -Not -BeNullOrEmpty
    }
}
