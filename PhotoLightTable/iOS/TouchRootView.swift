#if !os(macOS)
import SwiftData
import SwiftUI

/// Placeholder iOS shell.
///
/// This exists so the shared layer is exercised on iOS from the first commit —
/// permission, fetching, thumbnail loading and the rating store all run here.
/// The real touch culling UI (swipe to pick/reject, loupe, events) replaces it
/// in a later step; nothing here is meant to be the final design.
struct TouchRootView: View {
    @EnvironmentObject private var library: PhotoLibraryService
    @EnvironmentObject private var ratings: RatingStore
    @Query private var events: [LightTableEvent]

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 3)]

    var body: some View {
        NavigationStack {
            Group {
                switch library.authState {
                case .undetermined:
                    ProgressView("Waiting for photo library access…")
                case .denied:
                    ContentUnavailableView {
                        Label("No access to your photos", systemImage: "lock.fill")
                    } description: {
                        Text("Grant access in Settings ▸ Privacy & Security ▸ Photos.")
                    } actions: {
                        Button("Open Settings") { Platform.openPhotoPrivacySettings() }
                    }
                case .authorized, .limited:
                    grid
                }
            }
            .navigationTitle("Light Table")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Text("\(library.items.count)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task { await library.requestAccess() }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(library.items) { item in
                    ThumbnailCell(item: item,
                                  size: 110,
                                  rating: ratings.rating(for: item.id),
                                  isSelected: false,
                                  isFocused: false,
                                  showsSelectionBadge: false,
                                  imageVersion: 0)
                }
            }
            .padding(3)
        }
    }
}
#endif
