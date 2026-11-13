import Network
import os
import SwiftUI
import UIKit

/// Request to open the Commons photo picker for one species photo role.
struct ChooseSpeciesPhotoRequest: Identifiable, Hashable {
    var id: String { "\(speciesId)|\(role)" }
    var speciesId: String
    var commonName: String
    var scientificName: String
    var alsoCalled: [String]
    var alsoScientific: [String]
    var aliases: [String]
    var dimorphic: Bool
    /// Commons / cache role: male, female, either, or unsexed.
    var role: String
    /// Commons file title already in use — excluded from search results.
    var currentFileTitle: String
}

/// Lets the user replace a poor species photo with another open-licence Commons image.
struct ChooseSpeciesPhotoSheet: View {
    @EnvironmentObject private var model: GuideModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var request: ChooseSpeciesPhotoRequest

    @StateObject private var controller = ChooseSpeciesPhotoController()

    var body: some View {
        NavigationStack {
            Group {
                switch controller.phase {
                case .searching:
                    searchingState
                case .empty:
                    messageState(
                        title: "No other photos found",
                        detail: "Wikimedia Commons did not return another openly licensed match for this \(rolePhrase). Try again later, or keep the current photo."
                    )
                case .failed(let message):
                    messageState(title: "Couldn’t load photos", detail: message, showRetry: true)
                case .saving:
                    savingState
                case .ready:
                    candidateList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .guideBackground()
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(controller.phase == .saving ? "Please wait" : "Cancel") {
                        guard controller.phase != .saving else { return }
                        controller.cancel()
                        dismiss()
                    }
                    .disabled(controller.phase == .saving)
                }
            }
            .interactiveDismissDisabled(controller.phase == .saving)
        }
        .tint(GuideColor.rust)
        .presentationDetents(horizontalSizeClass == .regular ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
        .task(id: request.id) {
            await controller.start(request: request)
        }
        .onDisappear {
            controller.cancel()
        }
    }

    private var navigationTitle: String {
        switch request.role {
        case "male": return "Choose male photo"
        case "female": return "Choose female photo"
        default: return "Choose different photo"
        }
    }

    private var rolePhrase: String {
        switch request.role {
        case "male": return "male"
        case "female": return "female"
        default: return "species"
        }
    }

    private var searchingState: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
                .tint(GuideColor.green)
            Text("Searching open-licence photos…")
                .font(.system(.title3, design: .serif))
                .foregroundStyle(GuideColor.green)
            Text("Looking on Wikimedia Commons for PD, CC0, CC BY, CC BY-SA, and GFDL images of \(request.commonName).")
                .font(.subheadline)
                .foregroundStyle(GuideColor.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Searching open-licence photos")
    }

    private var savingState: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
                .tint(GuideColor.green)
            Text("Saving photo…")
                .font(.system(.title3, design: .serif))
                .foregroundStyle(GuideColor.green)
            Text("Downloading and caching the image on this device, with attribution for Photo Attr.")
                .font(.subheadline)
                .foregroundStyle(GuideColor.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func messageState(title: String, detail: String, showRetry: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(.title2, design: .serif))
                .foregroundStyle(GuideColor.green)
            Text(detail)
                .font(.body)
                .foregroundStyle(GuideColor.ink)
                .fixedSize(horizontal: false, vertical: true)
            if showRetry {
                Button {
                    Task { await controller.start(request: request) }
                } label: {
                    Text("Try again")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(GuideChipStyle(selected: true))
            }
            Button {
                dismiss()
            } label: {
                Text("Keep current photo")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(GuideChipStyle(selected: false))
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: 520, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var candidateList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Pick a better open-licence photo. Attribution is saved for the Photo Attr badge.")
                    .font(.subheadline)
                    .foregroundStyle(GuideColor.muted)
                    .fixedSize(horizontal: false, vertical: true)

                LazyVGrid(columns: gridColumns, spacing: 14) {
                    ForEach(controller.candidates, id: \.title) { candidate in
                        Button {
                            Task {
                                let ok = await controller.select(
                                    candidate,
                                    request: request,
                                    photoCache: model.photoCache
                                )
                                if ok { dismiss() }
                            }
                        } label: {
                            candidateCard(candidate)
                        }
                        .buttonStyle(.plain)
                        .disabled(controller.phase == .saving)
                        .accessibilityHint("Saves this photo for \(request.commonName)")
                    }
                }

                if let error = controller.selectionError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(GuideColor.rust)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
            .frame(maxWidth: detailMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var gridColumns: [GridItem] {
        if horizontalSizeClass == .regular {
            return [
                GridItem(.flexible(), spacing: 14),
                GridItem(.flexible(), spacing: 14),
            ]
        }
        return [GridItem(.flexible())]
    }

    private var detailMaxWidth: CGFloat {
        horizontalSizeClass == .regular ? 900 : 720
    }

    private func candidateCard(_ candidate: CommonsPhotoClient.Candidate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CommonsRemoteThumb(url: candidate.downloadURL)
                .frame(maxWidth: .infinity)
                .frame(height: horizontalSizeClass == .regular ? 200 : 180)
                .clipped()
                .background(GuideColor.green.opacity(0.08))

            Text(candidate.artist.isEmpty ? "Wikimedia Commons contributor" : candidate.artist)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(GuideColor.ink)
                .lineLimit(2)

            Text(candidate.license.isEmpty ? "Open licence" : candidate.license)
                .font(.caption)
                .foregroundStyle(GuideColor.green)

            if !candidate.description.isEmpty {
                Text(candidate.description)
                    .font(.caption)
                    .foregroundStyle(GuideColor.muted)
                    .lineLimit(3)
            }

            Text("Use this photo")
                .font(.caption.weight(.semibold))
                .foregroundStyle(GuideColor.rust)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GuideColor.card)
        .overlay {
            RoundedRectangle(cornerRadius: 2)
                .stroke(GuideColor.line, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: candidate))
    }

    private func accessibilityLabel(for candidate: CommonsPhotoClient.Candidate) -> String {
        let artist = candidate.artist.isEmpty ? "Wikimedia Commons contributor" : candidate.artist
        let license = candidate.license.isEmpty ? "open licence" : candidate.license
        return "Photo by \(artist), \(license)"
    }
}

// MARK: - Controller

@MainActor
final class ChooseSpeciesPhotoController: ObservableObject {
    enum Phase: Equatable {
        case searching
        case ready
        case empty
        case saving
        case failed(String)
    }

    @Published private(set) var phase: Phase = .searching
    @Published private(set) var candidates: [CommonsPhotoClient.Candidate] = []
    @Published private(set) var selectionError: String?

    private let client: CommonsPhotoClient
    private var task: Task<Void, Never>?

    init(client: CommonsPhotoClient = .shared) {
        self.client = client
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    func start(request: ChooseSpeciesPhotoRequest) async {
        cancel()
        phase = .searching
        candidates = []
        selectionError = nil

        if !(await Self.hasNetworkPath()) {
            phase = .failed("You’re offline. Connect to the internet to search Wikimedia Commons, then try again.")
            return
        }

        let request = request
        let client = client
        task = Task { [weak self] in
            guard let self else { return }
            do {
                var scientific = request.scientificName
                if scientific == "—" || scientific.isEmpty || scientific == "-" {
                    scientific = await client.resolveScientificName(
                        commonName: request.commonName,
                        hinted: request.scientificName
                    )
                }
                try Task.checkCancellation()
                let query = CommonsPhotoClient.SpeciesQuery(
                    commonName: request.commonName,
                    scientificName: scientific,
                    alsoCalled: request.alsoCalled,
                    alsoScientific: request.alsoScientific,
                    aliases: request.aliases
                )
                var avoid = Set<String>()
                if !request.currentFileTitle.isEmpty {
                    avoid.insert(request.currentFileTitle)
                }
                let searchRole = Self.normalizedRole(request.role)
                let found = try await client.searchCandidates(
                    species: query,
                    role: searchRole,
                    avoidTitles: avoid,
                    limit: 8
                )
                try Task.checkCancellation()
                self.candidates = found
                self.phase = found.isEmpty ? .empty : .ready
            } catch is CancellationError {
                // Sheet dismissed or a newer search started.
            } catch {
                if Self.looksOffline(error) {
                    self.phase = .failed("You’re offline. Connect to the internet to search Wikimedia Commons, then try again.")
                } else {
                    self.phase = .failed("Something went wrong reaching Wikimedia Commons. Check your connection and try again.")
                }
            }
        }
        await task?.value
    }

    func select(
        _ candidate: CommonsPhotoClient.Candidate,
        request: ChooseSpeciesPhotoRequest,
        photoCache: PhotoCacheStore
    ) async -> Bool {
        selectionError = nil
        phase = .saving
        let role = Self.normalizedRole(request.role)
        do {
            let (data, width, height) = try await client.downloadJPEG(from: candidate.downloadURL)
            try Task.checkCancellation()
            let token = String(UUID().uuidString.prefix(8)).lowercased()
            // Drop any previous cached image for this logical slot (including illustration → either).
            let previousEntry = photoCache.entry(forSpeciesId: request.speciesId)
            let previous = previousEntry?.photos.first(where: { $0.role == role })
                ?? previousEntry?.photos.first(where: { $0.role == request.role })
            let path = try photoCache.writeImageData(
                data,
                speciesId: request.speciesId,
                role: role,
                token: token
            )
            let photo = CommonsPhotoClient.makePhoto(
                speciesId: request.speciesId,
                commonName: request.commonName,
                role: role,
                candidate: candidate,
                relativePath: path,
                width: width,
                height: height
            )
            photoCache.savePhotos(
                speciesId: request.speciesId,
                commonName: request.commonName,
                scientificName: request.scientificName == "—" ? nil : request.scientificName,
                dimorphic: request.dimorphic,
                photos: [photo]
            )
            if let previous, previous.src != path {
                photoCache.removeImageFile(atRelativePath: previous.src)
            }
            return true
        } catch is CancellationError {
            phase = .ready
            return false
        } catch {
            phase = .ready
            if Self.looksOffline(error) {
                selectionError = "Download failed — you’re offline. Try again when connected."
            } else {
                selectionError = "Couldn’t download that image. Pick another, or try again."
            }
            return false
        }
    }

    /// Historical illustrations are replaced with a normal species photo slot.
    private static func normalizedRole(_ role: String) -> String {
        role == "illustration" ? "either" : role
    }

    private static func hasNetworkPath() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "handy.choose-photo.path")
            let resumed = OSAllocatedUnfairLock(initialState: false)
            monitor.pathUpdateHandler = { path in
                let shouldResume = resumed.withLock { didResume -> Bool in
                    guard !didResume else { return false }
                    didResume = true
                    return true
                }
                guard shouldResume else { return }
                monitor.cancel()
                continuation.resume(returning: path.status == .satisfied)
            }
            monitor.start(queue: queue)
        }
    }

    private static func looksOffline(_ error: Error) -> Bool {
        let urlError = error as? URLError
        switch urlError?.code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }
}

// MARK: - Remote thumb

private struct CommonsRemoteThumb: View {
    var url: URL

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if failed {
                GuideColor.green.opacity(0.12)
                    .overlay {
                        Text("Preview unavailable")
                            .font(.caption)
                            .foregroundStyle(GuideColor.muted)
                    }
            } else {
                GuideColor.green.opacity(0.12)
                    .overlay { ProgressView().controlSize(.small) }
            }
        }
        .task(id: url.absoluteString) {
            failed = false
            image = nil
            do {
                let loaded = try await Self.load(url: url)
                image = loaded
            } catch {
                failed = true
            }
        }
    }

    private static func load(url: URL) async throws -> UIImage {
        var request = URLRequest(url: url)
        request.setValue(
            "HandyFieldGuide/1.0 (iOS field guide; https://github.com/mulroneyp/mulroneyp; open-licence photos)",
            forHTTPHeaderField: "User-Agent"
        )
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        guard let image = UIImage(data: data) else {
            throw URLError(.cannotDecodeContentData)
        }
        return image
    }
}
