#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# 全 .ps1 / .psm1 の構文チェックとエンコーディング(UTF-8 BOM)チェック。
# dot-source 分割後の App.ps1 + src/*.ps1 が起動時に構文エラーで落ちるのを未然に防ぐ。

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
# -LiteralPath + -Include はフィルタが効かないため、拡張子で明示的に絞り込む
$appScriptFiles = @(
    Get-ChildItem -LiteralPath $repoRoot -File
    Get-ChildItem -LiteralPath (Join-Path $repoRoot 'src') -File -ErrorAction SilentlyContinue
) | Where-Object { $_.Extension -in @('.ps1', '.psm1') }
$scriptFiles = @($appScriptFiles) + @(
    Get-ChildItem -LiteralPath (Join-Path $repoRoot 'tests') -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -eq '.ps1' }
)

Describe 'PowerShell syntax' {
    It 'parses <_.Name> without errors' -ForEach $scriptFiles {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors) | Out-Null
        if ($null -ne $errors -and @($errors).Count -gt 0) {
            $detail = (@($errors) | ForEach-Object { "$($_.Extent.StartLineNumber): $($_.Message)" }) -join "`n"
            throw "構文エラー: $($_.FullName)`n$detail"
        }
    }
}

Describe 'Encoding (UTF-8 BOM)' {
    # CP932 環境での文字化けを防ぐため、日本語を含む .ps1/.psm1 は BOM 付き必須(CLAUDE.md 規約)
    It '<_.Name> starts with a UTF-8 BOM' -ForEach $appScriptFiles {
        $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
        $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        $hasBom | Should -BeTrue -Because "$($_.Name) は UTF-8 BOM 付きで保存する規約"
    }
}
