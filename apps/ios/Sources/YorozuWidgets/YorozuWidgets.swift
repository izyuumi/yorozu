import SwiftUI
import WidgetKit

@main
struct YorozuWidgets: WidgetBundle {
    var body: some Widget {
        ConversationsWidget()
        UnreadAccessoryWidget()
        TalkLauncherWidget()
        AskLauncherWidget()
        NewConversationControl()
        TalkToYorozuControl()
        YorozuActivityWidget()
    }
}
