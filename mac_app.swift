import AppKit
import Foundation
import UniformTypeIdentifiers

let defaultOutputDir = "\(NSHomeDirectory())/Desktop/影片轉文字輸出"
let ud = UserDefaults.standard

let appBackground = NSColor.windowBackgroundColor
let primaryText = NSColor.labelColor
let secondaryText = NSColor.secondaryLabelColor
let fieldBackground = NSColor.textBackgroundColor

protocol DropHandler: AnyObject {
    func handleDragEntered(_ sender: NSDraggingInfo) -> NSDragOperation
    func handleDragOperation(_ sender: NSDraggingInfo) -> Bool
}

final class DropReceivingView: NSView {
    weak var dropHandler: DropHandler?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, .string, .URL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropHandler?.handleDragEntered(sender) ?? []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHandler?.handleDragOperation(sender) ?? false
    }
}

// Locate the self-contained frozen CLI that PyInstaller produced.
// It lives next to the main executable inside the .app bundle.
func bundledTranscriberCLI() -> String {
    let execDir = Bundle.main.executableURL!.deletingLastPathComponent()
    return execDir.appendingPathComponent("transcriber-cli").path
}

final class AppDelegate: NSObject, NSApplicationDelegate, DropHandler {
    var window: NSWindow!
    let sourceModeControl = NSSegmentedControl(labels: ["網路網址", "本機檔案"], trackingMode: .selectOne, target: nil, action: nil)
    let urlField = NSTextField()
    let pasteButton = NSButton(title: "貼上", target: nil, action: nil)
    let localFileField = NSTextField()
    let localFileButton = NSButton(title: "選檔", target: nil, action: nil)
    let outputField = NSTextField(string: defaultOutputDir)
    let languagePopup = NSPopUpButton()
    let modelPopup = NSPopUpButton()
    let cookiesPopup = NSPopUpButton()
    let videoCheck = NSButton(checkboxWithTitle: "下載影片 MP4", target: nil, action: nil)
    let highPrecisionCheck = NSButton(checkboxWithTitle: "高精度模式（較慢，錯字更少）", target: nil, action: nil)
    let txtCheck = NSButton(checkboxWithTitle: "輸出 TXT", target: nil, action: nil)
    let srtCheck = NSButton(checkboxWithTitle: "輸出 SRT", target: nil, action: nil)
    let startButton = NSButton(title: "開始轉錄", target: nil, action: nil)
    let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    let openButton = NSButton(title: "打開輸出資料夾", target: nil, action: nil)
    let statusLabel = NSTextField(labelWithString: "準備好了")
    let detailLabel = NSTextField(labelWithString: "")
    let progressBar = NSProgressIndicator()
    let progressLabel = NSTextField(labelWithString: "0%")
    let logView = NSTextView()
    var process: Process?
    var lastOutputDir: String?
    var wasCancelled = false
    var outputBuffer = ""
    var ffmpegAvailable = true
    var urlSectionView: NSView!
    var localFileSectionView: NSView!
    var cookiesSectionView: NSView!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        ffmpegAvailable = checkFFmpegAvailable()
        buildMainMenu()
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminateChildProcess(force: true)
    }

    func bundledToolPath(_ name: String) -> String {
        Bundle.main.executableURL!
            .deletingLastPathComponent()
            .appendingPathComponent(name)
            .path
    }

    func checkFFmpegAvailable() -> Bool {
        let candidates = [
            bundledToolPath("ffmpeg"),
            bundledToolPath("ffmpeg-arm64"),
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg"
        ]
        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return true
            }
        }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "影片轉文字"
        window.titlebarAppearsTransparent = true
        window.center()
        window.minSize = NSSize(width: 860, height: 560)

        guard let content = window.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = appBackground.cgColor

        let dropView = DropReceivingView(frame: content.bounds)
        dropView.autoresizingMask = [.width, .height]
        dropView.dropHandler = self
        content.addSubview(dropView)

        let formWidth: CGFloat = 780
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .centerX
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 24, left: 0, bottom: 20, right: 0)
        root.translatesAutoresizingMaskIntoConstraints = false
        dropView.addSubview(root)
        NSLayoutConstraint.activate([
            root.centerXAnchor.constraint(equalTo: dropView.centerXAnchor),
            root.widthAnchor.constraint(equalToConstant: formWidth),
            root.leadingAnchor.constraint(greaterThanOrEqualTo: dropView.leadingAnchor, constant: 32),
            root.trailingAnchor.constraint(lessThanOrEqualTo: dropView.trailingAnchor, constant: -32),
            root.topAnchor.constraint(equalTo: dropView.topAnchor),
            root.bottomAnchor.constraint(equalTo: dropView.bottomAnchor)
        ])

        let subtitle = NSTextField(labelWithString: "YouTube / Instagram Reel / 本機影片  →  自動轉錄成文字與字幕")
        subtitle.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        subtitle.textColor = secondaryText
        subtitle.alignment = .center
        root.addArrangedSubview(subtitle)

        let sourceBox = sectionBox("來源", width: formWidth)
        let sourceContent = NSStackView()
        sourceContent.orientation = .vertical
        sourceContent.alignment = .centerX
        sourceContent.spacing = 12
        sourceBox.contentView = sourceContent
        root.addArrangedSubview(sourceBox)

        sourceModeControl.selectedSegment = 0
        sourceModeControl.target = self
        sourceModeControl.action = #selector(sourceModeChanged)
        sourceModeControl.widthAnchor.constraint(equalToConstant: 260).isActive = true
        sourceContent.addArrangedSubview(sourceModeControl)

        let urlRow = NSStackView()
        urlRow.orientation = .horizontal
        urlRow.alignment = .centerY
        urlRow.spacing = 10
        urlRow.widthAnchor.constraint(equalToConstant: formWidth - 32).isActive = true
        urlRow.addArrangedSubview(urlField)
        pasteButton.target = self
        pasteButton.action = #selector(pasteURLFromClipboard)
        pasteButton.widthAnchor.constraint(equalToConstant: 76).isActive = true
        urlRow.addArrangedSubview(pasteButton)

        urlSectionView = labeledView("影片網址", urlRow, align: .left)
        urlSectionView.widthAnchor.constraint(equalToConstant: formWidth - 32).isActive = true
        sourceContent.addArrangedSubview(urlSectionView)
        urlField.placeholderString = "YouTube 影片網址，或 Instagram 單支 Reel 連結（不是帳號頁）"
        urlField.font = NSFont.systemFont(ofSize: 15)
        urlField.target = self
        urlField.action = #selector(sourceFieldsChanged)
        styleInput(urlField)
        urlField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        urlField.heightAnchor.constraint(equalToConstant: 34).isActive = true

        let localFileRow = NSStackView()
        localFileRow.orientation = .horizontal
        localFileRow.alignment = .centerY
        localFileRow.spacing = 10
        localFileRow.widthAnchor.constraint(equalToConstant: formWidth - 32).isActive = true
        localFileRow.addArrangedSubview(localFileField)
        localFileButton.target = self
        localFileButton.action = #selector(chooseLocalFile)
        localFileButton.widthAnchor.constraint(equalToConstant: 76).isActive = true
        localFileRow.addArrangedSubview(localFileButton)

        localFileSectionView = labeledView("本機檔案", localFileRow, align: .left)
        localFileSectionView.widthAnchor.constraint(equalToConstant: formWidth - 32).isActive = true
        sourceContent.addArrangedSubview(localFileSectionView)
        localFileField.placeholderString = "選擇 MP4 / MOV / MP3 / WAV / M4A"
        localFileField.font = NSFont.systemFont(ofSize: 15)
        localFileField.target = self
        localFileField.action = #selector(sourceFieldsChanged)
        styleInput(localFileField)
        localFileField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        localFileField.heightAnchor.constraint(equalToConstant: 34).isActive = true

        let outputBox = sectionBox("輸出設定", width: formWidth)
        let outputContent = NSStackView()
        outputContent.orientation = .vertical
        outputContent.alignment = .leading
        outputContent.spacing = 12
        outputBox.contentView = outputContent
        root.addArrangedSubview(outputBox)

        let outputRow = NSStackView()
        outputRow.orientation = .horizontal
        outputRow.alignment = .centerY
        outputRow.spacing = 10
        outputRow.widthAnchor.constraint(equalToConstant: formWidth - 32).isActive = true
        outputRow.addArrangedSubview(outputField)
        styleInput(outputField)
        outputField.isEditable = false
        outputField.isSelectable = true
        outputField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        outputField.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let chooseButton = NSButton(title: "選擇", target: self, action: #selector(chooseOutputFolder))
        outputRow.addArrangedSubview(chooseButton)
        chooseButton.widthAnchor.constraint(equalToConstant: 80).isActive = true
        outputContent.addArrangedSubview(labeledView("輸出資料夾", outputRow, align: .left))

        languagePopup.addItems(withTitles: ["繁體中文", "英文", "原文"])
        modelPopup.addItems(withTitles: ["Large 最準（較慢）", "Small 標準", "Base 最快"])
        cookiesPopup.addItems(withTitles: ["不使用", "Chrome", "Safari", "Firefox", "Edge"])
        stylePopup(languagePopup)
        stylePopup(modelPopup)
        stylePopup(cookiesPopup)

        let popupRow = NSStackView()
        popupRow.orientation = .horizontal
        popupRow.alignment = .top
        popupRow.spacing = 18
        popupRow.distribution = .fillEqually
        popupRow.widthAnchor.constraint(equalToConstant: formWidth - 32).isActive = true
        popupRow.addArrangedSubview(labeledView("輸出語言", languagePopup, align: .left))
        popupRow.addArrangedSubview(labeledView("轉錄品質", modelPopup, align: .left))
        outputContent.addArrangedSubview(popupRow)

        let cookieRow = NSStackView()
        cookieRow.orientation = .horizontal
        cookieRow.alignment = .centerY
        cookieRow.spacing = 6
        cookieRow.widthAnchor.constraint(equalToConstant: formWidth - 32).isActive = true
        cookieRow.addArrangedSubview(cookiesPopup)
        cookiesPopup.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let cookieInfoButton = NSButton()
        cookieInfoButton.bezelStyle = .inline
        cookieInfoButton.isBordered = false
        cookieInfoButton.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Instagram 登入說明")
        cookieInfoButton.imagePosition = .imageOnly
        cookieInfoButton.target = self
        cookieInfoButton.action = #selector(showCookieHelp)
        cookieInfoButton.toolTip = "若 Reel 下載失敗，請先在瀏覽器登入 Instagram，再選對應瀏覽器"
        cookieRow.addArrangedSubview(cookieInfoButton)
        let cookieSpacer = NSView()
        cookieSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        cookieRow.addArrangedSubview(cookieSpacer)
        cookiesSectionView = labeledView("Instagram 登入", cookieRow, align: .left)
        cookiesSectionView.widthAnchor.constraint(equalToConstant: formWidth - 32).isActive = true
        outputContent.addArrangedSubview(cookiesSectionView)

        videoCheck.state = .on
        videoCheck.target = self
        videoCheck.action = #selector(sourceFieldsChanged)
        highPrecisionCheck.target = self
        highPrecisionCheck.action = #selector(highPrecisionChanged)
        txtCheck.state = .on
        srtCheck.state = .on
        styleButton(videoCheck)
        styleButton(highPrecisionCheck)
        styleButton(txtCheck)
        styleButton(srtCheck)
        let checkRow = NSStackView(views: [videoCheck, txtCheck, srtCheck])
        checkRow.orientation = .horizontal
        checkRow.alignment = .centerY
        checkRow.spacing = 22
        outputContent.addArrangedSubview(checkRow)
        outputContent.addArrangedSubview(highPrecisionCheck)

        let formatHint = NSTextField(labelWithString: "至少選擇一種輸出格式（網址模式可另選下載 MP4）")
        formatHint.font = NSFont.systemFont(ofSize: 11)
        formatHint.textColor = secondaryText
        outputContent.addArrangedSubview(formatHint)

        startButton.target = self
        startButton.action = #selector(startWork)
        startButton.bezelStyle = .rounded
        startButton.controlSize = .large
        startButton.keyEquivalent = "\r"
        startButton.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        startButton.contentTintColor = .controlAccentColor

        openButton.target = self
        openButton.action = #selector(openOutputFolder)
        openButton.isEnabled = false
        cancelButton.target = self
        cancelButton.action = #selector(cancelWork)
        cancelButton.isEnabled = false
        cancelButton.keyEquivalent = "."

        let buttonRow = NSStackView(views: [startButton, cancelButton, openButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        buttonRow.alignment = .centerY
        root.addArrangedSubview(buttonRow)

        let progressRow = NSStackView()
        progressRow.orientation = .horizontal
        progressRow.alignment = .centerY
        progressRow.spacing = 10
        progressRow.widthAnchor.constraint(equalToConstant: formWidth).isActive = true
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 100
        progressBar.doubleValue = 0
        progressBar.controlSize = .regular
        progressBar.setContentHuggingPriority(.defaultLow, for: .horizontal)
        progressRow.addArrangedSubview(progressBar)
        progressLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        progressLabel.textColor = secondaryText
        progressLabel.alignment = .right
        progressLabel.widthAnchor.constraint(equalToConstant: 46).isActive = true
        progressRow.addArrangedSubview(progressLabel)
        root.addArrangedSubview(progressRow)

        statusLabel.font = NSFont.boldSystemFont(ofSize: 14)
        statusLabel.textColor = primaryText
        statusLabel.alignment = .center
        root.addArrangedSubview(statusLabel)

        detailLabel.font = NSFont.systemFont(ofSize: 12)
        detailLabel.textColor = secondaryText
        detailLabel.alignment = .center
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.maximumNumberOfLines = 2
        root.addArrangedSubview(detailLabel)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.autohidesScrollers = true
        logView.isEditable = false
        logView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.backgroundColor = NSColor.textBackgroundColor
        logView.textColor = primaryText
        logView.isRichText = false
        scrollView.documentView = logView
        scrollView.widthAnchor.constraint(equalToConstant: formWidth).isActive = true
        root.addArrangedSubview(scrollView)
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true

        urlField.toolTip = "貼上 YouTube 或 Instagram Reel 連結，也可拖放檔案或網址到此視窗"
        localFileField.toolTip = "支援 MP4, MOV, MP3, WAV, M4A"
        outputField.toolTip = "轉錄結果會儲存到此資料夾"
        highPrecisionCheck.toolTip = "使用 Large-v3 完整模型與 FP32 推論，適合重要內容"
        startButton.toolTip = "開始下載 / 轉錄處理（Enter）"
        cancelButton.toolTip = "中止目前處理（⌘.）"
        openButton.toolTip = "用 Finder 打開最後的輸出資料夾"
        cookiesPopup.toolTip = cookieInfoButton.toolTip

        updateSourceMode(focus: false)
        restorePreferences()

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(urlField)
    }

    func sectionBox(_ title: String, width: CGFloat) -> NSBox {
        let box = NSBox()
        box.title = title
        box.titlePosition = .atTop
        box.boxType = .custom
        box.cornerRadius = 8
        box.borderWidth = 1
        box.fillColor = NSColor.controlBackgroundColor.withAlphaComponent(0.3)
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: width).isActive = true
        return box
    }

    func handleDragEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            return .copy
        }
        if sender.draggingPasteboard.string(forType: .string) != nil {
            return .copy
        }
        return []
    }

    func handleDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], let first = urls.first {
            if first.isFileURL {
                sourceModeControl.selectedSegment = 1
                localFileField.stringValue = first.path
                updateSourceMode()
            } else {
                sourceModeControl.selectedSegment = 0
                urlField.stringValue = first.absoluteString
                updateSourceMode()
            }
            savePreferences()
            return true
        }
        if let s = pb.string(forType: .string) ?? pb.string(forType: .URL) {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("http") || trimmed.hasPrefix("file:") {
                sourceModeControl.selectedSegment = 0
                urlField.stringValue = trimmed
            } else if FileManager.default.fileExists(atPath: trimmed) {
                sourceModeControl.selectedSegment = 1
                localFileField.stringValue = trimmed
            } else {
                urlField.stringValue = trimmed
            }
            updateSourceMode()
            savePreferences()
            return true
        }
        return false
    }

    func restorePreferences() {
        if let lastOut = ud.string(forKey: "lastOutputDir"), !lastOut.isEmpty {
            outputField.stringValue = lastOut
        }
        if let m = ud.string(forKey: "lastModel") {
            for i in 0..<modelPopup.numberOfItems {
                if modelPopup.item(at: i)?.title.contains(m) == true || modelPopup.itemTitle(at: i).lowercased().contains(m) {
                    modelPopup.selectItem(at: i)
                    break
                }
            }
        }
        if let l = ud.string(forKey: "lastLanguage") {
            for i in 0..<languagePopup.numberOfItems {
                if languagePopup.itemTitle(at: i).contains(l == "zh" ? "繁" : (l == "en" ? "英文" : "原文")) {
                    languagePopup.selectItem(at: i)
                    break
                }
            }
        }
        if ud.object(forKey: "preferTXT") != nil { txtCheck.state = ud.bool(forKey: "preferTXT") ? .on : .off }
        if ud.object(forKey: "preferSRT") != nil { srtCheck.state = ud.bool(forKey: "preferSRT") ? .on : .off }
        if ud.object(forKey: "preferVideo") != nil { videoCheck.state = ud.bool(forKey: "preferVideo") ? .on : .off }
        if ud.object(forKey: "preferHighPrecision") != nil {
            highPrecisionCheck.state = ud.bool(forKey: "preferHighPrecision") ? .on : .off
            updateHighPrecisionMode()
        }
        if let cookie = ud.string(forKey: "lastCookies") {
            for i in 0..<cookiesPopup.numberOfItems {
                if cookieCode(from: cookiesPopup.itemTitle(at: i)) == cookie {
                    cookiesPopup.selectItem(at: i)
                    break
                }
            }
        }
        if let mode = ud.object(forKey: "lastSourceMode") as? Int {
            sourceModeControl.selectedSegment = mode
            updateSourceMode(focus: false)
        }
    }

    func savePreferences() {
        ud.set(outputField.stringValue, forKey: "lastOutputDir")
        let modelTitle = modelPopup.titleOfSelectedItem ?? ""
        if modelTitle.contains("Base") { ud.set("base", forKey: "lastModel") }
        else if modelTitle.contains("Small") { ud.set("small", forKey: "lastModel") }
        else { ud.set("large-v3", forKey: "lastModel") }

        let langTitle = languagePopup.titleOfSelectedItem ?? ""
        if langTitle.contains("英文") { ud.set("en", forKey: "lastLanguage") }
        else if langTitle.contains("原文") { ud.set("original", forKey: "lastLanguage") }
        else { ud.set("zh", forKey: "lastLanguage") }

        ud.set(txtCheck.state == .on, forKey: "preferTXT")
        ud.set(srtCheck.state == .on, forKey: "preferSRT")
        ud.set(videoCheck.state == .on, forKey: "preferVideo")
        ud.set(highPrecisionCheck.state == .on, forKey: "preferHighPrecision")
        ud.set(sourceModeControl.selectedSegment, forKey: "lastSourceMode")
        ud.set(cookieCode(), forKey: "lastCookies")
    }

    func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "結束影片轉文字", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "編輯")
        editMenu.addItem(withTitle: "剪下", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "複製", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "貼上", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全選", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    func labeledView(_ label: String, _ view: NSView, align: NSTextAlignment = .center) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        if align == .left {
            stack.alignment = .leading
        } else {
            stack.alignment = .centerX
        }
        stack.spacing = 4
        let labelView = NSTextField(labelWithString: label)
        labelView.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        labelView.textColor = secondaryText
        labelView.alignment = align
        stack.addArrangedSubview(labelView)
        stack.addArrangedSubview(view)
        return stack
    }

    func styleInput(_ field: NSTextField) {
        field.drawsBackground = true
        field.backgroundColor = fieldBackground
        field.textColor = primaryText
        if let placeholder = field.placeholderString {
            field.placeholderAttributedString = NSAttributedString(
                string: placeholder,
                attributes: [.foregroundColor: NSColor.placeholderTextColor]
            )
        }
    }

    func styleButton(_ button: NSButton) {
        button.contentTintColor = primaryText
    }

    func stylePopup(_ popup: NSPopUpButton) {
        popup.alignment = .left
        popup.contentTintColor = primaryText
    }

    @objc func showCookieHelp() {
        showAlert(
            "若 Instagram Reel 下載失敗，請先在 Chrome、Safari、Firefox 或 Edge 登入 Instagram，\n再在此選擇你使用的瀏覽器作為登入狀態來源。"
        )
    }

    @objc func pasteURLFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            showAlert("剪貼簿裡沒有可以貼上的文字。")
            return
        }
        urlField.stringValue = text.trimmingCharacters(in: .whitespacesAndNewlines)
        updateSourceMode()
        window.makeFirstResponder(urlField)
    }

    @objc func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: outputField.stringValue)
        if panel.runModal() == .OK, let url = panel.url {
            outputField.stringValue = url.path
            savePreferences()
        }
    }

    @objc func chooseLocalFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            .mpeg4Movie, .quickTimeMovie, .movie, .audio, .mp3, .wav, .mpeg4Audio
        ]
        if panel.runModal() == .OK, let url = panel.url {
            sourceModeControl.selectedSegment = 1
            localFileField.stringValue = url.path
            updateSourceMode()
        }
    }

    @objc func sourceModeChanged() {
        updateSourceMode()
        savePreferences()
    }

    @objc func sourceFieldsChanged() {
        updateSourceMode()
        savePreferences()
    }

    @objc func highPrecisionChanged() {
        updateHighPrecisionMode()
        savePreferences()
    }

    func updateHighPrecisionMode() {
        let enabled = highPrecisionCheck.state == .on
        modelPopup.isEnabled = !enabled
        modelPopup.alphaValue = enabled ? 0.45 : 1.0
        if enabled {
            modelPopup.selectItem(withTitle: "Large 最準（較慢）")
        }
    }

    func isURLMode() -> Bool {
        sourceModeControl.selectedSegment == 0
    }

    func updateSourceMode(focus: Bool = true) {
        let urlMode = isURLMode()
        urlSectionView.isHidden = !urlMode
        localFileSectionView.isHidden = urlMode
        cookiesSectionView.isHidden = !urlMode
        videoCheck.isHidden = !urlMode
        videoCheck.isEnabled = urlMode
        videoCheck.alphaValue = urlMode ? 1.0 : 0.45
        if focus {
            window.makeFirstResponder(urlMode ? urlField : localFileField)
        }
    }

    @objc func startWork() {
        savePreferences()

        if !ffmpegAvailable {
            ffmpegAvailable = checkFFmpegAvailable()
            if !ffmpegAvailable {
                showAlert("找不到 ffmpeg。\n請重新安裝 App，或執行：brew install ffmpeg")
                return
            }
        }

        let cliPath = bundledTranscriberCLI()
        if !FileManager.default.fileExists(atPath: cliPath) {
            showAlert("內建轉錄引擎 (transcriber-cli) 找不到。\n請確認 App 是否完整。")
            return
        }

        let url = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let localFile = localFileField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlMode = isURLMode()
        if urlMode && url.isEmpty {
            showAlert("請先貼上影片網址。")
            return
        }
        if !urlMode && localFile.isEmpty {
            showAlert("請先選擇本機檔案。")
            return
        }
        if urlMode && videoCheck.state != .on && txtCheck.state != .on && srtCheck.state != .on {
            showAlert("請至少勾選 MP4、TXT 或 SRT 其中一項。")
            return
        }
        if !urlMode && txtCheck.state != .on && srtCheck.state != .on {
            showAlert("本機檔案請至少勾選 TXT 或 SRT。")
            return
        }

        wasCancelled = false
        outputBuffer = ""
        logView.string = ""
        statusLabel.stringValue = "處理中"
        detailLabel.stringValue = "準備開始"
        setProgress(0, "準備開始")
        startButton.isEnabled = false
        cancelButton.isEnabled = true
        openButton.isEnabled = false
        lastOutputDir = nil

        if highPrecisionCheck.state == .on {
            appendLog("高精度模式：使用 Large-v3 完整模型 + FP32 推論。首次會下載模型，請保持網路。")
        } else if modelCode() == "large-v3" {
            appendLog("提示：使用 MLX Whisper large-v3-turbo（Apple Silicon 優化）。首次會下載模型，請保持網路。")
        }

        var arguments = [
            "--output-dir", outputField.stringValue,
            "--language", languageCode(),
            "--model", modelCode()
        ]
        if !urlMode {
            arguments += ["--input-file", localFile]
        } else {
            arguments += ["--url", url]
            let cookie = cookieCode()
            if !cookie.isEmpty {
                arguments += ["--cookies", cookie]
            }
        }
        if urlMode && videoCheck.state == .on {
            arguments.append("--download-video")
        }
        if txtCheck.state == .on {
            arguments += ["--format", "txt"]
        }
        if srtCheck.state == .on {
            arguments += ["--format", "srt"]
        }
        if highPrecisionCheck.state == .on {
            arguments.append("--high-precision")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.outputBuffer += String(decoding: data, as: UTF8.self)
                while let newlineIndex = self.outputBuffer.firstIndex(of: "\n") {
                    let line = String(self.outputBuffer[..<newlineIndex])
                    self.outputBuffer.removeSubrange(...newlineIndex)
                    if self.outputBuffer.first == "\n" {
                        self.outputBuffer.removeFirst()
                    }
                    self.consumeOutput(line + "\n")
                }
            }
        }

        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                pipe.fileHandleForReading.readabilityHandler = nil
                if let self, !self.outputBuffer.isEmpty {
                    self.consumeOutput(self.outputBuffer + "\n")
                    self.outputBuffer = ""
                }
                self?.finish(exitCode: finished.terminationStatus)
            }
        }

        do {
            try process.run()
            self.process = process
        } catch {
            startButton.isEnabled = true
            cancelButton.isEnabled = false
            statusLabel.stringValue = "啟動失敗"
            detailLabel.stringValue = ""
            showAlert("無法啟動轉錄引擎：\(error.localizedDescription)")
        }
    }

    @objc func cancelWork() {
        if let p = process, p.isRunning {
            wasCancelled = true
            terminateChildProcess(force: false)
            appendLog("已送出取消指令，正在中止...")
            statusLabel.stringValue = "正在取消"
            detailLabel.stringValue = ""
        }
        cancelButton.isEnabled = false
    }

    func terminateChildProcess(force: Bool) {
        guard let p = process, p.isRunning else { return }
        if force {
            p.interrupt()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, let p = self.process, p.isRunning else { return }
                p.terminate()
            }
        } else {
            p.interrupt()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self, let p = self.process, p.isRunning else { return }
                p.terminate()
            }
        }
    }

    func consumeOutput(_ text: String) {
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix("OUTPUT_DIR::") {
                lastOutputDir = String(line.dropFirst("OUTPUT_DIR::".count))
            } else if line.hasPrefix("PROGRESS::") {
                handleProgress(line)
            } else {
                appendLog(line)
            }
        }
    }

    func finish(exitCode: Int32) {
        process = nil
        startButton.isEnabled = true
        cancelButton.isEnabled = false
        openButton.isEnabled = lastOutputDir != nil

        if wasCancelled {
            setProgress(0, "")
            statusLabel.stringValue = "已取消"
            detailLabel.stringValue = ""
            wasCancelled = false
            return
        }

        if exitCode == 0 {
            setProgress(100, "完成")
            statusLabel.stringValue = "完成"
            detailLabel.stringValue = "可以按「打開輸出資料夾」查看結果"
            appendLog("完成，可以按「打開輸出資料夾」查看結果")
        } else {
            statusLabel.stringValue = "發生錯誤"
            detailLabel.stringValue = "請查看下方詳細日誌"
            appendLog("處理失敗，請看上方訊息（或重新設定後端）")
        }
    }

    func handleProgress(_ line: String) {
        let parts = line.components(separatedBy: "::")
        guard parts.count >= 3, let value = Double(parts[1]) else { return }
        let message = parts.dropFirst(2).joined(separator: "::")
        setProgress(value, message)
    }

    func setProgress(_ value: Double, _ message: String) {
        let clamped = min(max(value, 0), 100)
        progressBar.doubleValue = clamped
        progressLabel.stringValue = "\(Int(clamped))%"
        if !message.isEmpty {
            detailLabel.stringValue = message
            updateStageLabel(from: message, progress: clamped)
        }
    }

    func updateStageLabel(from message: String, progress: Double) {
        let lower = message.lowercased()
        if progress >= 100 || lower.contains("完成") {
            statusLabel.stringValue = "完成"
        } else if lower.contains("下載模型") {
            statusLabel.stringValue = "下載模型中"
        } else if lower.contains("下載") || lower.contains("download") {
            statusLabel.stringValue = "下載中"
        } else if lower.contains("轉錄") || lower.contains("transcrib") || lower.contains("whisper") || lower.contains("音訊") {
            statusLabel.stringValue = "轉錄中"
        } else if process != nil {
            statusLabel.stringValue = "處理中"
        }
    }

    func appendLog(_ message: String) {
        let current = logView.string
        logView.string = current.isEmpty ? "\(message)\n" : "\(current)\(message)\n"
        logView.scrollToEndOfDocument(nil)
    }

    @objc func openOutputFolder() {
        let path = lastOutputDir ?? outputField.stringValue
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }

    func showAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    func languageCode() -> String {
        switch languagePopup.titleOfSelectedItem ?? "繁體中文" {
        case "英文": return "en"
        case "原文": return "original"
        default: return "zh"
        }
    }

    func modelCode() -> String {
        switch modelPopup.titleOfSelectedItem ?? "Large 最準" {
        case "Base 最快": return "base"
        case "Small 標準": return "small"
        default: return "large-v3"
        }
    }

    func cookieCode() -> String {
        cookieCode(from: cookiesPopup.titleOfSelectedItem ?? "不使用")
    }

    func cookieCode(from title: String) -> String {
        switch title {
        case "Chrome": return "chrome"
        case "Safari": return "safari"
        case "Firefox": return "firefox"
        case "Edge": return "edge"
        default: return ""
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.isFileURL {
                sourceModeControl.selectedSegment = 1
                localFileField.stringValue = url.path
            } else {
                sourceModeControl.selectedSegment = 0
                urlField.stringValue = url.absoluteString
            }
        }
        updateSourceMode()
        if !urls.isEmpty {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            window?.makeKeyAndOrderFront(nil)
        }
        return true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()