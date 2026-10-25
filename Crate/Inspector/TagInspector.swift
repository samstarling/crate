import RekordboxKit
import SwiftUI

/// The inspector showing every tag in the selected track's audio file.
struct TagInspector: View {
    /// The `UserDefaults` key remembering whether the inspector is shown.
    static let visibilityKey = "ShowsTagInspector"

    let selectedTracks: [Track]

    var body: some View {
        switch selectedTracks.count {
        case 0:
            ContentUnavailableView("No Selection", systemImage: "tag", description: Text("Select a track to see its file\u{2019}s tags."))
        case 1:
            TrackTags(track: selectedTracks[0])
        default:
            ContentUnavailableView("\(selectedTracks.count) Tracks Selected", systemImage: "tag", description: Text("Select a single track to see its file\u{2019}s tags."))
        }
    }
}

/// Loads and shows one track's tags.
private struct TrackTags: View {
    let track: Track
    @State private var tags: Result<FileTags, Error>?

    var body: some View {
        Group {
            switch tags {
            case nil:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .success(let tags) where tags.isEmpty:
                ContentUnavailableView("No Tags", systemImage: "tag.slash", description: Text("\u{201C}\(track.fileURL.lastPathComponent)\u{201D} has no tags."))
            case .success(let tags):
                TagList(fileName: track.fileURL.lastPathComponent, tags: tags)
            case .failure(let error):
                ContentUnavailableView("Can\u{2019}t Read Tags", systemImage: "exclamationmark.triangle", description: Text(error.localizedDescription))
            }
        }
        .task(id: track.fileURL) {
            tags = nil
            let url = track.fileURL
            guard FileManager.default.fileExists(atPath: url.path) else {
                tags = .failure(CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: url.path]))
                return
            }
            do {
                let loaded = try await FileTags.load(from: url)
                guard !Task.isCancelled else { return }
                tags = .success(loaded)
            } catch is CancellationError {
                return
            } catch {
                tags = .failure(error)
            }
        }
    }
}

struct TagList: View {
    let fileName: String
    let tags: FileTags
    /// The tag formats the user has collapsed, one per line, remembered from track to track.
    @AppStorage("CollapsedTagGroups") private var collapsedGroups = ""

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("File")
                    Text(fileName)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ForEach(tags.groups) { group in
                Section(group.name, isExpanded: isExpanded(group)) {
                    ForEach(group.tags) { tag in
                        TagRow(tag: tag)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func isExpanded(_ group: FileTags.Group) -> Binding<Bool> {
        Binding {
            !collapsedGroups.split(separator: "\n").contains(Substring(group.id))
        } set: { isExpanded in
            var collapsed = Set(collapsedGroups.split(separator: "\n").map(String.init))
            if isExpanded {
                collapsed.remove(group.id)
            } else {
                collapsed.insert(group.id)
            }
            collapsedGroups = collapsed.sorted().joined(separator: "\n")
        }
    }
}

private struct TagRow: View {
    let tag: FileTags.Tag

    var body: some View {
        Group {
            switch tag.value {
            case .text(let text) where text.contains("\n"):
                stacked { value(text) }
            case .text(let text):
                // Beside the label if it fits on one line, otherwise underneath, so long values such
                // as MusicBrainz IDs aren't squeezed into a narrow column.
                ViewThatFits(in: .horizontal) {
                    inline { value(text) }
                    stacked { value(text) }
                }
            case .image(let image):
                stacked {
                    Image(image, scale: 2, label: Text(tag.name))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 160, maxHeight: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            case .data(let byteCount):
                inline { Text(Int64(byteCount).formatted(.byteCount(style: .file))) }
            }
        }
        .help(tag.detail)
        .contextMenu {
            if case .text(let text) = tag.value {
                Button("Copy Value") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
        }
    }

    @ViewBuilder
    private func value(_ text: String) -> some View {
        let value = Text(text.isEmpty ? "\u{2014}" : text).foregroundStyle(.secondary)
        if text.count > 300 {
            // Some values run to thousands of characters, such as AcoustID fingerprints, so they're
            // cut short; Copy Value still copies all of it. They can't also be selectable, because
            // selectable text ignores its line limit once clicked, and spills over the rows below.
            value.lineLimit(4)
        } else {
            value.textSelection(.enabled)
        }
    }

    private func inline(@ViewBuilder _ value: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(tag.name)
            Spacer(minLength: 12)
            value()
        }
    }

    private func stacked(@ViewBuilder _ value: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tag.name)
            value()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview("Tags") {
    TagList(fileName: "Night Drive.mp3", tags: FileTags(groups: [
        FileTags.Group(name: "ID3v2.4", tags: [
            .init(id: 0, name: "Title", detail: "TIT2", value: .text("Night Drive")),
            .init(id: 1, name: "Artist", detail: "TPE1", value: .text("Halcyon Static")),
            .init(id: 2, name: "Composer", detail: "TCOM", value: .text("Mara Vey\nOttoline")),
            .init(id: 3, name: "BPM", detail: "TBPM", value: .text("122")),
            .init(id: 4, name: "Comment", detail: "COMM", value: .text("Lovely warm-up track, plays well after something deeper.")),
            .init(id: 5, name: "SERATO_PLAYCOUNT", detail: "TXXX (User Text)", value: .text("4")),
            .init(id: 6, name: "MusicBrainz Artist Id", detail: "TXXX (User Text)", value: .text("37a0943e-9638-48fe-9a56-7192d7efbbed")),
            .init(id: 7, name: "Private", detail: "PRIV", value: .data(byteCount: 2_048)),
        ]),
        FileTags.Group(name: "ID3v1", tags: [
            .init(id: 0, name: "Title", detail: "", value: .text("Night Drive")),
            .init(id: 1, name: "Genre", detail: "", value: .text("House")),
        ]),
    ]))
    .frame(width: 300, height: 500)
}

#Preview("Nothing selected") {
    TagInspector(selectedTracks: [])
        .frame(width: 300, height: 300)
}

#Preview("Several selected") {
    TagInspector(selectedTracks: Array(Track.previews.prefix(3)))
        .frame(width: 300, height: 300)
}
