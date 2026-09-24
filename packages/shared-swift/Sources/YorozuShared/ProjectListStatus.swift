/// Distinguishes an empty answer from a request that has not reached the host Mac yet.
public enum ProjectListStatus: Equatable, Sendable {
    case loading, ready, offline, failed
}
