import AppIntents
import SwiftUI
import WidgetKit

struct NewConversationControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "to.yumi.yorozu.control.new") {
            ControlWidgetButton(action: NewConversationIntent()) {
                Label("New Conversation", systemImage: "square.and.pencil")
            }
        }
        .displayName("New Conversation")
        .description("Opens a new conversation in Yorozu.")
    }
}

/// Opens a new conversation with voice input started, or the voice setup when the model isn't ready.
struct TalkToYorozuControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "to.yumi.yorozu.control.talk") {
            ControlWidgetButton(action: TalkToYorozuIntent()) {
                Label("Talk to Yorozu", systemImage: "mic")
            }
        }
        .displayName("Talk to Yorozu")
        .description("Opens a new conversation in Yorozu and starts voice input.")
    }
}
