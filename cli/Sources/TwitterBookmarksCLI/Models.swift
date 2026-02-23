import Foundation

struct Bookmark: Codable {
    let id: String
    let authorName: String
    let authorHandle: String
    let text: String
    let url: String
    let timestamp: String
    let likes: Int
    let retweets: Int
    let replies: Int
    let bookmarks: Int
    let hasMedia: Bool
}
