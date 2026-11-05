import Foundation
import Testing
@testable import Kaset

// MARK: - UploadsParsingTests

@Suite(.tags(.parser))
struct UploadsParsingTests {
    private static let artistDetailId = "FEmusic_library_privately_owned_artist_detaila_po_omar"
    private static let releaseDetailId = "FEmusic_library_privately_owned_release_detailb_po_omar"

    @Test("Parse uploaded artists from the selected Uploads tab")
    func parseUploadedArtistsPage() {
        let shelf: [String: Any] = [
            "contents": [
                Self.artistRow(id: Self.artistDetailId, name: "Omar Naber", count: "10 songs"),
                Self.artistRow(id: "UCcatalog", name: "Catalog Artist", count: "1 song"),
            ],
            "continuations": [["nextContinuationData": ["continuation": "next-token"]]],
        ]
        let data: [String: Any] = [
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [
                        ["tabRenderer": ["content": ["sectionListRenderer": ["contents": [[String: Any]]()]]]],
                        [
                            "tabRenderer": [
                                "selected": true,
                                "content": ["sectionListRenderer": ["contents": [["musicShelfRenderer": shelf]]]],
                            ],
                        ],
                    ],
                ],
            ],
        ]

        let (artists, token) = LibraryContentParser.parseUploadedArtistsPage(data)

        #expect(artists.map(\.id) == [Self.artistDetailId])
        #expect(artists.first?.name == "Omar Naber")
        #expect(artists.first?.subtitle == "10 songs")
        #expect(token == "next-token")
    }

    @Test("Parse uploaded artists continuation")
    func parseUploadedArtistsContinuation() {
        let data: [String: Any] = [
            "continuationContents": [
                "musicShelfContinuation": [
                    "contents": [Self.artistRow(id: Self.artistDetailId, name: "Omar Naber", count: "10 songs")],
                ],
            ],
        ]

        let (artists, token) = LibraryContentParser.parseUploadedArtistsContinuation(data)

        #expect(artists.map(\.name) == ["Omar Naber"])
        #expect(token == nil)
    }

    @Test("Uploaded track rows keep the artist linked to the uploads artist page")
    func uploadedTrackRowKeepsArtistName() {
        let row: [String: Any] = [
            "flexColumns": [
                Self.flexColumn(["text": "Krasen Dan"]),
                Self.flexColumn([
                    "text": "Omar Naber",
                    "navigationEndpoint": ["browseEndpoint": ["browseId": Self.artistDetailId]],
                ]),
            ],
        ]

        let artists = ParsingHelpers.extractArtistsFromFlexColumns(row)

        #expect(artists.map(\.name) == ["Omar Naber"])
        #expect(artists.first.map { Artist.isNavigableId($0.id) } == false)
    }

    @Test("Uploads browse IDs are uploads, load as-is, and have no library toggle")
    func uploadsBrowseIds() {
        for id in [Self.artistDetailId, Self.releaseDetailId, "FEmusic_library_privately_owned_tracks"] {
            let playlist = Playlist(id: id, title: "Uploads", description: nil, thumbnailURL: nil, trackCount: nil)
            #expect(playlist.isUploads)
            #expect(!playlist.supportsLibraryToggle)
            #expect(YTMusicClient.playlistBrowseId(for: id) == id)
        }
    }

    private static func artistRow(id: String, name: String, count: String) -> [String: Any] {
        [
            "musicResponsiveListItemRenderer": [
                "navigationEndpoint": ["browseEndpoint": ["browseId": id]],
                "flexColumns": [Self.flexColumn(["text": name]), Self.flexColumn(["text": count])],
            ],
        ]
    }

    private static func flexColumn(_ run: [String: Any]) -> [String: Any] {
        ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [run]]]]
    }
}

// MARK: - UploadsLibraryViewModelTests

@Suite(.serialized, .tags(.viewModel), .timeLimit(.minutes(1)))
@MainActor
struct UploadsLibraryViewModelTests {
    let mockClient = MockYTMusicClient()
    let viewModel: LibraryViewModel

    init() {
        self.viewModel = LibraryViewModel(client: self.mockClient, registerForLibraryMutations: false)
        self.mockClient.uploadedAlbums = [TestFixtures.makeAlbum(id: "FEmusic_library_privately_owned_release_detail1")]
        self.mockClient.uploadedArtists = [
            Artist(id: "FEmusic_library_privately_owned_artist_detail1", name: "Omar Naber", subtitle: "10 songs"),
        ]
    }

    @Test("Uploads load once until refreshed")
    func loadUploadsIfNeededLoadsOnce() async {
        await self.viewModel.loadUploadsIfNeeded()
        await self.viewModel.loadUploadsIfNeeded()

        #expect(self.viewModel.uploadsLoadingState == .loaded)
        #expect(self.viewModel.uploadedAlbums.count == 1)
        #expect(self.viewModel.uploadedArtists.map(\.name) == ["Omar Naber"])
        #expect(self.mockClient.getUploadedAlbumsCallCount == 1)
        #expect(self.mockClient.getUploadedArtistsCallCount == 1)
    }

    @Test("Failed uploads load is retried")
    func failedUploadsLoadIsRetried() async {
        self.mockClient.shouldThrowError = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))
        await self.viewModel.loadUploadsIfNeeded()
        guard case .error = self.viewModel.uploadsLoadingState else {
            Issue.record("Expected error state, got \(self.viewModel.uploadsLoadingState)")
            return
        }

        self.mockClient.shouldThrowError = nil
        await self.viewModel.loadUploadsIfNeeded()

        #expect(self.viewModel.uploadsLoadingState == .loaded)
        #expect(self.viewModel.uploadedAlbums.count == 1)
    }

    @Test("Switching accounts clears uploads")
    func accountSwitchClearsUploads() async {
        self.viewModel.activateAccountScope("account-a")
        await self.viewModel.loadUploadsIfNeeded()

        self.viewModel.activateAccountScope("account-b")

        #expect(self.viewModel.uploadedAlbums.isEmpty)
        #expect(self.viewModel.uploadedArtists.isEmpty)
        #expect(self.viewModel.uploadsLoadingState == .idle)
    }
}
