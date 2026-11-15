import SwiftUI

/// What the home screen shows: the section, the selected conversation and the split view's columns, changed
/// together so that opening a conversation always brings it on screen.
struct HomeRoute: Equatable {
    enum Section: Hashable { case chats, crons }

    var section = Section.chats
    var selection: String?
    var columns = LaunchColumns.initial

    /// A conversation the app was asked to open (notification, widget, control, intent, link): it is shown, and
    /// the sidebar never covers it.
    mutating func openRequested(_ convId: String) {
        open(convId)
        columns = LaunchColumns.afterRequestedOpen(columns)
    }

    /// A conversation opened from inside the app (in-app notice, automation): it is shown, columns stay as they are.
    mutating func open(_ convId: String) {
        section = .chats
        selection = convId
    }
}
