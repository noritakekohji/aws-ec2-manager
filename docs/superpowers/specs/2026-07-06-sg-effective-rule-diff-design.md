# 設計: セキュリティグループ 実効ルール差分

- 日付: 2026-07-06
- 対象: aws-ec2-manager / Tab2（セキュリティグループ適用プレビュー）
- ステータス: 設計確定（実装前）

## 背景と課題

現在の SG 差分（`Get-SgDiffData` in `App.ps1`）は **SG の付け外し単位**で差分を取る。
「追加された SG / 削除された SG / 元からある SG」に分類し、追加・削除された SG は
その中身（Inbound/Outbound ルール）を全展開して表示する。

このため、SG を入れ替えたときに **instance として実際に開く/閉じるポート（ルール）が
どう変わるのか**が一目で分からない。たとえば SG-A を外して SG-B を付けたとき、
両方が `tcp/443/0.0.0.0/0` を許可していても、現状は「+SG-B の全ルール」「-SG-A の全ルール」
として別々に全表示されるため、ユーザーが頭の中で重複を差し引いて実効の増減を計算する必要がある。

## ゴール

適用前後の全 SG のルールを集約し、**実際に増減したルール（ネット差分）だけ**を
サマリとして提示する。SG をまたいで重複するルールは「変化なし」として相殺する。

- メモ欄（ルールの Description）は比較対象外
- 生成元 SG がどこかは追えるようにする（注記）
- 画面パネル・テキスト出力・HTML 出力の 3 系統すべてに反映する

## 非ゴール（YAGNI）

- CIDR の包含計算（例: `10.0.0.0/8` が `10.0.1.0/24` を包含する等）は行わない。Target は文字列一致で比較する。
- 任意 2 SG の突き合わせ比較モードは作らない。
- 「元からある SG」の AWS 側ルール変更検知は対象外（この tab では before/after が同一 VPC スナップショット由来のため中身は不変）。

## 差分の定義

### ルール同一性キー（実効差分用）

新しいキー関数を導入する（既存の `Get-SgRuleKey` はメモと生成元 SG を含むため流用不可）。

- 実効差分キー = `Direction | Protocol | Port | Target`
- **メモ（Description）と生成元 SG（SecurityGroupId）は含めない**
- 大文字小文字は区別しない（比較を安定させる）

### 集合とネット差分

- before 集合 = 変更前の全 SG（`tab2State.OriginalSgItems`）のルール行を集約
- after 集合 = 変更後の全 SG（現在の `appliedSgList`）のルール行を集約
- ルール行は既存の `Get-SgRuleRowsForItems` で生成する（`Protocol` が `(ルールなし)` の行は除外済み）
- **Added（開く / `[+]`）** = after にあって before にない実効差分キー
- **Removed（閉じる / `[-]`）** = before にあって after にない実効差分キー
- 同一キーが複数 SG 由来で重複する場合は 1 件に集約する（生成元 SG は注記用にまとめて保持）

「元からある SG」のルールは before/after 双方に含まれるため自動的に相殺され、
本当に増減したルールだけが残る。SG-A→SG-B の入替で両者に `tcp/443/0.0.0.0/0` があれば
差分ゼロになる（意図どおり）。

## コンポーネント設計

### 1. 純粋関数 `Get-SgRuleDiff`（`AwsManager.psm1`）

差分計算ロジックを純粋関数として module 側に置き、Pester でテスト可能にする。
現状 App.ps1 側の差分・整形ロジックは無テストなので、少なくともこのコア計算は
テスト対象にする。

- 入力: `[PSCustomObject[]]$BeforeRules`, `[PSCustomObject[]]$AfterRules`
  （`Direction/Protocol/Port/Target/Description/SecurityGroupId/SecurityGroup` を持つルール行）
- 出力: `[PSCustomObject]@{ Added = @(...); Removed = @(...) }`
  - 各要素はルール行 + 集約した生成元 SG 情報
- キー = `Direction|Protocol|Port|Target`（case-insensitive、Description と SecurityGroupId は無視）
- 重複キーは 1 件に集約し、生成元 SG ラベルを配列で保持

App.ps1 の `Get-SgDiffData` は既存の `Get-SgRuleRowsForItems` で before/after の
ルール行を作り、この関数へ渡すだけにする。戻り値に `AddedRules` / `RemovedRules` フィールドを追加する。

### 2. 画面パネル（`Render-SgDiffPanel` in `App.ps1`）

既存の「Security Group 差分」セクションの**上に新セクションを追加**する。既存表示は残す。

```
実効ルール差分（メモ欄は対象外）
  [+] Inbound  tcp  443  0.0.0.0/0      (from web-sg)          ← 青 #38BDF8
  [-] Inbound  tcp  22   10.0.0.0/8     (from old-ssh-sg)      ← 赤 #F97373
```

- `[+]` = 開く方向（青系 `#38BDF8`）、`[-]` = 閉じる方向（赤系 `#F97373`）
- 各行末尾に生成元 SG を薄色で注記。複数 SG 由来なら `(from web-sg +1)` のように要約
- SG の組合せは変わるが実効ルールが同じ場合は
  「実効ルール差分なし（SG の組合せは変わりますが開放ルールは同じです）」と明示する

### 3. テキスト出力（`Format-SgDiffText`）／ HTML 出力（`New-SgReportHtml`）

同じ実効ルール差分セクションを両出力にも追加し、画面・エクスポートの表示を一致させる。
HTML は既存の差分テーブルのスタイル（added/removed クラス）を踏襲する。

## エラー処理・エッジケース

- インスタンス未選択: 既存どおり「インスタンスを選択してください。」
- 変更なし（SG 組合せ自体が同一）: 既存の「SG 差分はありません。」を維持
- SG 組合せは変わるが実効ルールが同じ: 新セクションで「実効ルール差分なし」を表示
- `Protocol` が `all`/`-1`: 既存の `ConvertTo-SgRuleRows` の正規化を踏襲
- メモだけ違うルール: 同一キー扱い（差分に出さない）＝仕様どおり
- Port レンジ: 既存のルール行の `Port` 表記をそのまま使う

## テスト

`tests/AwsManager.Tests.ps1` に `Get-SgRuleDiff` の happy-path を追加する。

- 追加のみ: before に無く after にあるルールが `Added` に出る
- 削除のみ: before にあり after に無いルールが `Removed` に出る
- 相殺: 別 SG 由来でも同一キーなら差分に出ない
- メモ違い: Description だけ異なるルールは差分に出ない
- 重複集約: 同一キーが複数 SG 由来でも `Added`/`Removed` は 1 件

手動確認: アプリを起動し Tab2 で SG を入替え、パネル・テキスト・HTML の 3 表示が一致することを確認する。

## 影響範囲

- `AwsManager.psm1`: `Get-SgRuleDiff` 追加、`Export-ModuleMember` に追記
- `App.ps1`: `Get-SgDiffData`（フィールド追加）、`Render-SgDiffPanel`、`Format-SgDiffText`、`New-SgReportHtml`、実効差分キー関数の追加
- `tests/AwsManager.Tests.ps1`: テスト追加
- `CHANGELOG.md`: `[Unreleased]` に機能追加を記載
