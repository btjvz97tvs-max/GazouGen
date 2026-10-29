# 画像生成（iPhone 単体版）

iPhone の中だけで画像を生成するアプリです。Apple の Core ML 版 Stable Diffusion を使っていて、通信は不要です。

- 生成／履歴／キャラ／モデル の4タブ
- SDXL と SD1.5 系の Core ML モデルに対応
- R18 モード：オンにすると成人向け表現を抑えるネガティブを外します（未成年を指す語や18歳未満の年齢指定があると生成しません）

---

## 1. アプリをビルドする（GitHub、iPhone からでも可）

1. GitHub アカウントを作る
2. 新しいリポジトリを作り（Private 推奨）、このフォルダの中身をすべてアップロード
   - `.github/workflows/build.yml` も必ず含める（隠しフォルダなので注意）
3. リポジトリの「Actions」タブ → 「Build IPA」→「Run workflow」
4. 10〜20分ほどで完了。完了した実行を開き、下の Artifacts から `GazouGen-ipa` をダウンロード（中に `GazouGen.ipa`）

## 2. iPhone に入れる（Windows PC が必要）

1. Windows に **iTunes（Microsoft Store版ではなく Apple サイト版）** と **Sideloadly** を入れる
2. iPhone をケーブルでつなぎ、Sideloadly に `GazouGen.ipa` をドラッグ
3. Apple ID を入力して Start
4. iPhone の「設定 > 一般 > VPNとデバイス管理」で自分の Apple ID を信頼
5. iOS 16 以降は「設定 > プライバシーとセキュリティ > デベロッパモード」をオンにして再起動

無料の Apple ID だと **7日ごとに入れ直し**が必要です（Sideloadly で同じ操作をするだけ。データは残ります）。

## 3. モデルを入れる

このアプリは **Core ML 形式**のモデルが必要です（Civitai などの `.safetensors` はそのままでは使えません）。

1. Hugging Face で「coreml」「split_einsum」「compiled」付きのモデルを探してダウンロード
   - iPhone では **split_einsum 版**を選ぶ（original 版は遅い／動かない）
   - SDXL は「ios」向けに圧縮（palettized）されたものがおすすめ
2. 「ファイル」アプリで zip をタップして解凍
3. アプリの「モデル」タブ →「フォルダから追加」で解凍したフォルダを選ぶ
   （または「ファイル」アプリで このiPhone内 > 画像生成 > Models に直接移動）

`.mlmodelc` が入ったフォルダならOKです。

## 使い方のコツ

- 初回のモデル読み込みは数分かかります（2回目以降は速い）
- 画像サイズはモデルで決まります（SDXL は 1024px、SD1.5 は 512px が多い）
- プロンプトは英語タグ推奨。長すぎると後ろが切り捨てられます（約75トークン）
- 目安：ステップ 20〜30、CFG 5〜7、DPM++
- 生成中は発熱します。連続生成は枚数を控えめに

## うまくいかないとき

- **読み込み中に落ちる**：メモリ不足です。palettized（6bit など）の軽いモデルにする
- **真っ黒／ぼやけた画像**：SD1.5 で元モデルに安全フィルタが入っている場合があります。R18 モードをオンにすると無効になります
- **モデルが一覧に出ない**：フォルダ内に `TextEncoder.mlmodelc` と `Unet.mlmodelc`（または `UnetChunk1.mlmodelc`）があるか確認
- **Actions のビルドが失敗**：エラーログをそのまま貼ってもらえれば直します
