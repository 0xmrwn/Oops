import Darwin
import OopsCore

/// Where a dictation's audio comes from: the microphone, or a WAV file standing in for it. A source writes
/// mono Float32 samples at its own rate into the ring it is opened with, in blocks stamped with when their
/// last sample was captured, until it is closed.
protocol DictationAudioSource: AnyObject, Sendable {
    /// Starts delivering into `ring` and returns the samples' rate. Opening a source that is open restarts it.
    func open(into ring: DictationAudioRing) throws(DictationAudioError) -> Double
    /// Stops delivering. Once it returns, nothing more is written into the ring.
    func close()
}

enum DictationAudioError: Error, Equatable, Sendable {
    /// Microphone access is not granted. The source never asks: the session does, at a press that finds access never asked.
    case microphoneAccess(DictationMicrophoneAccess)
    /// No input device, or one whose format cannot be read.
    case noInput
    case unreadableFile(String)
    case failed(String)
}

extension CaptureInstant {
    /// Now, on the host clock microphone timestamps and key events use (`mach_absolute_time`, as nanoseconds).
    static func now() -> CaptureInstant { CaptureInstant(nanoseconds: clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) }

    /// Converts host time ticks (`mach_absolute_time`) to nanoseconds with a timebase read up front, so the
    /// audio thread never reads it itself.
    struct HostClock: Sendable {
        let numerator: UInt64
        let denominator: UInt64

        init() {
            var timebase = mach_timebase_info_data_t()
            mach_timebase_info(&timebase)
            numerator = UInt64(max(timebase.numer, 1)); denominator = UInt64(max(timebase.denom, 1))
        }

        func instant(ticks: UInt64) -> CaptureInstant {
            guard numerator != denominator else { return CaptureInstant(nanoseconds: ticks) }
            return CaptureInstant(nanoseconds: denominator.dividingFullWidth(ticks.multipliedFullWidth(by: numerator)).quotient)
        }
    }
}
