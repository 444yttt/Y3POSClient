import SwiftUI

@MainActor
struct SettingsView: View {
    @ObservedObject var browser: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var replacementURL = ""
    @State private var staffAutofillEnabled = false
    @State private var replacementStaffID = ""
    @State private var replacementPassword = ""
    @State private var validationError: String?
    @State private var staffValidationError: String?
    @State private var submitting = false
    @State private var confirmRemoval = false

    private var busy: Bool {
        submitting || browser.connectionStoreLoading || browser.staffCredentialStoreLoading
    }

    private var version: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        guard let build, !build.isEmpty else { return value }
        return "\(value) (\(build))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if browser.hasSavedConnection {
                        Label("接続設定は登録済みです", systemImage: "checkmark.shield")
                        Text("変更する場合だけ、新しいURLを入力してください。空欄なら現在の設定を使います。")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else if browser.connectionStoreError == nil {
                        Text("ログイン開始URLを登録してください。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    SecureField(browser.hasSavedConnection ? "新しいログイン開始URL" : "https://…", text: $replacementURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("ログイン開始URL")
                        .privacySensitive()
                        .disabled(busy)
                    if let validationError { Text(validationError).foregroundStyle(.red).font(.footnote) }
                    if let error = browser.connectionStoreError, error != validationError {
                        Text(error).foregroundStyle(.red).font(.footnote)
                        Button("保存済み設定を再試行") {
                            Task { @MainActor in await browser.retrySavedConnection() }
                        }
                        .disabled(busy)
                    }
                    if busy { ProgressView("処理中…") }
                } header: { Text("ログイン開始URL") } footer: {
                    Text("店舗の接続情報を含むURLを、このiPhoneのKeychainに保存します。登録済みURLは表示しません。URLを変更すると、以前のURL用に保存したスタッフ情報を削除します。")
                }
                Section {
                    Toggle("スタッフ情報を保存して自動入力", isOn: $staffAutofillEnabled)
                        .disabled(busy)
                    if browser.hasSavedStaffCredentials {
                        Label("スタッフ情報は登録済みです", systemImage: "checkmark.shield")
                            .font(.footnote)
                    }
                    if staffAutofillEnabled {
                        TextField(browser.hasSavedStaffCredentials ? "変更するスタッフID" : "スタッフID", text: $replacementStaffID)
                            .keyboardType(.asciiCapable)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .privacySensitive()
                            .disabled(busy)
                        SecureField(browser.hasSavedStaffCredentials ? "変更するパスワード" : "パスワード", text: $replacementPassword)
                            .textContentType(.password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .privacySensitive()
                            .disabled(busy)
                        if browser.hasSavedStaffCredentials {
                            Text("保存済みのID・パスワードは表示しません。同じURLで更新する場合、空欄の項目は現在の設定を使います。URLも変更する場合は両方を入力してください。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if let staffValidationError {
                        Text(staffValidationError).foregroundStyle(.red).font(.footnote)
                    }
                    if let error = browser.staffCredentialStoreError, error != staffValidationError {
                        Text(error).foregroundStyle(.red).font(.footnote)
                        Button("保存済みスタッフ情報を再試行") {
                            Task { @MainActor in
                                await browser.refreshStaffCredentialStatus()
                                staffAutofillEnabled = browser.hasSavedStaffCredentials
                            }
                        }
                        .disabled(busy)
                    }
                    if browser.hasSavedStaffCredentials || browser.staffCredentialStoreError != nil {
                        Button("保存したスタッフ情報を削除", role: .destructive) {
                            submitting = true
                            staffValidationError = nil
                            Task { @MainActor in
                                if let error = await browser.removeSavedStaffCredentials() {
                                    staffValidationError = error
                                } else {
                                    staffAutofillEnabled = false
                                    replacementStaffID = ""
                                    replacementPassword = ""
                                }
                                submitting = false
                            }
                        }
                        .disabled(busy)
                    }
                } header: { Text("スタッフのログイン情報") } footer: {
                    Text("オンにして保存すると、登録した接続先のログイン画面でID・パスワードを自動入力します。ログインボタンは自分で押してください。保存先はこのiPhoneのKeychainで、他の端末には同期しません。オフで保存するとスタッフ情報を削除します。")
                }
                Section("接続先") {
                    Text(URLPolicy.origin).font(.footnote).textSelection(.enabled)
                    Label("接続先の証明書を検証します", systemImage: "lock.shield").font(.footnote)
                }
                Section("ログイン状態") {
                    Text("Cookieはこのアプリ内で保持します。有効期限はサイトに従います。SafariやPC版とのログイン状態の共有はありません。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("接続設定を削除", role: .destructive) { confirmRemoval = true }
                        .disabled(busy || (!browser.hasSavedConnection && browser.connectionStoreError == nil))
                    Text("接続設定の削除ではURL・スタッフ情報・Cookieを消去し、接続設定を開き直します。メニューのログイン状態リセットはCookieだけを消去し、スタッフ情報を保持します。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    LabeledContent("バージョン", value: version)
                    Text("サイト運営元の公式アプリではありません。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("接続設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }.disabled(submitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        submitting = true
                        validationError = nil
                        staffValidationError = nil
                        Task { @MainActor in
                            if let error = await browser.saveConnectionSettings(replacementURL,
                                staffAutofillEnabled: staffAutofillEnabled,
                                staffID: replacementStaffID, password: replacementPassword) {
                                validationError = error
                                submitting = false
                                return
                            }
                            replacementURL = ""
                            replacementStaffID = ""
                            replacementPassword = ""
                            submitting = false
                            dismiss()
                            browser.login()
                        }
                    }
                    .disabled(busy)
                }
            }
            .interactiveDismissDisabled(submitting)
            .alert("接続設定を削除", isPresented: $confirmRemoval) {
                Button("キャンセル", role: .cancel) {}
                Button("削除する", role: .destructive) {
                    submitting = true
                    validationError = nil
                    Task { @MainActor in
                        if let error = await browser.removeSavedConnection() {
                            validationError = error
                            submitting = false
                            return
                        }
                        replacementURL = ""
                        replacementStaffID = ""
                        replacementPassword = ""
                        staffAutofillEnabled = false
                        submitting = false
                        dismiss()
                    }
                }
            } message: {
                Text("登録済みURL・スタッフ情報と、このアプリのログイン状態を消去します。再度URLの登録が必要です。")
            }
            .task {
                await browser.refreshStaffCredentialStatus()
                staffAutofillEnabled = browser.hasSavedStaffCredentials
            }
            .onDisappear {
                replacementURL = ""
                replacementStaffID = ""
                replacementPassword = ""
            }
        }
    }
}
