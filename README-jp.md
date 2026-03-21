# SolixMenu

Anker Solix デバイスを監視するための軽量な macOS メニューバーアプリです。

## 特長
- デバイスごとのバッテリー残量と電力情報をメニューバーに表示
- ログイン/ログアウト用のアカウント設定 UI
- About ダイアログ
- 英語/日本語ローカライズ

## 動作要件
- macOS 26 以降
- Apple Silicon (arm64)

## インストール（Homebrew）
```/dev/null/commands.sh#L1-1
brew install --cask rioriost/cask/solixmenu
```

## 使い方
1. アプリを起動します（メニューバーアクセサリとして動作します）。
2. メニューバーのアイコンをクリックしてデバイス状態を確認します。
3. **Account Settings…** からログイン/認証情報の更新を行います。
4. アプリ情報は **About**、終了は **Quit** を使用します。

## ローカライズ
- 日本語 (`ja`) は日本語の文字列を使用します。
- その他のロケールは英語を使用します。

## 制限事項
- Anker Solix の有効な認証情報とネットワーク接続が必要です。
- デバイスの利用可否は Anker Solix API およびアカウントに依存します。
- Anker 公式とは無関係です。

## 謝意
本プロジェクトは以下の Anker Solix API の調査・研究を参照して実装されています。  
https://github.com/thomluther/anker-solix-api  
素晴らしい取り組みに感謝します。

## ライセンス
MIT（`LICENSE` を参照）
