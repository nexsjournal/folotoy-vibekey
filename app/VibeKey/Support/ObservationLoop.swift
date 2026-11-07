import Observation

/// 在非 SwiftUI 代码里监听 @Observable 属性变化:`read` 里读到的属性任一变化时调用 `onChange`,并持续监听。
@MainActor
func observeChanges(_ read: @escaping @MainActor () -> Void, onChange: @escaping @MainActor () -> Void) {
    withObservationTracking {
        read()
    } onChange: {
        Task { @MainActor in
            onChange()
            observeChanges(read, onChange: onChange)
        }
    }
}
