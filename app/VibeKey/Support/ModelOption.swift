import Foundation

/// 下拉选择里的一个模型:`id` 是发给接口的模型名,`title` 是给人看的名字(没有就显示 id)。
/// 用于 LLM 模型和云端识别模型的选择(ModelPickerField)。
nonisolated struct ModelOption: Identifiable, Hashable, Sendable {
    let id: String
    var title: String?

    var displayName: String { title.map { "\($0) · \(id)" } ?? id }

    static func ids(_ ids: [String]) -> [ModelOption] { ids.map { ModelOption(id: $0) } }
}
