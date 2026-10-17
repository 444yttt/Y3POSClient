import SwiftUI
import UIKit
import WebKit

@MainActor
struct ContentView: View {
    @ObservedObject var browser: BrowserModel
    @State private var keyboardVisible = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                BrowserHeader(browser: browser, keyboardVisible: keyboardVisible)
                BrowserSurface(browser: browser, webView: browser.activeWebView)
            }
                .toolbar(.hidden, for: .navigationBar)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if !keyboardVisible && !browser.framePanes.isEmpty && browser.failure == nil {
                        BrowserControls(browser: browser)
                    }
                }
                .disabled(browser.isResetting)
                .sheet(item: $browser.sheet, onDismiss: browser.sheetDidDismiss) { sheet in
                    switch sheet {
                    case .settings: SettingsView(browser: browser)
                    case .download(let download):
                        ShareSheet(file: download.file) { browser.sharingCompleted(id: download.id) }
                    }
                }
                .alert("ログイン状態をリセット", isPresented: $browser.showResetConfirmation) {
                    Button("キャンセル", role: .cancel) {}
                    Button("消去する", role: .destructive) { browser.resetSession() }
                } message: {
                    Text("このアプリに保存したログイン状態を消去します。再ログインが必要になり、別ウィンドウも閉じます。")
                }
                .alert("Y3 Client", isPresented: Binding(get: { browser.notice != nil }, set: { if !$0 { browser.notice = nil } })) {
                    Button("OK") { browser.notice = nil }
                } message: { Text(browser.notice ?? "") }
        }
        .tint(Color.primary)
        .onAppear { browser.start() }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
            guard browser.sheet == nil,
                  let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .filter { $0.activationState == .foregroundActive }.flatMap(\.windows)
            guard let window = windows.first(where: \.isKeyWindow) else { return }
            let localFrame = window.screen.coordinateSpace.convert(frame, to: window)
            keyboardVisible = window.bounds.intersection(localFrame).height > 0
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
        }
    }
}

@MainActor
private struct BrowserHeader: View {
    @ObservedObject var browser: BrowserModel
    let keyboardVisible: Bool

    private var screenTitle: String {
        if browser.needsLogin { return "ログイン" }
        if browser.title == "POS CM CLOUD" || browser.title.contains("メニュー選択") { return "店舗ツール" }
        return browser.title
    }

    var body: some View {
        HStack(spacing: 10) {
            if browser.hasPopups {
                Button("閉じる", systemImage: "xmark", action: browser.closeTopPopup)
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
            } else if browser.canGoBack {
                Button("戻る", systemImage: "chevron.left", action: browser.back)
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
            }
            Button(action: browser.home) {
                Text("Y-3").font(.system(size: 23, weight: .black, design: .default))
                    .tracking(-1)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("メニューへ戻る")
            .disabled(!browser.hasSavedConnection)
            Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 20)
            Text(screenTitle)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if keyboardVisible {
                Button("キーボードを閉じる", systemImage: "keyboard.chevron.compact.down", action: browser.dismissKeyboard)
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
            }
            BrowserMoreMenu(browser: browser)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 54)
        .background(Color(.systemBackground))
        .overlay(alignment: .bottom) { Divider() }
    }
}

@MainActor
struct BrowserSurface: View {
    @ObservedObject var browser: BrowserModel
    let webView: WKWebView

    private var resultPanes: [FramePane] { browser.framePanes.filter { $0.kind == .result } }
    private var showingResult: Bool { resultPanes.contains { $0.id == browser.selectedFramePaneID } }

    var body: some View {
        VStack(spacing: 0) {
            if resultPanes.count > 1 && showingResult && browser.failure == nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(resultPanes) { pane in
                            paneButton(pane.title, selected: browser.selectedFramePaneID == pane.id) { browser.focusFramePane(pane) }
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 5)
                }
                .background(Color(.systemBackground))
                .overlay(alignment: .bottom) { Divider() }
                .accessibilityLabel("結果の切替")
            }
            if browser.needsLogin {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                    Text("ログインが必要です").font(.footnote)
                    Spacer(minLength: 8)
                    Button("ログイン画面", action: browser.login).font(.footnote.weight(.semibold))
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color(.tertiarySystemBackground))
            }
            ZStack(alignment: .top) {
                WebView(webView: webView).id(ObjectIdentifier(webView))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(browser.failure == nil ? 1 : 0)
                    .accessibilityHidden(browser.failure != nil)
                if browser.failure == nil && !browser.hasSavedConnection && !browser.isResetting
                    && (webView.url == nil || webView.url?.absoluteString == "about:blank") {
                    ContentUnavailableView {
                        Label("接続設定が必要です", systemImage: "link")
                    } description: {
                        Text("ログイン開始URLを登録して、POS CM CLOUDを開きます。")
                    } actions: {
                        Button("接続設定") { browser.showSettings = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
                if let failure = browser.failure {
                    ContentUnavailableView {
                        Label(failure.title, systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(failure.message)
                    } actions: {
                        Button("もう一度接続する", action: browser.reload).buttonStyle(.borderedProminent)
                        Button("接続設定") { browser.showSettings = true }
                    }
                }
                if browser.loading && browser.failure == nil {
                    ProgressView(value: browser.progress).progressViewStyle(.linear)
                        .accessibilityLabel("読み込み中")
                }
                if browser.isResetting {
                    Color(.systemBackground).opacity(0.95)
                    ProgressView("ログイン状態を消去しています…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func paneButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.footnote.weight(.semibold))
                .padding(.horizontal, 12).frame(minHeight: 44)
                .foregroundStyle(selected ? Color(.systemBackground) : Color.primary)
                .background(selected ? Color.primary : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

@MainActor
struct BrowserControls: View {
    @ObservedObject var browser: BrowserModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var selectedPane: FramePane? { browser.framePanes.first { $0.id == browser.selectedFramePaneID } }
    private var hasConditions: Bool { browser.framePanes.contains { $0.kind == .condition } }
    private var hasResults: Bool { browser.framePanes.contains { $0.kind == .result } }
    private var exportPane: FramePane? { browser.framePanes.first { $0.kind == .export } }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            controlItems
            ScrollView(.horizontal, showsIndicators: false) {
                controlItems
            }
            .accessibilityHint("左右にスクロールして操作を選べます")
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color(.systemBackground))
        .overlay(alignment: .top) { Divider() }
    }

    private var controlItems: some View {
        HStack(spacing: 0) {
            action("メニュー", symbol: "square.grid.2x2", selected: false, action: browser.home)
            if hasConditions {
                action("検索条件", symbol: "slider.horizontal.3", selected: selectedPane?.kind == .condition,
                       action: browser.focusConditions)
            }
            if hasResults {
                action("結果", symbol: "list.bullet.rectangle", selected: selectedPane?.kind == .result,
                       action: browser.focusResults)
            }
            if let exportPane {
                action("書き出し", symbol: "square.and.arrow.up", selected: selectedPane?.kind == .export) {
                    browser.focusFramePane(exportPane)
                }
            }
        }
    }

    private func action(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 17, weight: selected ? .semibold : .regular))
                Text(title).font(.caption.weight(selected ? .semibold : .regular))
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .frame(minWidth: dynamicTypeSize.isAccessibilitySize ? 100 : 72, maxWidth: .infinity, minHeight: 48)
            .background(selected ? Color(.secondarySystemBackground) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

@MainActor
private struct BrowserMoreMenu: View {
    @ObservedObject var browser: BrowserModel

    var body: some View {
        Menu {
            if !browser.framePanes.isEmpty {
                Section("表示") {
                    Button("全体を表示", systemImage: "rectangle.split.2x2") { browser.focusFramePane(nil) }
                    ForEach(browser.framePanes) { pane in
                        Button(pane.title) { browser.focusFramePane(pane) }
                    }
                }
            }
            Section("操作") {
                Button("メニューへ戻る", systemImage: "square.grid.2x2", action: browser.home)
                Button("戻る", systemImage: "chevron.left", action: browser.back).disabled(!browser.canGoBack)
                Button("進む", systemImage: "chevron.right", action: browser.forward).disabled(!browser.canGoForward)
                Button("更新", systemImage: "arrow.clockwise", action: browser.reload)
            }
            Button("ログイン画面", systemImage: "person.crop.circle", action: browser.login)
            Button("AirPrintで印刷", systemImage: "printer", action: browser.printPage)
                .disabled(browser.needsLogin || browser.failure != nil)
            Button("Safariで開く", systemImage: "safari", action: browser.openInSafari)
            Divider()
            Button("接続設定", systemImage: "slider.horizontal.3") { browser.showSettings = true }
            Button("ログイン状態をリセット", systemImage: "arrow.counterclockwise", role: .destructive) { browser.showResetConfirmation = true }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 20, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .labelStyle(.iconOnly)
        .accessibilityLabel("その他の操作")
    }
}

