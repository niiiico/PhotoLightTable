import Foundation

/// Whether an event should be treated as hidden.
///
/// Photos does not hide albums, and for Photos that is the right call: album
/// membership there is open-ended, and an album that locks itself the moment
/// somebody hides one photograph in it would be a trap. Here the membership is
/// fixed at import — a Lightroom collection is a list somebody made by hand,
/// and it does not change under us — so the question has an answer.
///
/// All, not any. An event of a hundred photographs where one has been hidden is
/// an ordinary event with one photograph missing from it; an event where every
/// single one is hidden is a hidden event, and showing its contents would undo
/// the hiding.
enum EventPrivacy {
    static func isHidden(memberIDs: [String], hiddenIDs: Set<String>) -> Bool {
        guard !memberIDs.isEmpty else { return false }
        return memberIDs.allSatisfy { hiddenIDs.contains($0) }
    }
}
