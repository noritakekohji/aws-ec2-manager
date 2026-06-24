# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `AwsConfig.psm1` モジュール: `Get-AwsProfiles` / `Get-AwsProfileDetail` / `Test-SsoToken` と Pester テスト
- `AwsManager.psm1` モジュール: EC2 列挙 / 起動・停止・再起動 / SG 取得・割当 / SSM Run Command (`Invoke-SsmTask`) と最小 YAML パーサ、Pester テスト

### Changed
- `AwsConfig.psm1` の `Invoke-AwsCli` が `[PSCustomObject]` (`ExitCode` / `Output` / `Success`) を返すように変更。`$global:LASTEXITCODE` をヘルパー内部で捕捉し、呼び出し側で参照する必要をなくした

### Fixed

## [0.1.0] - 2026-06-25

### Added
- プロジェクト初期化
- `ops-scripts-template/tools/` から 8 ツールを移植
  (aws-instance-audit / cert-check / collect-snapshot / log-collector /
   network-check / perf-monitor / port-inventory / server-snapshot)
