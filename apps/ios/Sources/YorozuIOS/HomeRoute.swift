import SwiftUI

struct HomeRoute: Equatable {
    enum Section: Hashable { case chats, crons }

    var section = Section.chats
    var selection: String?
    var columns = LaunchColumns.initial

    mutating func openRequested(_ convId: String) {
        open(convId)
        columns = LaunchColumns.afterRequestedOpen(columns)
    }

    mutating func open(_ convId: String) {
        section = .chats
        selection = convId
    }
}
