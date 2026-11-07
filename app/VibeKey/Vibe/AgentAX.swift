import AppKit
import ApplicationServices

/// 只读 AX 工具。所有函数都在主线程调用，不缓存 AXUIElement。
@MainActor
enum AgentAX {
    static func value(_ element: AXUIElement, _ name: String) -> Any? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    static func string(_ element: AXUIElement, _ name: String) -> String {
        (value(element, name) as? String) ?? ""
    }

    static func bool(_ element: AXUIElement, _ name: String) -> Bool? {
        value(element, name) as? Bool
    }

    static func element(_ value: Any?) -> AXUIElement? {
        guard let value, CFGetTypeID(value as CFTypeRef) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func elements(_ value: Any?) -> [AXUIElement] {
        value as? [AXUIElement] ?? []
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        elements(value(element, kAXChildrenAttribute))
    }

    static func hasAction(_ element: AXUIElement, _ action: String) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let names = names as? [String] else { return false }
        return names.contains(action)
    }

    @discardableResult
    static func press(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    /// 优先按自身、再按子树找可 AXPress 的元素；列表行本身常常没有 AXPress，按钮在子节点里。
    static func firstPressable(in root: AXUIElement, maxDepth: Int = 8) -> AXUIElement? {
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        var seen = Set<AXUIElement>()
        while let (element, depth) = stack.popLast() {
            guard seen.insert(element).inserted else { continue }
            if hasAction(element, kAXPressAction as String) { return element }
            guard depth < maxDepth else { continue }
            for child in children(element).reversed() { stack.append((child, depth + 1)) }
        }
        return nil
    }

    /// 前序遍历，限制深度和节点数，避免 Electron 的巨大 AX 树拖住主线程。
    static func all(in root: AXUIElement, maxDepth: Int = 40, maxNodes: Int = 8_000,
                    where predicate: (AXUIElement) -> Bool) -> [AXUIElement] {
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        var seen = Set<AXUIElement>()
        var result: [AXUIElement] = []
        while let (element, depth) = stack.popLast(), seen.count < maxNodes {
            guard seen.insert(element).inserted else { continue }
            if predicate(element) { result.append(element) }
            guard depth < maxDepth else { continue }
            for child in children(element).reversed() {
                stack.append((child, depth + 1))
            }
        }
        return result
    }

    /// 解析快照里的路径；每次操作前重新取窗口再调用，避免缓存失效的 AXUIElement。
    static func element(at path: [Int], in root: AXUIElement) -> AXUIElement? {
        var current = root
        for index in path {
            let kids = children(current)
            guard kids.indices.contains(index) else { return nil }
            current = kids[index]
        }
        return current
    }
}

/// 纯数据快照，可安全跨线程传递，也方便用合成树做单测。
nonisolated struct AXSnapshotNode: Sendable {
    struct Rect: Equatable, Sendable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        var maxX: Double { x + width }
        var midX: Double { x + width / 2 }
        var area: Double { max(0, width) * max(0, height) }
        var isEmpty: Bool { width <= 0 || height <= 0 }
    }

    let role: String
    let subrole: String
    let title: String
    let description: String
    let value: String
    let placeholder: String
    let actions: Set<String>
    let selected: Bool
    let ariaCurrent: Bool
    let enabled: Bool
    let rect: Rect
    let children: [AXSnapshotNode]

    var isPressable: Bool { actions.contains("AXPress") }

    var nodeCount: Int {
        1 + children.reduce(0) { $0 + $1.nodeCount }
    }

    init(role: String, subrole: String = "", title: String = "", description: String = "",
         value: String = "", placeholder: String = "", actions: Set<String> = [],
         selected: Bool = false, ariaCurrent: Bool = false, enabled: Bool = true,
         rect: Rect = .init(x: 0, y: 0, width: 0, height: 0), children: [AXSnapshotNode] = []) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.description = description
        self.value = value
        self.placeholder = placeholder
        self.actions = actions
        self.selected = selected
        self.ariaCurrent = ariaCurrent
        self.enabled = enabled
        self.rect = rect
        self.children = children
    }
}

/// 把当前窗口读成纯数据快照。用 `AXUIElementCopyMultipleAttributeValues` 批量读属性，
/// 避免每个节点十几次 IPC 把主线程拖住。
@MainActor
enum AXSnapshot {
    private static let attributes = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
        kAXValueAttribute, "AXPlaceholderValue", kAXSelectedAttribute, "AXARIACurrent",
        kAXEnabledAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute,
    ]
    private static let actionableRoles: Set<String> = [
        "AXButton", "AXGroup", "AXRow", "AXCell", "AXLink", "AXRadioButton",
        "AXCheckBox", "AXTabButton", "AXListItem", "AXColumn",
    ]

    static func capture(window: AXUIElement, maxDepth: Int = 45, maxNodes: Int = 12_000) -> AXSnapshotNode {
        var count = 0

        func build(_ element: AXUIElement, _ depth: Int) -> AXSnapshotNode {
            count += 1
            let raw = multipleAttributes(element)
            let role = raw[0] as? String ?? ""
            let children: [AXSnapshotNode]
            if depth < maxDepth, count < maxNodes {
                children = AgentAX.elements(raw[11]).compactMap { child in
                    // 不能按 AXUIElement 去重：Chrome 会把同一节点挂在多个父节点下，
                    // 去重后快照的子节点下标和真实 AXChildren 错位，按路径就按不到会话行。
                    guard count < maxNodes else { return nil }
                    return build(child, depth + 1)
                }
            } else {
                children = []
            }
            let actions: Set<String>
            if actionableRoles.contains(role) {
                var names: CFArray?
                if AXUIElementCopyActionNames(element, &names) == .success,
                   let list = names as? [String] {
                    actions = Set(list)
                } else {
                    actions = []
                }
            } else {
                actions = []
            }
            return AXSnapshotNode(
                role: role,
                subrole: raw[1] as? String ?? "",
                title: raw[2] as? String ?? "",
                description: raw[3] as? String ?? "",
                value: raw[4] as? String ?? "",
                placeholder: raw[5] as? String ?? "",
                actions: actions,
                selected: raw[6] as? Bool ?? false,
                ariaCurrent: isTruthy(raw[7]),
                enabled: raw[8] as? Bool ?? true,
                rect: rect(raw[9], raw[10]),
                children: children)
        }

        return build(window, 0)
    }

    private static func multipleAttributes(_ element: AXUIElement) -> [Any?] {
        var values: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(
            element, attributes as CFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0), &values)
        guard error == .success, let list = values as? [Any] else {
            return attributes.map { AgentAX.value(element, $0) }
        }
        return list.map { item -> Any? in
            CFGetTypeID(item as CFTypeRef) == CFNullGetTypeID() ? nil : item
        }
    }

    private static func isTruthy(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.intValue != 0 }
        if let text = value as? String { return !text.isEmpty && text != "0" && text != "false" }
        return false
    }

    private static func rect(_ position: Any?, _ size: Any?) -> AXSnapshotNode.Rect {
        var point = CGPoint.zero
        var extent = CGSize.zero
        if let position, CFGetTypeID(position as CFTypeRef) == AXValueGetTypeID() {
            AXValueGetValue(position as! AXValue, .cgPoint, &point)
        }
        if let size, CFGetTypeID(size as CFTypeRef) == AXValueGetTypeID() {
            AXValueGetValue(size as! AXValue, .cgSize, &extent)
        }
        return .init(x: point.x, y: point.y, width: extent.width, height: extent.height)
    }
}
