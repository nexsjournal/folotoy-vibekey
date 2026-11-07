import Foundation

/// Soniox REST 接口:目前只用到模型列表(`GET https://api.soniox.com/v1/models`,Bearer 鉴权)。
/// 文档:https://soniox.com/docs/openapi.yaml(get_models)。
nonisolated enum SonioxAPI {
    static let modelsURL = URL(string: "https://api.soniox.com/v1/models")!

    /// 拉取可用于实时识别的模型。
    static func realtimeModels(apiKey: String, session: URLSession = .shared) async throws -> [ModelOption] {
        var request = URLRequest(url: modelsURL, timeoutInterval: 15)
        request.setValue("Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CloudASRError.server(errorMessage(data, status: http.statusCode))
        }
        return try parseRealtimeModels(data)
    }

    /// 解析 `{"models":[{"id","name","transcription_mode","aliased_model_id"}]}`:
    /// 只保留实时模型,并去掉别名(别名指向的正式模型已在列表里,避免重复)。
    static func parseRealtimeModels(_ data: Data) throws -> [ModelOption] {
        guard let models = CloudJSON.object(data)?["models"] as? [[String: Any]] else {
            throw OpenAICompatibleAPI.APIError.unexpectedResponse
        }
        return models.compactMap { model in
            guard let id = model["id"] as? String,
                  model["transcription_mode"] as? String == "real_time",
                  model["aliased_model_id"] as? String == nil else { return nil }
            let name = (model["name"] as? String).flatMap { $0.isEmpty || $0 == id ? nil : $0 }
            return ModelOption(id: id, title: name.map { "\($0) · \(id)" } ?? id)
        }
        .sorted { $0.id.localizedStandardCompare($1.id) == .orderedDescending }
    }

    /// 错误响应 `{"message": …, "error_type": …}` 里取可读的说明。
    static func errorMessage(_ data: Data, status: Int) -> String {
        let object = CloudJSON.object(data)
        let message = object?["message"] as? String ?? object?["error_message"] as? String
        if status == 401 || status == 403 {
            return String(localized: "API Key 无效或没有权限（HTTP \(status)）", bundle: .l10n)
        }
        return message.map { "HTTP \(status): \($0)" } ?? "HTTP \(status)"
    }
}
