import Foundation

/// Where the eye was in each scope.
///
/// Leaving an album and coming back to it used to land on the newest photograph
/// — which, after making an event out of a run you were part-way through, is
/// several thousand frames from where you were. This remembers the photograph
/// you were on, per scope, and hands it back on return.
///
/// Generic over the scope rather than tied to `LibrarySelection`, so the rule
/// can be exercised without a SwiftData store behind it to mint identifiers.
/// The same move as `LibraryProjection.stacked` and `TemporalPhoto`.
struct ScopeMemory<Scope: Hashable> {
    private var focusByScope: [Scope: String] = [:]

    /// Nothing is remembered for a scope never visited, which is the difference
    /// between "put me back" and "start at the top".
    func focus(in scope: Scope) -> String? {
        focusByScope[scope]
    }

    mutating func remember(_ id: String, in scope: Scope) {
        focusByScope[scope] = id
    }

    /// Dropped when the photograph itself is gone — a remembered identifier
    /// that no longer resolves would scroll to nothing and read as the memory
    /// having failed rather than the photograph having left.
    mutating func forget(_ id: String) {
        focusByScope = focusByScope.filter { $0.value != id }
    }
}
