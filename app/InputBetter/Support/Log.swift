import os

nonisolated enum Log {
    static let subsystem = "com.inputbetter.InputBetter"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let asr = Logger(subsystem: subsystem, category: "asr")
    static let models = Logger(subsystem: subsystem, category: "models")
    static let dictation = Logger(subsystem: subsystem, category: "dictation")
    static let llm = Logger(subsystem: subsystem, category: "llm")
    static let subtitles = Logger(subsystem: subsystem, category: "subtitles")
    static let update = Logger(subsystem: subsystem, category: "update")
}
