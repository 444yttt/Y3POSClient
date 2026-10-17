# GitHub ActionsによるIPA作成

専用の公開リポジトリは [444yttt/Y3POSClient](https://github.com/444yttt/Y3POSClient) です。既存のマニュアルリポジトリは非公開のまま維持します。

## ビルド設定

- Source branch: `main`（手動実行時のcommitへ固定）
- Source directory: リポジトリのルート
- Project / shared Scheme / Target: `Y3Client.xcodeproj` / `Y3Client` / `Y3Client`
- Bundle ID: `com.ayato.y3posclient`
- Minimum deployment: iPhone / iOS 17.0
- Runner: standard `macos-15`; Xcode 16.4を明示的に選択。大容量runnerは使いません。
- Timeout: 30分
- Dependencies: Apple frameworksのみ。Extension、Swift Package、CocoaPodsはありません。
- Distribution: `app-store-connect`。IPAのexportのみで、TestFlight・App Storeへのアップロードは行いません。

公開リポジトリの標準GitHub-hosted runnerは、GitHubの公開リポジトリ向け無料利用の対象です。大容量runnerや別の有料サービスへ変更する場合は料金条件が異なります。このworkflowはBilling設定を変更しません。

App Store向けIPAは、ファイルをiPhoneへ渡すだけではインストールできません。直接配布へ変更する場合は、Ad Hoc用のProfileと登録済みUDIDが必要です。

## 現在の実行結果

2026年10月17日の[署名ビルド](https://github.com/444yttt/Y3POSClient/actions/runs/39022303775)で、サイズ別在庫・結果統合・ログイン自動入力を追加した版のSimulatorビルド、実機向けRelease archive、App Store配布用IPAの書き出しと署名検証が成功しました。ビルドしたcommitは`3e205067c74083ee757a19a9e012113f3cbda16f`、バージョンは`1.2.0`、ビルド番号は`3`です。Apple Developerで作成した専用Profileを`BUILD_PROVISION_PROFILE_BASE64`へ登録し、既存P12の署名証明書を使用しています。

Profileの有効期限は`2027-09-28T14:59:37Z`です。arm64の署名、Bundle ID、証明書、Entitlements、Profileの一致と期限など15項目の検証が通り、受け取り後もIPAのSHA256と埋め込みProfileを照合しました。Extensionはありません。iPhone実機での動作、AirPrint、共有画面は未確認です。

既存署名環境から`BUILD_CERTIFICATE_BASE64`、`P12_PASSWORD`、`KEYCHAIN_PASSWORD`、`APPLE_TEAM_ID`、`ASC_KEY_ID`、`ASC_ISSUER_ID`、`ASC_PRIVATE_KEY`を登録し、専用Profileを加えて8つのSecretsを準備済みです。[専用Profileの登録実行](https://github.com/444yttt/Y3POSClient/actions/runs/38135082128)でも、既存P12との一致を検証しました。既存マニュアル用Profileは流用していません。今回のビルドでは登録済みProfileを使用し、Profile作成APIは呼び出していません。

成果物はIPAと検証JSONをまとめたage暗号化ファイルで、Actions Artifactの保存期間は7日です。復号には受取人側で保管する秘密identityが必要です。復元した署名ファイル、一時Keychain、ログイン用一時データは削除済みです。

書き出し方式は`app-store-connect`です。IPAをiPhoneへ渡すだけではインストールできません。このworkflowはTestFlightやApp Storeへのアップロードを行いません。直接配布には、登録済みUDIDを含むAd Hoc Profileと対応する書き出し設定が必要です。

## このリポジトリに登録するSecrets

別リポジトリのSecretsは、新しい公開リポジトリへ自動的に引き継がれません。GitHub APIから既存Secretsの平文を読み戻すこともできません。所有者が署名環境で保管している元ファイルを使い、このリポジトリのSettings → Secrets and variables → Actionsに登録する必要があります。

| 用途 | 推奨するSecret名 | 同じ新リポジトリで利用できる別名 |
| --- | --- | --- |
| 秘密鍵を含む.p12のBase64 | `BUILD_CERTIFICATE_BASE64` | `DIST_P12_BASE64` |
| .p12のパスワード | `P12_PASSWORD` | `DIST_P12_PASSWORD` |
| Apple Developer Team ID | `APPLE_TEAM_ID` | なし |
| 新アプリ専用ProfileのBase64（任意） | `BUILD_PROVISION_PROFILE_BASE64` | なし |
| 一時Keychainのパスワード（任意） | `KEYCHAIN_PASSWORD` | 未設定なら実行ごとに生成 |

Profileを登録しない場合は、同じ新リポジトリに `ASC_KEY_ID`、`ASC_ISSUER_ID`、`ASC_PRIVATE_KEY` を登録します。`ASC_PRIVATE_KEY`は対応する`.p8`ファイルのPEM本文です。APIキーにはCertificates, Identifiers & Profilesへのアクセス権限が必要です。

.p12、パスワード、Profile、API秘密鍵をソース、Issue、Actions入力欄、チャットに貼り付けないでください。SecretsはGitHubのSecrets画面または所有者の認証を使う暗号化された登録経路で設定します。

## 署名とProfileの準備

コード署名には.p12内の対応する秘密鍵と有効な証明書が必要です。.cerだけやApp Store Connect APIキーだけでは署名しません。

Profileが未設定の場合は、登録されたASCキーを使い、既存.p12の証明書に合う `com.ayato.y3posclient` 用のProfileを取得します。未登録なら、このBundle IDとApp Store Profileだけを作成します。既存アプリのProfile、証明書の新規作成・失効、既存アプリの設定変更は行いません。

署名前に秘密鍵identity、ProfileのTeam・App ID prefix・Bundle・許可証明書・期限・配布方式を照合します。署名設定は対象ターゲットにだけ一時的に適用し、ソースのTeam設定は空欄へ戻します。新しいExtension等を追加した場合は、そのターゲット用Profileと検証対応を追加するまで停止します。

### 専用Profileの暗号化登録

`profile-secret.yml`は、レビュー済みの`main`コミットを`expected_source_sha`に指定して開始します。受取人向けに暗号化した一回限りのchallengeを発行し、`profile-secret-reply.yml`で暗号化した応答を受け取ります。応答は同じコミット、実行ID、試行番号に結び付けられ、有効時間は10分です。GitHub所有者の承認済みOAuth認証情報は暗号化した応答の中だけに渡します。

登録前にTeam、正確なBundle ID、既存P12の証明書、有効期限、App Store配布用Profileであることを検証し、`BUILD_PROVISION_PROFILE_BASE64`だけを更新します。Profileと認証情報は、公開workflow入力とChecksへ暗号文としてのみ渡し、一時ファイルは終了時に削除します。平文のProfileや認証情報をworkflow入力へ貼り付けないでください。

## 実行と成果物

Secretsを用意する前でも、Actionsの `Check Y3 POS Client iOS Build` でApple SDKによる無署名Simulatorビルドを確認できます。このworkflowはSecretsの参照や署名資産の復元を行いません。

Secretsの登録後、Actionsから `Build Y3 POS Client IPA` を手動実行します。`source_ref`は`main`だけを受け付けます。専用リポジトリの`main`から手動実行した場合にだけ動作し、実行開始時のcommitをビルドします。Xcode 16.4を確認し、無署名Simulatorビルドの後、実機Releaseのarchive・manual export・署名検証を行います。

出力IPAの全architectureについて、コード署名、Bundle、実署名証明書、Entitlements、埋め込みProfile、期限、選択したProfileとの一致を検証します。成功した場合だけIPAと検証JSONをまとめ、受取人のage公開鍵で暗号化した`.age`ファイルだけをArtifactとして7日間保存します。平文のIPA、検証JSON、生のProfile、証明書ファイル、.p12、API秘密鍵、一時Keychain、archiveはアップロードしません。

公開リポジトリのActions Artifactは、リポジトリを閲覧できるGitHub利用者がダウンロードできますが、このworkflowが保存するのは暗号化済みパッケージだけです。IPAには署名証明書と埋め込みProfileが含まれるため、これらのTeam情報や証明書名も暗号化して保護します。

Artifactのダウンロード経路が使えない場合に備え、別のUbuntuジョブが同じ暗号化ファイルだけを一時的なDraft Releaseにも保存します。Draftは公開せず、タグは`ci-delivery-実行番号-試行番号`です。このジョブには署名用Secretsを渡しません。所有者はDraftのassetを取得して復号・内容確認後、不要になったDraftを削除してください。平文のIPAや検証JSONをReleaseへ保存する処理はありません。

`delivery-recipient.txt`に入れるのは受取人のage公開鍵だけで、ソースへ登録できます。対応する秘密identityは受取人側で保管し、リポジトリ、Secrets、Actions入力欄、Artifactへ入れません。暗号化に追加のSecretsは不要です。生成する秘密identityはソース候補の外で保管します。受取人は秘密identityを使ってダウンロードした`.age`を復号し、中のIPAと検証JSONを取り出します。

成否にかかわらず、復元した署名ファイルとKeychainを削除し、Keychainの検索リストを戻します。IPAの生成後も、iPhone実機でのログイン・共有・AirPrintの確認は必要です。

## 実行が止まる場合

- Secret不足: エラーに表示された名前を、この新リポジトリのActions Secretsへ登録します。別の非公開リポジトリに同じ名前があっても利用されません。
- 秘密鍵identityなし: 対応する秘密鍵を含む.p12を、既存署名環境から書き出します。
- Apple APIの401: Key ID・Issuer ID・対応する.p8を確認します。
- Apple APIの403: APIキーのCertificates, Identifiers & Profiles権限を確認するか、新Bundleに適合するProfileを登録します。
- 期限切れ・Team不一致: 所有者のApple Developer Teamに属する、有効な証明書と対応するProfileを用意します。
- Runner開始前のアカウント制限: GitHubのBilling画面に表示された理由を確認します。このworkflowは支払いや利用上限を変更しません。
