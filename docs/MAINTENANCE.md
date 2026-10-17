# 保守点検記録：1.4.0

確認日：2026年10月17日。対象はデータ閲覧27画面、在庫管理13画面、エクスポート6画面の計46画面です。同じ表示名でも相対パスが異なる画面は別に数えます。

画面幅390pxのChromiumで、46画面すべての検索条件と、元のフォームから検索・抽出した後の表示を確認しました。入れ子のフレームの読み込み完了を待って測定し、表示中の画面の横はみ出しと既知のサーバーエラー表示は0件でした。結合セルや詳細ボタンを含む広い表は、列を保って表内でスクロールします。

日付範囲欄は2026-10-17の1日分、品番欄は提供された品番を指定しました。週次・現在在庫などは画面の集計単位を使用しています。業務データの登録・更新・削除は実施していません。

「該当なし表示」は、今回の条件では明細を確認できなかった画面です。「ファイル取得未確認」は、抽出後の画面までの確認に限ります。全期間・全品番・全条件の組み合わせを網羅したものではありません。メニューに同一URL・同一ハンドラーのインボイス項目が2つあるため、その重複は1画面として数えています。

検索補助画面のチェック式候補一覧も、選択・元の条件への反映まで実サイトで確認しました。日付カレンダーは開いても結果カードに変換されず、画面幅に収まります。販売CSVは実ファイルの取得を確認し、検証後に作業環境から削除しました。

## データ閲覧（27画面）

| No. | メニュー | 相対パス | 条件画面 | 検索・抽出結果 |
| --- | --- | --- | --- | --- |
| 1 | レシートデータ閲覧 | `/scripts/verona/print/prtz020_1.asp` | 確認済み | 該当なし表示を確認 |
| 2 | 売上日報 | `/scripts/verona/print/prtz030_1.asp` | 確認済み | 結果画面を確認 |
| 3 | アイテム別売上集計レポート | `/scripts/verona/print/prtz060_1.asp` | 確認済み | 結果画面を確認 |
| 4 | ブランド別売上集計レポート | `/scripts/verona/print/prtz070_1.asp` | 確認済み | 結果画面を確認 |
| 5 | 商品別売上集計レポート | `/scripts/verona/print/prtz080_1.asp` | 確認済み | 結果画面を確認 |
| 6 | カテゴリー別売上集計レポート | `/scripts/verona/print/prtz430_1.asp` | 確認済み | 結果画面を確認 |
| 7 | 時間帯別売上レポート | `/scripts/verona/print/prtz090_1.asp` | 確認済み | 結果画面を確認 |
| 8 | 時間帯別曜日別売上レポート | `/scripts/verona/print/prtz440_1.asp` | 確認済み | 結果画面を確認 |
| 9 | 売上ベストレポート | `/scripts/verona/print/prtz100_1.asp` | 確認済み | 結果画面を確認 |
| 10 | 総売上日報 | `/scripts/verona/print/prtz110_1.asp` | 確認済み | 結果画面を確認 |
| 11 | 店舗別売上日計表 | `/scripts/verona/print/prtz120_1.asp` | 確認済み | 結果画面を確認 |
| 12 | 担当者別売上実績表 | `/scripts/verona/print/prtz130_1.asp` | 確認済み | 結果画面を確認 |
| 13 | セット販売ベスト10 | `/scripts/verona/print/prtz140_1.asp` | 確認済み | 該当なし表示を確認 |
| 14 | 品番別売上週次レポート | `/scripts/verona/print/prtz160_1.asp` | 確認済み | 結果画面を確認 |
| 15 | 店舗別売上週次レポート | `/scripts/verona/print/prtz170_1.asp` | 確認済み | 結果画面を確認 |
| 16 | アイテム別売上週次レポート | `/scripts/verona/print/prtz180_1.asp` | 確認済み | 結果画面を確認 |
| 17 | 担当者売上ランキング表 | `/scripts/verona/print/prtz510_1.asp` | 確認済み | 結果画面を確認 |
| 18 | 入出庫実績表 | `/scripts/verona/print/prtz230_1.asp` | 確認済み | 該当なし表示を確認 |
| 19 | 入庫予定表 | `/scripts/verona/print/prtz280_1.asp` | 確認済み | 該当なし表示を確認 |
| 20 | 入庫検品予定実績表 | `/scripts/verona/print/prtz240_1.asp` | 確認済み | 該当なし表示を確認 |
| 21 | 店舗別金種集計表 | `/scripts/verona/print/prtz320_1.asp` | 確認済み | 結果画面を確認 |
| 22 | 日次点検データ閲覧 | `/scripts/verona/print/prtz340_1.asp` | 確認済み | 結果画面を確認 |
| 23 | 取引合計レポート | `/scripts/verona/print/prtz050_1.asp` | 確認済み | 結果画面を確認 |
| 24 | 取置受付一覧表 | `/scripts/verona/print/prtz380_1.asp` | 確認済み | 該当なし表示を確認 |
| 25 | 店舗点検データ閲覧 | `/scripts/verona/print/prtz420_1.asp` | 確認済み | 結果画面を確認 |
| 26 | インボイス対応税率別取引合計レポート | `/scripts/verona/print/prtz530_1.asp` | 確認済み | 該当なし表示を確認 |
| 27 | 収入印紙データ集計表(店舗別年月日別) | `/scripts/verona/print/prtz500_1.asp` | 確認済み | 結果画面を確認 |

## 在庫管理（13画面）

| No. | メニュー | 相対パス | 条件画面 | 検索・抽出結果 |
| --- | --- | --- | --- | --- |
| 28 | 客注在庫照会 | `/scripts/verona/print/prtz370_1.asp` | 確認済み | 結果画面を確認 |
| 29 | 在庫詳細照会 | `/scripts/verona/print/prtz010_1.asp` | 確認済み | 結果画面を確認 |
| 30 | 在庫詳細照会 | `/scripts/verona/print/prtz015_1.asp` | 確認済み | 結果画面を確認 |
| 31 | 在庫照会 | `/scripts/verona/print/prtz011_1.asp` | 確認済み | 結果画面を確認 |
| 32 | 全拠点在庫照会 | `/scripts/verona/print/prtz450_1.asp` | 確認済み | 結果画面を確認 |
| 33 | アイテム別在庫表 | `/scripts/verona/print/prtz210_1.asp` | 確認済み | 結果画面を確認 |
| 34 | 部門別在庫表 | `/scripts/verona/print/prtz220_1.asp` | 確認済み | 結果画面を確認 |
| 35 | 品番別在庫表 | `/scripts/verona/print/prtz190_1.asp` | 確認済み | 結果画面を確認 |
| 36 | 商品別在庫表 | `/scripts/verona/print/prtz200_1.asp` | 確認済み | 結果画面を確認 |
| 37 | 店舗別在庫表 | `/scripts/verona/print/prtz250_1.asp` | 確認済み | 結果画面を確認 |
| 38 | 商品受払表 | `/scripts/verona/print/prtz270_1.asp` | 確認済み | 結果画面を確認 |
| 39 | 商品マスター検索 | `/scripts/verona/display/dstz100_1.asp` | 確認済み | 結果画面を確認 |
| 40 | 仮棚卸リスト | `/scripts/verona/print/prtz365_1.asp` | 確認済み | 該当なし表示を確認 |

## エクスポート（6画面）

| No. | メニュー | 相対パス | 条件画面 | 検索・抽出結果 |
| --- | --- | --- | --- | --- |
| 41 | 販売データ エクスポート | `/scripts/verona/display/dstz210_1.asp` | 確認済み | CSV取得・Excelリンクを確認 |
| 42 | 移動データ エクスポート | `/scripts/verona/display/dstz240_1.asp` | 確認済み | 該当なし表示を確認 |
| 43 | 在庫データ エクスポート | `/scripts/verona/display/dstz280_1.asp` | 確認済み | CSV・Excelリンクを確認 |
| 44 | 販売累計データ エクスポート | `/scripts/verona/display/dstz300_1.asp` | 確認済み | 該当なし表示を確認 |
| 45 | 収入印紙集計データエクスポート | `/scripts/verona/display/dstz710_1.asp` | 確認済み | 抽出後画面を確認・ファイル取得未確認 |
| 46 | 日別収入印紙集計データエクスポート | `/scripts/verona/display/dstz730_1.asp` | 確認済み | 抽出後画面を確認・ファイル取得未確認 |

## 検証の区別と未確認事項

実サイトの確認と、架空の画面を使う自動テストは別に記録します。`Tests/fixtures/compound-form.html`を含むfixtureテストは架空の値を使用し、実サイトの全メニューの検索成功を証明するものではありません。Chromiumでの確認は、iPhone実機のWKWebViewでの確認を代替しません。

iPhone実機の操作、AirPrintの出力、iOSの共有画面は未確認です。1.4.0のビルド・署名・配布結果は、この画面点検記録とは別に[CI_BUILD.md](CI_BUILD.md)へ記録します。

公開する記録にはメニュー名・相対パス・確認範囲だけを残し、資格情報、店舗用ログインURL、業務明細、私的スクリーンショットは含めません。
