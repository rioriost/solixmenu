# Plan for v1.0.9: 終了・クラッシュ調査用ログ追加

## Background
- アプリが「いつの間にか終了している」事象がある。
- 直前ログには MQTT の `connection closed` / `connect failed (disconnect)` が見えるが、現状コード上はそれ自体が明示的な終了処理には直結していない。
- 再現条件が不明なため、まずは終了直前の状況を特定できるよう観測性を上げる。

## Goal
- アプリ終了前後、MQTT切断前後、主要な非同期タスクの開始/終了/失敗がログから追える。
- 次回発生時に「正常終了」「ユーザー操作による終了」「クラッシュ直前の異常挙動」の切り分け材料が残る。

## Phase 1: アプリライフサイクルの観測強化
### Task 1.1
- `SolixMenuApp` に起動・終了・再オープン関連のログを追加する。
- `applicationDidFinishLaunching`
- `applicationWillTerminate`
- 必要に応じて追加可能なアプリイベント入口

### Task 1.2
- 終了要求の入口に識別ログを追加する。
- メニューの Quit 選択
- 明示的な `terminate` 呼び出しの直前

### Acceptance
- 「アプリが正常終了した」のか「突然消えた」のかをログ有無で判定できる。

## Phase 2: Coordinator の状態遷移とタスク寿命の可視化
### Task 2.1
- `SolixAppCoordinator` の主要メソッド入口/出口にログを追加する。
- `start`
- `start(with:)`
- `stop`
- `refreshDevices`
- `connectMqttIfNeeded`
- `configureMqttMonitor`

### Task 2.2
- 非同期タスクの生成・キャンセル・終了理由を記録する。
- polling task
- mqtt task
- realtime trigger task

### Task 2.3
- 例外やキャンセル時に、どのループ/タスクで起きたか分かるログを追加する。

### Acceptance
- 終了前に coordinator が `stop` へ遷移したのか、タスクだけ死んだのかを追跡できる。

## Phase 3: MQTT セッション異常時の文脈ログ追加
### Task 3.1
- `MqttSession` の connect/disconnect 周辺に文脈ログを追加する。
- 接続試行開始
- 接続成功
- 接続失敗理由
- close listener 発火時の接続状態
- cooldown 設定値
- client 再生成有無

### Task 3.2
- publish / subscribe / cleanup / timeout の前後に要約ログを追加する。
- queued subscribe 数
- active subscriptions 数
- cleanup 開始/完了
- connect timeout 発生

### Task 3.3
- disconnect 後に後続処理が継続しているかを追えるログを追加する。

### Acceptance
- MQTT切断が単独イベントなのか、その後の不整合の引き金なのかを時系列で判断できる。

## Phase 4: UI 更新・状態更新まわりの異常観測
### Task 4.1
- `SolixAppState` の更新箇所に軽量ログを追加する。
- device 件数変化
- 特定 device の IN/OUT/battery 更新
- 全消去

### Task 4.2
- `StatusBarController` のメニュー更新・Quit ハンドラにログを追加する。

### Acceptance
- UI 更新停止とプロセス終了の前後関係を判定できる。

## Phase 5: ログ量の制御
### Task 5.1
- ログは要約中心にし、毎秒大量出力を避ける。
- 件数
- task id 相当の識別子
- device 数
- 接続状態
- error の要約

### Task 5.2
- 通常運用を壊さない範囲で、クラッシュ調査に必要な情報のみ追加する。
- 秘匿情報は出さない
- payload 全文は避ける
- 差分と状態サマリを優先する

## Verification
- ビルドが通ること。
- 起動時に lifecycle / coordinator / mqtt の初期ログが出ること。
- Quit 操作時に「終了要求」と `applicationWillTerminate` の両方が記録されること。
- MQTT切断時に、切断直前直後の文脈ログが残ること。

## Expected Output
- 終了・クラッシュ調査に必要なログがコードへ追加される。
- 次回現象発生時に、ログだけで少なくとも以下を判別できる。
  - ユーザー操作による正常終了
  - アプリ内 stop による終了
  - MQTT切断のみで継続
  - 終了ログなしの異常終了/クラッシュ疑い