import Testing

struct TranscriptionPlanTests {
    @Test(arguments: [true, false], [true, false])
    func cpuEnginesAlwaysRunUnderABackgroundTask(inFront: Bool, gpu: Bool) {
        #expect(TranscriptionPlan.choose(usesGPU: false, inFront: inFront, continuedProcessing: gpu, backgroundGPU: gpu) == .backgroundTask)
    }

    @Test(arguments: [true, false], [true, false])
    func gpuEnginesWaitWhileInTheBackground(continued: Bool, gpu: Bool) {
        #expect(TranscriptionPlan.choose(usesGPU: true, inFront: false, continuedProcessing: continued, backgroundGPU: gpu) == .queue)
    }

    @Test func gpuEnginesUseContinuedProcessingOnlyWithBackgroundGPU() {
        #expect(TranscriptionPlan.choose(usesGPU: true, inFront: true, continuedProcessing: true, backgroundGPU: true) == .continuedProcessing)
        #expect(TranscriptionPlan.choose(usesGPU: true, inFront: true, continuedProcessing: true, backgroundGPU: false) == .foreground)
        #expect(TranscriptionPlan.choose(usesGPU: true, inFront: true, continuedProcessing: false, backgroundGPU: false) == .foreground)
    }
}
