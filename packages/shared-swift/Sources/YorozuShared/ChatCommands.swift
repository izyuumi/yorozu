#if os(macOS)
    import SwiftUI

    /// What the Mac's menu bar can do to the chat on screen.
    ///
    /// The menus are built by the `App` scene and the state they act on belongs to the views
    /// inside it, so the views publish what they can do as focused scene values and the menus
    /// read them back. Scene values rather than plain focused values: a menu item should work
    /// whichever half of the split view the pointer last clicked in.
    ///
    /// An action that is not available right now is nil, which is what draws its menu item
    /// disabled instead of offering something that would do nothing.
    public struct ChatCommands {
        public var find: () -> Void
        public var exportTitle: String
        public var exportMarkdown: () -> String
        /// Set only while a turn is running, which is the only time there is anything to stop.
        public var stop: (() -> Void)?
        /// Empty until the runtime has said what it has; then the Model submenu's choices.
        public var models: [ModelOption]
        public var model: String?
        public var setModel: (String?) -> Void

        public init(
            find: @escaping () -> Void,
            exportTitle: String,
            exportMarkdown: @escaping () -> String,
            stop: (() -> Void)? = nil,
            models: [ModelOption] = [],
            model: String? = nil,
            setModel: @escaping (String?) -> Void
        ) {
            self.find = find
            self.exportTitle = exportTitle
            self.exportMarkdown = exportMarkdown
            self.stop = stop
            self.models = models
            self.model = model
            self.setModel = setModel
        }
    }

    /// What the thread list can do. Separate from ``ChatCommands`` because it outlives any one
    /// thread: starting a new one is the sidebar's job, not the open chat's.
    public struct ThreadCommands {
        public var newThread: () -> Void

        public init(newThread: @escaping () -> Void) {
            self.newThread = newThread
        }
    }

    public struct ChatCommandsKey: FocusedValueKey {
        public typealias Value = ChatCommands
    }

    public struct ThreadCommandsKey: FocusedValueKey {
        public typealias Value = ThreadCommands
    }

    extension FocusedValues {
        public var chatCommands: ChatCommands? {
            get { self[ChatCommandsKey.self] }
            set { self[ChatCommandsKey.self] = newValue }
        }

        public var threadCommands: ThreadCommands? {
            get { self[ThreadCommandsKey.self] }
            set { self[ThreadCommandsKey.self] = newValue }
        }
    }
#endif
