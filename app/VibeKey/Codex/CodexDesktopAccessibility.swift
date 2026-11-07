import AppKit
import ApplicationServices
import CoreGraphics
import Carbon.HIToolbox

/// Codex 桌面 App 的辅助功能分类规则。单独拆出后可用纯字符串测试，
/// 避免把本地化文案散落在 AX 遍历代码里。
nonisolated enum CodexAccessibilityLabels {
    static let send: Set<String> = [
        "发送", "发送消息", "发送提示", "傳送", "Send", "Send message", "Send prompt", "Submit", "送信", "보내기", "Enviar", "Envoyer", "Senden", "Invia",
    ]
    static let stop: Set<String> = [
        "停止", "停止生成", "Stop", "Stop generating", "Stoppen", "Arrêter", "Detener", "Fermare", "Parar", "Остановить",
    ]
    /// 只把这些控件当作“有审批卡”。聊天正文里的“拒绝”等普通文字不是 AXButton，不会误报。
    static let approval: Set<String> = [
        "允许一次", "始終允許", "始终允许", "允许此对话", "审批选项", "拒绝",
        "Allow once", "Always allow", "Allow this conversation", "Approval options", "Deny",
    ]

    static func isSend(_ label: String) -> Bool { send.contains(label.trimmingCharacters(in: .whitespacesAndNewlines)) }
    static func isStop(_ label: String) -> Bool { stop.contains(label.trimmingCharacters(in: .whitespacesAndNewlines)) }
    static func isApproval(_ label: String) -> Bool {
        let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return approval.contains(normalized)
            || normalized.hasPrefix("允许")
            || normalized.hasPrefix("始终允许")
            || normalized.hasPrefix("Allow ")
    }
}

/// Codex 的 AX 线程身份通常出现在文档、URL 或 Identifier 中。只接受完整 UUID，
/// 不把普通按钮标识或项目路径升格为聊天身份。
nonisolated enum CodexConversationIdentityResolver {
    static func containsThreadUUID(_ value: String) -> Bool {
        value.range(
            of: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#,
            options: .regularExpression
        ) != nil
    }
}

/// Web AX 输入框的 value 有时等于占位提示，需要在业务判断前归一化。
nonisolated enum CodexInputText {
    static func effective(_ value: String, placeholder: String, characterCount: Int? = nil, rangeText: String? = nil,
                          placeholderOnly: Bool = false) -> String {
        if placeholderOnly { return "" }
        // 范围文本与字符数描述编辑内容本身，优先于可能包含提示文案的 AXValue。
        if let rangeText { return rangeText }
        if let characterCount, characterCount >= 0 { return characterCount == 0 ? "" : value }
        return !placeholder.isEmpty && value == placeholder ? "" : value
    }
}

/// 编辑器内容的结构证据，只保存“是否含文字”，不复制用户输入。
/// ProseMirror 的 CSS 提示文字会进入 AXValue 和 AX 字符数，必须按 placeholder 祖先区分。
nonisolated struct CodexInputContent {
    var placeholder = false
    var text = false
    var children: [CodexInputContent] = []

    var isPlaceholderOnly: Bool {
        let evidence = evidence(insidePlaceholder: false)
        return evidence.placeholder && !evidence.content
    }

    private func evidence(insidePlaceholder: Bool) -> (placeholder: Bool, content: Bool) {
        let inside = insidePlaceholder || placeholder
        var foundPlaceholder = placeholder
        var content = text && !inside
        for child in children {
            let next = child.evidence(insidePlaceholder: inside)
            foundPlaceholder = foundPlaceholder || next.placeholder
            content = content || next.content
        }
        return (foundPlaceholder, content)
    }
}

/// 只读 AX 树中的控件角色、文案和输入框全文。输入框全文仅用于核对发送目标，
/// 不写日志、不保存到文件；每次检查结束后由调用栈释放。
@MainActor
final class AccessibilityCodexDesktopAdapter: CodexDesktopAdapter {
    static let bundleIdentifier = "com.openai.codex"

    private let application: () -> NSRunningApplication?
    private let workspace: NSWorkspace
    private let verificationTimeout: Duration
    private let inspector = CodexAccessibilityInspector()
    private var accessibilityPrepared: Set<pid_t> = []

    init(application: @escaping () -> NSRunningApplication? = {
        NSRunningApplication.runningApplications(withBundleIdentifier: AccessibilityCodexDesktopAdapter.bundleIdentifier)
            .first { !$0.isTerminated }
    }, workspace: NSWorkspace = .shared, verificationTimeout: Duration = .seconds(2)) {
        self.application = application
        self.workspace = workspace
        self.verificationTimeout = verificationTimeout
    }

    /// 只输出角色、属性和字符数，不输出输入框正文或窗口标题，用于适配 Codex AX 结构更新。
    static func debugTreeSummary() -> String {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first(where: { !$0.isTerminated }) else { return "no app" }
        return CodexAccessibilityInspector().debugTreeSummary(processID: app.processIdentifier)
    }

    func inspectTarget() async throws -> CodexTargetSnapshot? {
        guard AXIsProcessTrusted() else {
            // 目标预检是只读操作；权限申请只由设置页的明确操作发起，避免每次按录音都弹系统框。
            throw CodexDesktopAdapterError.accessibilityDenied
        }
        guard let app = application(), !app.isTerminated else {
            throw CodexDesktopAdapterError.appUnavailable
        }
        if !accessibilityPrepared.contains(app.processIdentifier), ElectronAccessibility.enable(processID: app.processIdentifier) {
            accessibilityPrepared.insert(app.processIdentifier)
            // Chromium 首次创建完整树是异步的，避免立刻读取旧的残缺快照。
            try await Task.sleep(for: .milliseconds(120))
        }
        return try inspector.inspect(
            processID: app.processIdentifier,
            isFrontmost: workspace.frontmostApplication?.processIdentifier == app.processIdentifier,
            isUnlocked: Self.isSessionUnlocked
        )
    }

    func send(_ attempt: CodexDraftBuffer.Attempt, using snapshot: CodexTargetSnapshot) async throws
        -> CodexDraftBuffer.Delivery {
        guard let current = try await inspectTarget(), current.target == snapshot.target,
              current.isFrontmost, current.isUnlocked, current.canSend,
              !current.hasPendingApproval,
              CodexActionCoordinator.inputMatches(current.inputText, attempt.draft.text) else {
            return .notSent
        }
        guard try inspector.focusComposerForSend(
            expectedTarget: snapshot.target, text: attempt.draft.text
        ) else { Log.codex.notice("send blocked: composer/button validation failed"); return .notSent }
        // Chromium 的 AXPress 可返回成功但不触发提交。使用编辑器的 Cmd-Enter 作为唯一发送动作，
        // 普通 Enter 受换行偏好和多段落影响；本机编辑器的 Mod-Enter 绑定明确触发 submit。
        // 不先 AXPress 再补回车；发键前仍完整核对目标、全文、焦点、运行与审批状态。
        guard let focused = try await inspectTarget(), focused.target == snapshot.target,
              focused.isFrontmost, focused.isUnlocked, focused.canSend, !focused.hasPendingApproval,
              CodexActionCoordinator.inputMatches(focused.inputText, attempt.draft.text),
              KeySender.press(kVK_Return, flags: .maskCommand, processID: snapshot.target.processID) else { return .notSent }
        Log.codex.info("send posted: process-bound cmd-return, chars=\(attempt.draft.text.count)")

        let deadline = ContinuousClock.now + verificationTimeout
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return .unknown }
            guard let after = try? await inspectTarget() else { continue }
            if CodexSendReceipt.confirms(after, target: snapshot.target) {
                Log.codex.info("send confirmed: same conversation, composer cleared")
                return .confirmed
            }
        }
        Log.codex.notice("send unknown: receipt timed out; no retry dispatched")
        // 已经送出一次提交事件，但无法确认 UI 是否接收；按不确定处理，禁止自动重发。
        return .unknown
    }

    func stop(using snapshot: CodexTargetSnapshot) async throws -> CodexDraftBuffer.Delivery {
        guard let current = try await inspectTarget(), current.target == snapshot.target,
              current.isFrontmost, current.isUnlocked, current.runState == .running,
              !current.hasPendingApproval else {
            return .notSent
        }
        guard let button = try inspector.control(
            processID: snapshot.target.processID, expectedTarget: snapshot.target,
            matching: CodexAccessibilityLabels.isStop
        ) else { return .notSent }
        guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else { return .notSent }

        let deadline = ContinuousClock.now + verificationTimeout
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(80))
            guard let after = try await inspectTarget(), after.target == snapshot.target else { continue }
            if after.runState == .idle { return .confirmed }
        }
        return .unknown
    }

    /// 锁屏时 AX 可能仍能读到旧窗口；发送前必须是已解锁的当前图形会话。
    private static var isSessionUnlocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let locked = session["CGSSessionScreenIsLocked"] as? NSNumber else { return true }
        return !locked.boolValue
    }
}

/// 一次 AX 遍历的结果。遍历不读取聊天正文，只读取输入框 value、窗口标识和可交互按钮文案。
private nonisolated struct CodexAccessibilitySnapshot {
    let window: AXUIElement
    let input: AXUIElement
    let inputText: String
    let buttons: [AXUIElement]
}

private nonisolated struct ResolvedCodexTarget {
    let target: CodexDraftTarget
    let identity: CodexTargetSnapshot.ConversationIdentity
}

@MainActor
private final class CodexAccessibilityInspector {
    // CFHash 只是散列值，不能作为元素 ID 或去重依据；不同 AX 节点可能散列碰撞。
    // 字典和 Set<AXUIElement> 通过 CFEqual 区分碰撞，本注册表只在适配器生命周期内保存匿名 ID。
    private var identities: [AXUIElement: String] = [:]
    private var identityOrder: [AXUIElement] = []

    private func elementIdentity(for element: AXUIElement) -> String {
        if let existing = identities[element] { return existing }
        if identityOrder.count >= 512 { identities.removeValue(forKey: identityOrder.removeFirst()) }
        let token = UUID().uuidString
        identities[element] = token
        identityOrder.append(element)
        return token
    }

    enum Failure: Error {
        case noWindow, noFocusedInput
    }

    func inspect(processID: pid_t, isFrontmost: Bool, isUnlocked: Bool) throws -> CodexTargetSnapshot? {
        guard let snapshot = try tree(processID: processID), let resolved = target(in: snapshot) else { return nil }
        let labels = snapshot.buttons.filter(actionable).map(label).filter { !$0.isEmpty }
        return CodexTargetSnapshot(
            target: resolved.target,
            isFrontmost: isFrontmost,
            isUnlocked: isUnlocked,
            inputText: snapshot.inputText,
            runState: labels.contains(where: CodexAccessibilityLabels.isStop) ? .running : .idle,
            hasPendingApproval: labels.contains(where: CodexAccessibilityLabels.isApproval),
            conversationIdentity: resolved.identity,
            canSend: labels.contains(where: CodexAccessibilityLabels.isSend)
        )
    }

    /// 在同一份 AX 树快照里核对目标并取按钮。按钮与窗口、输入框必须来自同一次遍历，
    /// 防止“检查后切到另一个聊天、再按到新聊天按钮”的竞态。
    func control(
        processID: pid_t,
        expectedTarget: CodexDraftTarget,
        matching predicate: (String) -> Bool
    ) throws -> AXUIElement? {
        guard let snapshot = try tree(processID: processID), target(in: snapshot)?.target == expectedTarget else {
            return nil
        }
        return snapshot.buttons.first { actionable($0) && predicate(label($0)) }
    }

    /// 只有同一目标、同一全文且唯一可用发送按钮时才聚焦编辑器；不是 AX 查找失败的按键兜底。
    func focusComposerForSend(expectedTarget: CodexDraftTarget, text: String) throws -> Bool {
        guard let snapshot = try tree(processID: expectedTarget.processID),
              target(in: snapshot)?.target == expectedTarget,
              CodexActionCoordinator.inputMatches(snapshot.inputText, text),
              snapshot.buttons.filter({ actionable($0) && CodexAccessibilityLabels.isSend(label($0)) }).count == 1,
              actionable(snapshot.input) else { return false }
        let app = AXUIElementCreateApplication(expectedTarget.processID)
        if let focused = element(app, kAXFocusedUIElementAttribute), CFEqual(focused, snapshot.input) { return true }
        guard AXUIElementSetAttributeValue(snapshot.input, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success,
              let focused = element(app, kAXFocusedUIElementAttribute) else { return false }
        return CFEqual(focused, snapshot.input)
    }

    private func tree(processID: pid_t) throws -> CodexAccessibilitySnapshot? {
        let app = AXUIElementCreateApplication(processID)
        let windows = elements(app, kAXWindowsAttribute)
        guard let window = windows.first(where: { boolean($0, kAXFocusedAttribute) == true })
            ?? element(app, kAXFocusedWindowAttribute)
            ?? element(app, kAXMainWindowAttribute)
            ?? windows.first else { throw Failure.noWindow }

        var focusedInput: AXUIElement?
        var textAreas: [AXUIElement] = []
        var buttons: [AXUIElement] = []
        // 新版 Codex 的网页输入框由 AXFocusedUIElement 返回，但不是窗口遍历的子节点。
        // 优先使用这个权威焦点；只有它不符合文本输入角色时才回退到树内唯一 text area。
        if let focused = element(app, kAXFocusedUIElementAttribute),
           string(focused, kAXRoleAttribute) == (kAXTextAreaRole as String) {
            focusedInput = focused
        }
        var seen = Set<AXUIElement>()
        var remaining = 30_000
        let collect: (AXUIElement) -> Void = { [self] element in
            let role = string(element, kAXRoleAttribute)
            if role == (kAXTextAreaRole as String) {
                textAreas.append(element)
                if focusedInput == nil, boolean(element, kAXFocusedAttribute) == true { focusedInput = element }
            } else if role == (kAXButtonRole as String) {
                buttons.append(element)
            }
        }
        walk(window, depth: 0, seen: &seen, remaining: &remaining, visit: collect)
        // Chromium 可把 composer 作为独立 AX 片段，只通过应用焦点和 AXParent 相连。
        // 向上补读每层的孩子，仍去重并限制遍历数量，不依赖窗口孩子包含整个编辑器。
        if let input = focusedInput {
            var parent: AXUIElement? = input
            var ancestors = Set<AXUIElement>()
            for _ in 0..<24 {
                guard let node = parent, ancestors.insert(node).inserted,
                      string(node, kAXRoleAttribute) != (kAXApplicationRole as String) else { break }
                for child in [node] + elements(node, kAXChildrenAttribute) + elements(node, "AXChildrenInNavigationOrder") {
                    walk(child, depth: 0, seen: &seen, remaining: &remaining, visit: collect)
                }
                if string(node, kAXRoleAttribute) == (kAXWindowRole as String) { break }
                parent = element(node, kAXParentAttribute)
            }
        }
        // Codex 聊天页通常只有一个多行输入框。焦点在聊天按钮时，按下 OK 可安全把焦点送回这个唯一输入框，
        // 不向未知应用或控件自动输入；多个候选则拒绝猜测。
        if focusedInput == nil, textAreas.count == 1 {
            let candidate = textAreas[0]
            if AXUIElementSetAttributeValue(candidate, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success {
                focusedInput = candidate
            }
        }
        guard let input = focusedInput,
              let rawInputText = value(input) as? String else { throw Failure.noFocusedInput }
        // 网页输入框可能把占位提示作为 AXValue 返回；只有与 AXPlaceholderValue 完全相同才视为空。
        let count = (value(input, "AXNumberOfCharacters") as? NSNumber)?.intValue
        let inputText = CodexInputText.effective(rawInputText,
            placeholder: stringValue(input, "AXPlaceholderValue"), characterCount: count,
            rangeText: rangeText(input, count: count), placeholderOnly: inputContent(input).isPlaceholderOnly)
        return CodexAccessibilitySnapshot(window: window, input: input, inputText: inputText, buttons: buttons)
    }

    /// 用进程、窗口、线程标识和输入框共同绑定一次 axPress 的目标。
    private func target(in snapshot: CodexAccessibilitySnapshot) -> ResolvedCodexTarget? {
        var processID: pid_t = 0
        AXUIElementGetPid(snapshot.window, &processID)
        let windowTitle = string(snapshot.window, kAXTitleAttribute)
        let conversation = conversationIdentifier(in: snapshot.window)
        let value = conversation?.value ?? windowTitle
        let identity = conversation?.identity ?? .title
        let conversationID = "\(identity.rawValue):\(value)#\(windowTitle)"
        guard let target = CodexDraftTarget(
            processID: processID,
            windowID: elementIdentity(for: snapshot.window),
            conversationID: conversationID,
            inputID: elementIdentity(for: snapshot.input)
        ) else { return nil }
        return ResolvedCodexTarget(target: target, identity: identity)
    }

    private func walk(
        _ element: AXUIElement,
        depth: Int,
        seen: inout Set<AXUIElement>,
        remaining: inout Int,
        visit: (AXUIElement) -> Void
    ) {
        guard depth < 100, remaining > 0, seen.insert(element).inserted else { return }
        remaining -= 1
        visit(element)
        for child in elements(element, kAXChildrenAttribute) + elements(element, "AXChildrenInNavigationOrder") {
            walk(child, depth: depth + 1, seen: &seen, remaining: &remaining, visit: visit)
        }
    }

    /// Codex 当前不一定提供 AXDocument。优先取文档；否则在窗口、网页区和容器中寻找
    /// URL／Identifier 里的线程 UUID，只有 UUID 形式才采用，避免把通用控件标识当成聊天身份。
    private func conversationIdentifier(
        in root: AXUIElement
    ) -> (identity: CodexTargetSnapshot.ConversationIdentity, value: String)? {
        var document: String?
        var url: String?
        var identifier: String?
        var seen = Set<AXUIElement>()
        var remaining = 4_000
        let containerRoles: Set<String> = [
            "AXWindow", "AXWebArea", "AXGroup", "AXScrollArea", "AXTextArea",
        ]
        walk(root, depth: 0, seen: &seen, remaining: &remaining) { element in
            if document == nil {
                let candidate = stringValue(element, kAXDocumentAttribute)
                if !candidate.isEmpty { document = candidate }
            }
            guard containerRoles.contains(string(element, kAXRoleAttribute)) else { return }
            if url == nil {
                let candidate = stringValue(element, kAXURLAttribute)
                if CodexConversationIdentityResolver.containsThreadUUID(candidate) { url = candidate }
            }
            if identifier == nil {
                let candidate = stringValue(element, kAXIdentifierAttribute)
                if CodexConversationIdentityResolver.containsThreadUUID(candidate) { identifier = candidate }
            }
        }
        if let document { return (.document, document) }
        if let url { return (.url, url) }
        if let identifier { return (.identifier, identifier) }
        return nil
    }

    func debugTreeSummary(processID: pid_t) -> String {
        let app = AXUIElementCreateApplication(processID)
        guard let window = elements(app, kAXWindowsAttribute).first
            ?? element(app, kAXFocusedWindowAttribute)
            ?? element(app, kAXMainWindowAttribute) else { return "no window" }
        var counts: [String: Int] = [:]
        var candidates: [String] = []
        var focusedCandidates: [String] = []
        var focusedTextArea: AXUIElement?
        var diagnosticInputs: [AXUIElement] = []
        var sendButtons = 0
        var enabledSendButtons = 0
        var actionLabels: [String] = []
        var seen = Set<AXUIElement>()
        var remaining = 30_000
        walk(window, depth: 0, seen: &seen, remaining: &remaining) { element in
            let role = string(element, kAXRoleAttribute)
            if role == (kAXTextAreaRole as String) { diagnosticInputs.append(element) }
            counts[role, default: 0] += 1
            if role == (kAXButtonRole as String), CodexAccessibilityLabels.isSend(label(element)) {
                sendButtons += 1
                if enabled(element) { enabledSendButtons += 1 }
            }
            if role == (kAXButtonRole as String), actionable(element) {
                let currentLabel = label(element)
                if CodexAccessibilityLabels.isSend(currentLabel) || CodexAccessibilityLabels.isStop(currentLabel) {
                    actionLabels.append(currentLabel)
                }
            }
            let editable = boolean(element, "AXEditable") == true
            let roleLooksEditable = role.contains("Text") || role.contains("Web") || role.contains("Combo")
            let focused = boolean(element, kAXFocusedAttribute) == true
            if focused, role == (kAXTextAreaRole as String) { focusedTextArea = element }
            guard focusedCandidates.count < 8, focused || (candidates.count < 24 && (editable || roleLooksEditable)) else {
                return
            }
            let subrole = string(element, kAXSubroleAttribute)
            let hidden = boolean(element, kAXHiddenAttribute) == true
            let valueChars = (value(element, kAXValueAttribute) as? String)?.count ?? -1
            var valueSettable: DarwinBoolean = false
            AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &valueSettable)
            let attrs = attributeNames(element).filter {
                $0 == kAXValueAttribute || $0 == "AXEditable" || $0 == kAXFocusedAttribute
                    || $0 == kAXIdentifierAttribute || $0 == kAXURLAttribute
                    || $0 == kAXSelectedTextRangeAttribute || $0 == kAXDOMIdentifierAttribute
                    || $0 == "AXPlaceholderValue"
            }.joined(separator: ",")
            let description = (
                "\(role)/\(subrole) focused=\(focused) editable=\(editable) hidden=\(hidden) "
                    + "valueChars=\(valueChars) valueSettable=\(valueSettable.boolValue) attrs=\(attrs)"
            )
            if focused { focusedCandidates.append(description) }
            if candidates.count < 24, editable || roleLooksEditable { candidates.append(description) }
        }
        let roles = counts.sorted { $0.value > $1.value }.prefix(20)
            .map { "\($0.key)=\($0.value)" }.joined(separator: ";")
        let focusedUI = axElement(value(app, kAXFocusedUIElementAttribute)) ?? focusedTextArea
            ?? (diagnosticInputs.count == 1 ? diagnosticInputs.first : nil)
        let focusedRole = focusedUI.map { string($0, kAXRoleAttribute) } ?? "nil"
        let focusedSubrole = focusedUI.map { string($0, kAXSubroleAttribute) } ?? "nil"
        let focusedValueChars = focusedUI.flatMap { value($0, kAXValueAttribute) as? String }?.count ?? -1
        let focusedPlaceholderChars = focusedUI.map { stringValue($0, "AXPlaceholderValue").count } ?? -1
        // Chromium 有时把视觉上的占位符写进 AXValue，却把 AXPlaceholderValue 留空；
        // 同时记录 AXNumberOfCharacters，确认它是否能可靠区分占位符与真实草稿。
        let focusedCharacterCount = focusedUI
            .flatMap { value($0, "AXNumberOfCharacters") as? NSNumber }?
            .intValue ?? -1
        let focusedTitle = focusedUI.map { string($0, kAXTitleAttribute) } ?? ""
        let focusedDescription = focusedUI.map { string($0, kAXDescriptionAttribute) } ?? ""
        let focusedHelp = focusedUI.map { string($0, kAXHelpAttribute) } ?? ""
        let focusedValue = focusedUI.flatMap { value($0, kAXValueAttribute) as? String } ?? ""
        let formatCharacters = focusedValue.unicodeScalars.filter { $0.properties.generalCategory == .format }.count
        let focusedAttrs = focusedUI.map { attributeNames($0).joined(separator: ",") } ?? ""
        var inputShape: [String] = []
        if let focusedUI {
            var inputSeen = Set<AXUIElement>()
            var inputRemaining = 30
            walk(focusedUI, depth: 0, seen: &inputSeen, remaining: &inputRemaining) { node in
                let classes = (value(node, "AXDOMClassList") as? [String] ?? []).joined(separator: ",")
                inputShape.append("\(string(node, kAXRoleAttribute)) classes=\(classes) chars=\((value(node) as? String)?.count ?? -1)")
            }
        }
        var ancestorSummary: [String] = []
        if let input = element(app, kAXFocusedUIElementAttribute) {
            var parent: AXUIElement? = input
            var ancestors = Set<AXUIElement>()
            for _ in 0..<12 {
                guard let node = parent, ancestors.insert(node).inserted else { break }
                let role = string(node, kAXRoleAttribute)
                if role == (kAXApplicationRole as String) { break }
                var found: [String] = []
                var nodes = Set<AXUIElement>(), budget = 2_000
                walk(node, depth: 0, seen: &nodes, remaining: &budget) { item in
                    guard string(item, kAXRoleAttribute) == (kAXButtonRole as String), actionable(item) else { return }
                    let text = label(item)
                    if CodexAccessibilityLabels.isSend(text) || CodexAccessibilityLabels.isStop(text) { found.append(text) }
                }
                let classes = (value(node, "AXDOMClassList") as? [String] ?? []).joined(separator: ",")
                ancestorSummary.append("\(role).\(classes):actions=\(found.joined(separator: "/"))")
                if role == (kAXWindowRole as String) { break }
                parent = element(node, kAXParentAttribute)
            }
        }
        let hashCollisions = seen.count - Set(seen.map { CFHash($0) }).count
        return "hashCollisions=\(hashCollisions) ancestors=\(ancestorSummary.joined(separator: " > ")) roles=\(roles) focusedByAttribute=\(focusedRole)/\(focusedSubrole) "
            + "focusedValueChars=\(focusedValueChars) focusedPlaceholderChars=\(focusedPlaceholderChars) "
            + "focusedCharacterCount=\(focusedCharacterCount) "
            + "formatCharacters=\(formatCharacters) "
            + "focusedTitleChars=\(focusedTitle.count) focusedDescriptionChars=\(focusedDescription.count) "
            + "focusedHelpChars=\(focusedHelp.count) "
            + "titleEqualsValue=\(!focusedTitle.isEmpty && focusedTitle == focusedValue) "
            + "descriptionEqualsValue=\(!focusedDescription.isEmpty && focusedDescription == focusedValue) "
            + "helpEqualsValue=\(!focusedHelp.isEmpty && focusedHelp == focusedValue) "
            + "trimmedTitleEqualsValue=\(!focusedTitle.isEmpty && focusedTitle.trimmingCharacters(in: .whitespacesAndNewlines) == focusedValue.trimmingCharacters(in: .whitespacesAndNewlines)) "
            + "inputShape=\(inputShape.joined(separator: " | ")) "
            + "sendButtons=\(sendButtons) enabledSendButtons=\(enabledSendButtons) "
            + "actionLabels=\(actionLabels.joined(separator: " || ")) "
            + "focusedAttrs=\(focusedAttrs) "
            + "focused=\(focusedCandidates.joined(separator: " | ")) "
            + "candidates=\(candidates.joined(separator: " | "))"
    }

    private func label(_ button: AXUIElement) -> String {
        let title = string(button, kAXTitleAttribute)
        return title.isEmpty ? string(button, kAXDescriptionAttribute) : title
    }

    /// 读取编辑内容的完整范围，避免把 Web 输入框的提示文案当作用户草稿。
    private func rangeText(_ input: AXUIElement, count: Int?) -> String? {
        guard let count, count >= 0, count <= 1_000_000 else { return nil }
        var range = CFRange(location: 0, length: count)
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(input, kAXStringForRangeParameterizedAttribute as CFString,
            parameter, &result) == .success else { return nil }
        return result as? String
    }

    /// 只排除能证明完全来自提示节点的文字；混有真实文本、提及或未知深层内容时保留草稿。
    private func inputContent(_ node: AXUIElement, depth: Int = 0) -> CodexInputContent {
        guard depth < 24 else { return .init(text: true) }
        let role = string(node, kAXRoleAttribute)
        let classes = value(node, "AXDOMClassList") as? [String] ?? []
        let text = role == (kAXStaticTextRole as String)
            && !(value(node) as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let embedded = [kAXButtonRole as String, "AXLink", kAXImageRole as String].contains(role)
        return .init(placeholder: classes.contains("placeholder"), text: text || embedded,
                     children: elements(node, kAXChildrenAttribute).map { inputContent($0, depth: depth + 1) })
    }

    private func value(_ element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String {
        value(element, attribute) as? String ?? ""
    }

    private func stringValue(_ element: AXUIElement, _ attribute: String) -> String {
        guard let value = value(element, attribute) else { return "" }
        if let string = value as? String { return string }
        if let url = value as? URL { return url.absoluteString }
        return ""
    }

    private func enabled(_ element: AXUIElement) -> Bool {
        boolean(element, kAXEnabledAttribute) ?? true
    }

    /// 只把用户当前可操作且未隐藏的控件当作运行／审批信号和点击目标。
    /// Codex 可能在 AX 树中保留不可见的隐藏按钮，不能据此推断任务状态。
    private func actionable(_ element: AXUIElement) -> Bool {
        enabled(element) && boolean(element, kAXHiddenAttribute) != true
    }

    private func boolean(_ element: AXUIElement, _ attribute: String) -> Bool? {
        guard let value = value(element, attribute), CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    private func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        value(element, attribute) as? [AXUIElement] ?? []
    }

    private func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        axElement(value(element, attribute))
    }

    private func axElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func attributeNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    private func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
}
