import SwiftUI
import WidgetKit

@main
struct YorozuWidgets: WidgetBundle {
    var body: some Widget {
        ConversationsWidget()
        UnreadAccessoryWidget()
        NewConversationControl()
        TalkToYorozuControl()
        TurnActivityWidget()
    }
}
