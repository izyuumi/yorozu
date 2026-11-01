import Foundation

/// Where a finished clip is transcribed. iOS denies the GPU to an app in the background, so an engine that needs it
/// runs only in front, or in a continued-processing task (iOS 26) where the device lets that task keep the GPU;
/// engines on the CPU and Neural Engine keep going under a background task.
enum TranscriptionPlan: Equatable, Sendable {
    /// Now, under a background task, so leaving the app doesn't stop it.
    case backgroundTask
    /// Now, inside a continued-processing task that keeps the GPU in the background.
    case continuedProcessing
    /// Now, in front; leaving the app fails it and the clip waits.
    case foreground
    /// Later, once the app is in front.
    case queue

    /// `continuedProcessing`: the system takes continued-processing requests (iOS 26); they can be submitted only
    /// while the app is in front. `backgroundGPU`: such a task may use the GPU on this device.
    static func choose(usesGPU: Bool, inFront: Bool, continuedProcessing: Bool, backgroundGPU: Bool) -> Self {
        guard usesGPU else { return .backgroundTask }
        guard inFront else { return .queue }
        return continuedProcessing && backgroundGPU ? .continuedProcessing : .foreground
    }
}
