import Foundation

@MainActor
public final class PasteboardPollingMonitor: NSObject {
  public typealias OutcomeHandler = @MainActor (CaptureOutcome) -> Void

  private let service: ClipboardCaptureService
  private let interval: TimeInterval
  private let onOutcome: OutcomeHandler
  private var timer: Timer?
  private var pollTask: Task<Void, Never>?

  public init(
    service: ClipboardCaptureService,
    interval: TimeInterval = 0.5,
    onOutcome: @escaping OutcomeHandler
  ) {
    self.service = service
    self.interval = interval
    self.onOutcome = onOutcome
  }

  public func start() {
    guard timer == nil else { return }
    let timer = Timer.scheduledTimer(
      timeInterval: interval,
      target: self,
      selector: #selector(timerFired),
      userInfo: nil,
      repeats: true
    )
    timer.tolerance = interval * 0.2
    self.timer = timer
  }

  public func stop() {
    timer?.invalidate()
    timer = nil
    pollTask?.cancel()
  }

  @objc private func timerFired() {
    guard pollTask == nil else { return }
    pollTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let outcome = await service.pollOnce()
      guard !Task.isCancelled else {
        pollTask = nil
        return
      }
      if outcome != .noChange {
        onOutcome(outcome)
      }
      pollTask = nil
    }
  }
}
