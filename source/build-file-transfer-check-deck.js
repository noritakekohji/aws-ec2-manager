/**
 * file-transfer-check お客様向け実施手順書 (PowerPoint) 生成スクリプト
 *
 * 実行:
 *   NODE_PATH=<pptxgenjs のある node_modules> node source/build-file-transfer-check-deck.js
 *
 * 出力: output/file-transfer-check-手順.pptx
 */
const path = require('path');
const fs = require('fs');
const pptxgen = require('pptxgenjs');

// ---- パレット (Teal Trust ベース: 接続性・検証の主題に合わせた配色) ----
const TEAL = '028090'; // 主色
const MINT = '00A896'; // 補助
const DEEP = '0B3C4A'; // 濃色背景
const INK = '1A2E35'; // 本文
const MUTED = '5B7480'; // 補足
const LIGHT = 'F1F7F8'; // カード背景
const WHITE = 'FFFFFF';
const AMBER = 'C77700'; // 注意
const RED = 'B3261E'; // NG

const JP = 'Meiryo';
const MONO = 'Consolas';

const pres = new pptxgen();
pres.layout = 'LAYOUT_WIDE'; // 13.3 x 7.5
pres.author = 'Noritake Kohji';
pres.title = 'ファイル転送 疎通確認手順';

// 影は使い回すと pptxgenjs が破壊するので毎回新規生成する
const cardShadow = () => ({ type: 'outer', color: '9BB2BA', blur: 10, offset: 2, angle: 90, opacity: 0.35 });

/** 見出し + 任意のリード文 */
function heading(slide, title, lead) {
  slide.addText(title, {
    x: 0.6, y: 0.42, w: 12.1, h: 0.66,
    fontFace: JP, fontSize: 32, bold: true, color: INK, margin: 0,
  });
  if (lead) {
    slide.addText(lead, {
      x: 0.6, y: 1.14, w: 12.1, h: 0.42,
      fontFace: JP, fontSize: 14, color: MUTED, margin: 0,
    });
  }
}

/** STEP バッジ付き見出し (資料全体の視覚モチーフ) */
function stepHeading(slide, num, title, lead) {
  slide.addShape(pres.ShapeType.ellipse, {
    x: 0.6, y: 0.42, w: 0.66, h: 0.66, fill: { color: TEAL },
  });
  slide.addText(String(num), {
    x: 0.6, y: 0.42, w: 0.66, h: 0.66,
    fontFace: JP, fontSize: 20, bold: true, color: WHITE,
    align: 'center', valign: 'middle', margin: 0,
  });
  slide.addText(title, {
    x: 1.42, y: 0.42, w: 11.3, h: 0.66,
    fontFace: JP, fontSize: 32, bold: true, color: INK, valign: 'middle', margin: 0,
  });
  if (lead) {
    slide.addText(lead, {
      x: 1.42, y: 1.16, w: 11.3, h: 0.4,
      fontFace: JP, fontSize: 14, color: MUTED, margin: 0,
    });
  }
}

/** 黒背景のコンソール風ボックス */
function console_(slide, x, y, w, h, lines) {
  slide.addShape(pres.ShapeType.roundRect, {
    x, y, w, h, rectRadius: 0.06, fill: { color: '10262E' }, shadow: cardShadow(),
  });
  slide.addText(lines, {
    x: x + 0.22, y: y + 0.18, w: w - 0.44, h: h - 0.36,
    fontFace: MONO, fontSize: 11.5, color: 'DCEAEE', margin: 0, lineSpacing: 17,
  });
}

// =====================================================================
// 1. タイトル
// =====================================================================
{
  const s = pres.addSlide();
  s.background = { color: DEEP };

  // 装飾: 往復転送を示す同心リング
  s.addShape(pres.ShapeType.ellipse, {
    x: 9.55, y: 1.15, w: 3.5, h: 3.5, fill: { color: DEEP }, line: { color: TEAL, width: 1.5 },
  });
  s.addShape(pres.ShapeType.ellipse, {
    x: 10.15, y: 1.75, w: 2.3, h: 2.3, fill: { color: DEEP }, line: { color: MINT, width: 1.5 },
  });
  s.addShape(pres.ShapeType.ellipse, {
    x: 10.95, y: 2.55, w: 0.7, h: 0.7, fill: { color: MINT },
  });

  s.addText('ファイル転送 疎通確認手順', {
    x: 0.9, y: 2.25, w: 8.4, h: 0.9,
    fontFace: JP, fontSize: 40, bold: true, color: WHITE, margin: 0,
  });
  s.addText('お客様の端末から、サーバの共有フォルダへ\nファイルを送受信できるかを確認します', {
    x: 0.9, y: 3.3, w: 8.4, h: 1.0,
    fontFace: JP, fontSize: 17, color: 'BFE0E4', lineSpacing: 28, margin: 0,
  });

  s.addShape(pres.ShapeType.roundRect, {
    x: 0.9, y: 4.75, w: 5.5, h: 0.62, rectRadius: 0.31, fill: { color: '17505F' },
  });
  s.addText('所要時間 約10分  /  専門知識は不要です', {
    x: 0.9, y: 4.75, w: 5.5, h: 0.62,
    fontFace: JP, fontSize: 13, color: WHITE, align: 'center', valign: 'middle', margin: 0,
  });

  s.addText('File Transfer Check (SMB)', {
    x: 0.9, y: 6.35, w: 6.0, h: 0.35,
    fontFace: JP, fontSize: 11, color: '7FA8B0', margin: 0,
  });
  s.addNotes('お客様に実施いただく、共有フォルダへのファイル転送疎通確認の手順書です。実際にテストファイルを送って受け取り、壊れていないかまで確認します。');
}

// =====================================================================
// 2. このツールで確認できること
// =====================================================================
{
  const s = pres.addSlide();
  heading(s, 'この確認で分かること', 'テスト用のファイルを実際に送って受け取り、3つの観点で確認します');

  const cards = [
    { t: '送れるか', d: 'サーバの共有フォルダに\nファイルを書き込めるか', mark: '↑' },
    { t: '受け取れるか', d: '書き込んだファイルを\n読み戻せるか', mark: '↓' },
    { t: '壊れていないか', d: '送る前と後で中身が\n完全に同じか照合します', mark: '=' },
  ];
  cards.forEach((c, i) => {
    const x = 0.6 + i * 4.13;
    s.addShape(pres.ShapeType.roundRect, {
      x, y: 2.05, w: 3.83, h: 3.2, rectRadius: 0.1, fill: { color: LIGHT }, shadow: cardShadow(),
    });
    s.addShape(pres.ShapeType.ellipse, {
      x: x + 0.35, y: 2.45, w: 0.85, h: 0.85, fill: { color: TEAL },
    });
    s.addText(c.mark, {
      x: x + 0.35, y: 2.45, w: 0.85, h: 0.85,
      fontFace: JP, fontSize: 26, bold: true, color: WHITE, align: 'center', valign: 'middle', margin: 0,
    });
    s.addText(c.t, {
      x: x + 0.35, y: 3.55, w: 3.1, h: 0.45,
      fontFace: JP, fontSize: 19, bold: true, color: INK, margin: 0,
    });
    s.addText(c.d, {
      x: x + 0.35, y: 4.1, w: 3.2, h: 0.9,
      fontFace: JP, fontSize: 13, color: MUTED, lineSpacing: 21, margin: 0,
    });
  });

  s.addShape(pres.ShapeType.roundRect, {
    x: 0.6, y: 5.65, w: 12.1, h: 1.25, rectRadius: 0.1, fill: { color: 'E4F2F1' },
  });
  s.addText([
    { text: 'あわせて転送の速さ（スピード）も測定します。', options: { bold: true, breakLine: true } },
    { text: '結果は画面に表示され、ログファイルにも自動で記録されます。ご担当者へその記録をお送りいただきます。', options: {} },
  ], {
    x: 0.95, y: 5.65, w: 11.4, h: 1.25,
    fontFace: JP, fontSize: 13.5, color: INK, lineSpacing: 23, valign: 'middle', margin: 0,
  });
  s.addNotes('往復転送し、SHA-256 ハッシュで整合性まで確認する点がポイントです。');
}

// =====================================================================
// 3. 全体の流れ
// =====================================================================
{
  const s = pres.addSlide();
  heading(s, '全体の流れ', '4つのステップで完了します');

  const steps = [
    { n: '1', t: 'フォルダを\n受け取る', d: 'ご担当者から\n一式を受領' },
    { n: '2', t: '端末に\nコピー', d: 'デスクトップ等\nに置く' },
    { n: '3', t: '実行する', d: 'ファイルを\nダブルクリック' },
    { n: '4', t: '結果を\n送る', d: 'ログを\nご担当者へ' },
  ];
  steps.forEach((st, i) => {
    const x = 0.6 + i * 3.16;
    s.addShape(pres.ShapeType.roundRect, {
      x, y: 2.25, w: 2.75, h: 3.55, rectRadius: 0.1,
      fill: { color: WHITE }, line: { color: 'CFE2E5', width: 1 }, shadow: cardShadow(),
    });
    s.addShape(pres.ShapeType.ellipse, {
      x: x + 1.0, y: 2.65, w: 0.75, h: 0.75, fill: { color: i === 2 ? MINT : TEAL },
    });
    s.addText(st.n, {
      x: x + 1.0, y: 2.65, w: 0.75, h: 0.75,
      fontFace: JP, fontSize: 21, bold: true, color: WHITE, align: 'center', valign: 'middle', margin: 0,
    });
    s.addText(st.t, {
      x: x + 0.15, y: 3.65, w: 2.45, h: 0.8,
      fontFace: JP, fontSize: 16, bold: true, color: INK, align: 'center', lineSpacing: 23, margin: 0,
    });
    s.addText(st.d, {
      x: x + 0.15, y: 4.62, w: 2.45, h: 0.75,
      fontFace: JP, fontSize: 12, color: MUTED, align: 'center', lineSpacing: 19, margin: 0,
    });
    if (i < 3) {
      s.addShape(pres.ShapeType.rightArrow, {
        x: x + 2.83, y: 3.85, w: 0.3, h: 0.28, fill: { color: '9FC4CA' },
      });
    }
  });

  s.addText('※ サーバへ接続するための情報（共有フォルダの場所・ユーザー名）は、事前にご担当者が設定します。', {
    x: 0.6, y: 6.2, w: 12.1, h: 0.4,
    fontFace: JP, fontSize: 12.5, color: MUTED, margin: 0,
  });
  s.addNotes('お客様の作業は実質ステップ2〜4のみ。設定は運用者側が事前に済ませます。');
}

// =====================================================================
// 4. 事前のご確認
// =====================================================================
{
  const s = pres.addSlide();
  heading(s, '事前のご確認', '作業を始める前に、次の2点をご確認ください');

  const cols = [
    {
      t: 'ご用意いただくもの',
      items: [
        '確認を行う端末（普段お使いのPC）',
        'その端末が社内ネットワークに接続されていること',
        'ご担当者から受け取ったフォルダ一式',
      ],
    },
    {
      t: 'ご確認いただきたいこと',
      items: [
        '確認対象のサーバ名・共有フォルダ名',
        '接続に専用のユーザー名を使うかどうか',
        '（使う場合）そのパスワード',
      ],
    },
  ];
  cols.forEach((c, i) => {
    const x = 0.6 + i * 6.25;
    s.addShape(pres.ShapeType.roundRect, {
      x, y: 2.05, w: 5.85, h: 3.5, rectRadius: 0.1, fill: { color: LIGHT }, shadow: cardShadow(),
    });
    s.addShape(pres.ShapeType.ellipse, {
      x: x + 0.35, y: 2.4, w: 0.52, h: 0.52, fill: { color: TEAL },
    });
    s.addText(String(i + 1), {
      x: x + 0.35, y: 2.4, w: 0.52, h: 0.52,
      fontFace: JP, fontSize: 15, bold: true, color: WHITE, align: 'center', valign: 'middle', margin: 0,
    });
    s.addText(c.t, {
      x: x + 1.0, y: 2.4, w: 4.6, h: 0.52,
      fontFace: JP, fontSize: 18, bold: true, color: INK, valign: 'middle', margin: 0,
    });
    s.addText(
      c.items.map((it, j) => ({
        text: it,
        options: { bullet: true, breakLine: j !== c.items.length - 1 },
      })),
      {
        x: x + 0.45, y: 3.2, w: 5.1, h: 2.1,
        fontFace: JP, fontSize: 13.5, color: INK, lineSpacing: 22, paraSpaceAfter: 13, margin: 0,
      }
    );
  });

  s.addShape(pres.ShapeType.roundRect, {
    x: 0.6, y: 5.9, w: 12.1, h: 1.0, rectRadius: 0.1, fill: { color: 'FDF3E0' },
  });
  s.addText('パスワードは、この資料やファイルに書かないでください。実行中に画面で一度だけ入力していただきます。', {
    x: 0.95, y: 5.9, w: 11.4, h: 1.0,
    fontFace: JP, fontSize: 13.5, bold: true, color: AMBER, valign: 'middle', margin: 0,
  });
  s.addNotes('パスワードは実行時入力のみ。リストにも資料にも記載しない運用です。');
}

// =====================================================================
// 5. STEP 1 フォルダをコピー
// =====================================================================
{
  const s = pres.addSlide();
  stepHeading(s, 1, 'フォルダを端末にコピーする', '受け取ったフォルダを、そのまま端末に置いてください');

  s.addText(
    [
      { text: '受け取ったフォルダ一式を、デスクトップなど分かりやすい場所にコピーします。', options: { bullet: true, breakLine: true } },
      { text: 'フォルダの中身は変更しないでください（ファイルを消したり名前を変えたりしない）。', options: { bullet: true, breakLine: true } },
      { text: 'ネットワークドライブ上ではなく、端末内にコピーしてください。', options: { bullet: true } },
    ],
    { x: 0.6, y: 2.05, w: 6.6, h: 2.3, fontFace: JP, fontSize: 14.5, color: INK, lineSpacing: 26, paraSpaceAfter: 16, margin: 0 }
  );

  // フォルダ構成の見た目
  s.addShape(pres.ShapeType.roundRect, {
    x: 7.5, y: 2.0, w: 5.2, h: 3.85, rectRadius: 0.1,
    fill: { color: WHITE }, line: { color: 'CFE2E5', width: 1 }, shadow: cardShadow(),
  });
  s.addText('フォルダの中身', {
    x: 7.85, y: 2.25, w: 4.5, h: 0.35,
    fontFace: JP, fontSize: 13, bold: true, color: TEAL, margin: 0,
  });
  s.addText(
    [
      { text: 'file-transfer-check', options: { bold: true, breakLine: true } },
      { text: '  Check-FileTransfer.bat', options: { breakLine: true, color: TEAL, bold: true } },
      { text: '  Check-FileTransfer.ps1', options: { breakLine: true } },
      { text: '  check_file_transfer.sh', options: { breakLine: true } },
      { text: '  shares.lst', options: { breakLine: true } },
      { text: '  README.md', options: {} },
    ],
    { x: 7.85, y: 2.78, w: 4.5, h: 2.5, fontFace: MONO, fontSize: 12.5, color: INK, lineSpacing: 23, margin: 0 }
  );
  s.addText('青色のファイルを次のステップで使います', {
    x: 7.85, y: 5.32, w: 4.5, h: 0.3,
    fontFace: JP, fontSize: 11.5, color: MUTED, margin: 0,
  });

  s.addShape(pres.ShapeType.roundRect, {
    x: 0.6, y: 4.75, w: 6.6, h: 1.1, rectRadius: 0.1, fill: { color: 'E4F2F1' },
  });
  s.addText('コピーするだけで動きます。インストール作業は必要ありません。', {
    x: 0.95, y: 4.75, w: 6.0, h: 1.1,
    fontFace: JP, fontSize: 13.5, bold: true, color: INK, valign: 'middle', margin: 0,
  });
  s.addNotes('自己完結型。フォルダ一式のコピーのみで動作します。');
}

// =====================================================================
// 6. STEP 2 実行する (Windows)
// =====================================================================
{
  const s = pres.addSlide();
  stepHeading(s, 2, '実行する', 'ファイルをダブルクリックするだけです');

  s.addText(
    [
      { text: 'Check-FileTransfer.bat', options: { bold: true, fontFace: MONO, breakLine: true } },
      { text: '上のファイルをダブルクリックしてください。黒い画面が開き、確認が始まります。', options: { breakLine: true } },
      { text: '', options: { breakLine: true } },
      { text: '専用ユーザーを使う設定の場合のみ、パスワードの入力を求められます。', options: { breakLine: true } },
      { text: '入力しても画面には表示されませんが、正しく入力されています。', options: { color: MUTED } },
    ],
    { x: 0.6, y: 2.05, w: 6.0, h: 2.8, fontFace: JP, fontSize: 14, color: INK, lineSpacing: 26, margin: 0 }
  );

  console_(s, 6.9, 2.0, 5.8, 3.2, [
    { text: '================================', options: { breakLine: true, color: '6E9AA3' } },
    { text: ' File Transfer Check (SMB)', options: { breakLine: true, color: WHITE, bold: true } },
    { text: '================================', options: { breakLine: true, color: '6E9AA3' } },
    { text: '', options: { breakLine: true } },
    { text: 'Running...', options: { breakLine: true } },
    { text: '', options: { breakLine: true } },
    { text: 'パスワードを入力してください', options: { color: '7FD1C4' } },
  ]);

  s.addShape(pres.ShapeType.roundRect, {
    x: 0.6, y: 5.55, w: 12.1, h: 1.35, rectRadius: 0.1, fill: { color: 'FDF3E0' },
  });
  s.addText([
    { text: '画面が出てこない / すぐ閉じてしまう場合', options: { bold: true, breakLine: true, color: AMBER } },
    { text: 'フォルダごとコピーされているかご確認ください。bat ファイルだけを取り出すと動作しません。', options: { color: INK } },
  ], {
    x: 0.95, y: 5.55, w: 11.4, h: 1.35,
    fontFace: JP, fontSize: 13.5, lineSpacing: 23, valign: 'middle', margin: 0,
  });
  s.addNotes('bat は同フォルダの ps1 と shares.lst を参照するため、フォルダ一式が必要です。');
}

// =====================================================================
// 7. STEP 3 結果の見方
// =====================================================================
{
  const s = pres.addSlide();
  stepHeading(s, 3, '結果を確認する', '共有フォルダごとに結果が表示されます');

  console_(s, 0.6, 2.05, 7.0, 3.35, [
    { text: '[SHARE] \\\\filesv01\\upload  (業務ファイル受け渡し共有)', options: { breakLine: true, color: WHITE } },
    { text: '  Auth    : integrated (current user)', options: { breakLine: true } },
    { text: '  Upload  : OK   8.3 MB/s', options: { breakLine: true, color: '7FD1C4' } },
    { text: '  Download: OK   11.1 MB/s', options: { breakLine: true, color: '7FD1C4' } },
    { text: '  Verify  : OK   (SHA-256 一致)', options: { breakLine: true, color: '7FD1C4' } },
    { text: '  Result  : OK   expected=ok', options: { breakLine: true, color: '7FD1C4', bold: true } },
    { text: '', options: { breakLine: true } },
    { text: '--------------------------------------------', options: { breakLine: true, color: '6E9AA3' } },
    { text: '  Shares: 2   OK: 2   NG: 0   Warning: 0', options: { color: WHITE, bold: true } },
  ]);

  const marks = [
    { k: 'OK', c: MINT, d: '問題ありません' },
    { k: 'NG', c: RED, d: '転送できていません\nご担当者へご連絡ください' },
    { k: 'WARNING', c: AMBER, d: '一部確認が必要です\n記録をお送りください' },
  ];
  s.addText('表示の意味', {
    x: 7.85, y: 2.05, w: 4.85, h: 0.35,
    fontFace: JP, fontSize: 16, bold: true, color: INK, margin: 0,
  });
  marks.forEach((m, i) => {
    const y = 2.6 + i * 0.98;
    s.addShape(pres.ShapeType.roundRect, {
      x: 7.85, y, w: 1.28, h: 0.46, rectRadius: 0.23, fill: { color: m.c },
    });
    s.addText(m.k, {
      x: 7.85, y, w: 1.28, h: 0.46,
      fontFace: JP, fontSize: 11.5, bold: true, color: WHITE, align: 'center', valign: 'middle', margin: 0,
    });
    s.addText(m.d, {
      x: 9.28, y: y - 0.12, w: 3.42, h: 0.7,
      fontFace: JP, fontSize: 12, color: INK, valign: 'middle', lineSpacing: 17, margin: 0,
    });
  });

  s.addText('最後の行に合計が出ます。\nNG が 0 件なら問題ありません。', {
    x: 7.85, y: 5.55, w: 4.85, h: 0.7,
    fontFace: JP, fontSize: 12, color: MUTED, lineSpacing: 18, margin: 0,
  });

  s.addShape(pres.ShapeType.roundRect, {
    x: 0.6, y: 5.65, w: 7.0, h: 1.25, rectRadius: 0.1, fill: { color: 'E4F2F1' },
  });
  s.addText('NG が出ても、お客様の操作ミスではありません。ネットワークや権限の設定を確認するための情報です。', {
    x: 0.95, y: 5.65, w: 6.35, h: 1.25,
    fontFace: JP, fontSize: 13, color: INK, valign: 'middle', lineSpacing: 21, margin: 0,
  });
  s.addNotes('NG=期待どおり転送できなかった、の意味。お客様を不安にさせないよう補足しています。');
}

// =====================================================================
// 8. STEP 4 結果を送る
// =====================================================================
{
  const s = pres.addSlide();
  stepHeading(s, 4, '結果をご担当者へ送る', '自動で作られる記録ファイルをお送りください');

  const files = [
    {
      t: 'ログファイル（必須）',
      n: 'Check-FileTransfer_<日時>.log',
      d: 'bat と同じフォルダに自動で作られます。\n画面に出た内容がそのまま入っています。',
      c: TEAL,
    },
    {
      t: 'HTML レポート（設定時のみ）',
      n: 'report.html',
      d: '設定されている場合のみ作られます。\nブラウザで開くと表形式で確認できます。',
      c: MINT,
    },
  ];
  files.forEach((f, i) => {
    const x = 0.6 + i * 6.25;
    s.addShape(pres.ShapeType.roundRect, {
      x, y: 2.05, w: 5.85, h: 3.25, rectRadius: 0.1, fill: { color: LIGHT }, shadow: cardShadow(),
    });
    s.addShape(pres.ShapeType.roundRect, {
      x: x + 0.35, y: 2.4, w: 0.52, h: 0.62, rectRadius: 0.06, fill: { color: f.c },
    });
    s.addText(f.t, {
      x: x + 1.02, y: 2.4, w: 4.6, h: 0.62,
      fontFace: JP, fontSize: 16, bold: true, color: INK, valign: 'middle', margin: 0,
    });
    s.addText(f.n, {
      x: x + 0.35, y: 3.3, w: 5.15, h: 0.38,
      fontFace: MONO, fontSize: 12.5, color: TEAL, bold: true, margin: 0,
    });
    s.addText(f.d, {
      x: x + 0.35, y: 3.85, w: 5.15, h: 1.05,
      fontFace: JP, fontSize: 13, color: MUTED, lineSpacing: 22, margin: 0,
    });
  });

  s.addShape(pres.ShapeType.roundRect, {
    x: 0.6, y: 5.65, w: 12.1, h: 1.25, rectRadius: 0.1, fill: { color: 'E4F2F1' },
  });
  s.addText([
    { text: 'これらのファイルにパスワードは含まれません。', options: { bold: true, breakLine: true } },
    { text: 'そのままメール等でお送りいただいて問題ありません。', options: {} },
  ], {
    x: 0.95, y: 5.65, w: 11.4, h: 1.25,
    fontFace: JP, fontSize: 13.5, color: INK, lineSpacing: 23, valign: 'middle', margin: 0,
  });
  s.addNotes('ログ・HTML ともパスワードは出力しない設計です。');
}

// =====================================================================
// 9. うまくいかないときは
// =====================================================================
{
  const s = pres.addSlide();
  heading(s, 'うまくいかないときは', '次の内容をご担当者にお伝えいただくと、原因が早く分かります');

  const rows = [
    { m: '画面がすぐ閉じる', d: 'フォルダ一式がコピーされているかご確認ください' },
    { m: 'ファイルが見つからない旨の表示', d: '共有フォルダの設定ファイルが不足しています' },
    { m: 'すべて NG になる', d: 'ネットワーク接続・接続先の指定をご確認ください' },
    { m: 'パスワードを聞かれ続ける', d: 'ユーザー名またはパスワードが誤っている可能性があります' },
  ];
  rows.forEach((r, i) => {
    const y = 2.05 + i * 1.02;
    s.addShape(pres.ShapeType.roundRect, {
      x: 0.6, y, w: 12.1, h: 0.86, rectRadius: 0.08,
      fill: { color: i % 2 === 0 ? LIGHT : WHITE }, line: { color: 'DCE9EB', width: 1 },
    });
    s.addShape(pres.ShapeType.ellipse, {
      x: 0.95, y: y + 0.24, w: 0.38, h: 0.38, fill: { color: TEAL },
    });
    s.addText('?', {
      x: 0.95, y: y + 0.24, w: 0.38, h: 0.38,
      fontFace: JP, fontSize: 13, bold: true, color: WHITE, align: 'center', valign: 'middle', margin: 0,
    });
    s.addText(r.m, {
      x: 1.5, y, w: 4.3, h: 0.86,
      fontFace: JP, fontSize: 13.5, bold: true, color: INK, valign: 'middle', margin: 0,
    });
    s.addText(r.d, {
      x: 5.95, y, w: 6.5, h: 0.86,
      fontFace: JP, fontSize: 13, color: MUTED, valign: 'middle', margin: 0,
    });
  });

  s.addShape(pres.ShapeType.roundRect, {
    x: 0.6, y: 6.15, w: 12.1, h: 0.9, rectRadius: 0.1, fill: { color: 'E4F2F1' },
  });
  s.addText('解決しない場合は、記録ファイル（.log）を添えてご担当者へご連絡ください。', {
    x: 0.95, y: 6.15, w: 11.4, h: 0.9,
    fontFace: JP, fontSize: 13.5, bold: true, color: INK, valign: 'middle', margin: 0,
  });
  s.addNotes('お客様には終了コードの詳細は伝えず、症状ベースで案内しています。');
}

// =====================================================================
// 10. 安全性について
// =====================================================================
{
  const s = pres.addSlide();
  heading(s, '安全性について', 'お客様の環境に変更を加えることはありません');

  const items = [
    { t: 'パスワードは保存しません', d: '入力されたパスワードは確認中のみ使用し、\nファイルや記録には一切残りません。' },
    { t: 'テストファイルは自動で消えます', d: '確認用に送ったファイルは、確認後すぐに\n自動で削除されます。' },
    { t: '既存のファイルは触りません', d: '共有フォルダにある業務ファイルの\n読み書き・削除は行いません。' },
    { t: 'インストールしません', d: '端末に何かを導入したり、設定を\n変更したりすることはありません。' },
  ];
  items.forEach((it, i) => {
    const x = 0.6 + (i % 2) * 6.25;
    const y = 2.05 + Math.floor(i / 2) * 2.4;
    s.addShape(pres.ShapeType.roundRect, {
      x, y, w: 5.85, h: 2.1, rectRadius: 0.1, fill: { color: LIGHT }, shadow: cardShadow(),
    });
    s.addShape(pres.ShapeType.ellipse, {
      x: x + 0.35, y: y + 0.35, w: 0.52, h: 0.52, fill: { color: MINT },
    });
    s.addText('✓', {
      x: x + 0.35, y: y + 0.35, w: 0.52, h: 0.52,
      fontFace: JP, fontSize: 14, bold: true, color: WHITE, align: 'center', valign: 'middle', margin: 0,
    });
    s.addText(it.t, {
      x: x + 1.0, y: y + 0.33, w: 4.6, h: 0.55,
      fontFace: JP, fontSize: 15.5, bold: true, color: INK, valign: 'middle', margin: 0,
    });
    s.addText(it.d, {
      x: x + 1.0, y: y + 1.02, w: 4.65, h: 0.85,
      fontFace: JP, fontSize: 12.5, color: MUTED, lineSpacing: 20, margin: 0,
    });
  });
  s.addNotes('お客様の不安（勝手に何かされるのでは）を先回りして解消するページです。');
}

// =====================================================================
// 11. まとめ
// =====================================================================
{
  const s = pres.addSlide();
  s.background = { color: DEEP };

  s.addText('ご協力ありがとうございます', {
    x: 0.9, y: 1.55, w: 11.5, h: 0.85,
    fontFace: JP, fontSize: 34, bold: true, color: WHITE, margin: 0,
  });
  s.addText('お客様に実施いただくのは、次の3つだけです', {
    x: 0.9, y: 2.55, w: 11.5, h: 0.45,
    fontFace: JP, fontSize: 15, color: 'BFE0E4', margin: 0,
  });

  const recap = ['フォルダを端末にコピー', 'bat をダブルクリック', '記録ファイルを送付'];
  recap.forEach((r, i) => {
    const x = 0.9 + i * 3.95;
    s.addShape(pres.ShapeType.roundRect, {
      x, y: 3.4, w: 3.6, h: 1.85, rectRadius: 0.1, fill: { color: '17505F' },
    });
    s.addShape(pres.ShapeType.ellipse, {
      x: x + 0.35, y: 3.75, w: 0.6, h: 0.6, fill: { color: MINT },
    });
    s.addText(String(i + 1), {
      x: x + 0.35, y: 3.75, w: 0.6, h: 0.6,
      fontFace: JP, fontSize: 16, bold: true, color: DEEP, align: 'center', valign: 'middle', margin: 0,
    });
    s.addText(r, {
      x: x + 0.35, y: 4.55, w: 3.0, h: 0.5,
      fontFace: JP, fontSize: 13.5, bold: true, color: WHITE, valign: 'middle', margin: 0,
    });
  });

  s.addText('ご不明な点は、担当者までお気軽にお問い合わせください。', {
    x: 0.9, y: 5.95, w: 11.5, h: 0.45,
    fontFace: JP, fontSize: 14, color: 'BFE0E4', margin: 0,
  });
  s.addNotes('最後にお客様の作業を3点に要約して安心してもらう構成です。');
}

// ---- 出力 ----
const outDir = path.join(__dirname, '..', 'output');
if (!fs.existsSync(outDir)) fs.mkdirSync(outDir, { recursive: true });
const outFile = path.join(outDir, 'file-transfer-check-手順.pptx');
pres.writeFile({ fileName: outFile }).then(() => {
  console.log('written: ' + outFile);
});
