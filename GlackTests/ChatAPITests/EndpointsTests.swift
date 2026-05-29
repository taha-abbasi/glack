import Testing
import Foundation
@testable import Glack

@Suite("Chat API endpoints")
struct EndpointsTests {
    @Test("listSpaces uses spaces collection with page size")
    func listSpacesURL() {
        let url = ChatEndpoint.listSpaces(pageToken: nil, pageSize: 500)
        #expect(url.absoluteString.hasPrefix("https://chat.googleapis.com/v1/spaces"))
        #expect(url.absoluteString.contains("pageSize=500"))
        #expect(!url.absoluteString.contains("pageToken="))
    }

    @Test("listSpaces forwards the page token when present")
    func listSpacesPagination() {
        let url = ChatEndpoint.listSpaces(pageToken: "PAGE-2", pageSize: 1000)
        #expect(url.absoluteString.contains("pageToken=PAGE-2"))
    }

    @Test("listMessages nests under the space resource and applies orderBy")
    func listMessagesURL() {
        let url = ChatEndpoint.listMessages(
            spaceID: "spaces/AAAAAAAAAA",
            pageToken: nil,
            pageSize: 100,
            orderBy: "createTime desc"
        )
        #expect(url.absoluteString.contains("/v1/spaces/AAAAAAAAAA/messages"))
        // " " → "%20" in URL encoding.
        #expect(url.absoluteString.contains("orderBy=createTime%20desc")
                || url.absoluteString.contains("orderBy=createTime+desc"))
    }

    @Test("listMembers nests under the space resource")
    func listMembersURL() {
        let url = ChatEndpoint.listMembers(spaceID: "spaces/BBBBBBBBBB")
        #expect(url.absoluteString.contains("/v1/spaces/BBBBBBBBBB/members"))
    }
}
