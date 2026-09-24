import Testing

@testable import YorozuShared

private actor ProjectTransport: ChatTransport {
    private let stream: AsyncStream<TransportUpdate>
    private let continuation: AsyncStream<TransportUpdate>.Continuation
    private(set) var sent: [YorozuEvent] = []

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    func connect() -> AsyncStream<TransportUpdate> { stream }
    func send(_ event: YorozuEvent) { sent.append(event) }
    func close() { continuation.finish() }
    func yield(_ update: TransportUpdate) { continuation.yield(update) }
    var projectRequests: Int { sent.filter { $0.payload.kind == .projectList }.count }
}

@MainActor
private func eventuallyProject(_ condition: @MainActor () async -> Bool) async -> Bool {
    for _ in 0..<300 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

@MainActor
private func connectedProjectModel(_ transport: ProjectTransport) async -> ChatModel {
    let model = ChatModel(transport: transport)
    await transport.yield(.ownerOnline(true))
    await transport.yield(.state(.paired))
    model.start()
    #expect(await eventuallyProject { model.canDeliver })
    return model
}

private func projectResponse(_ projects: [ProjectFolder], id: String = "projects") -> TransportUpdate {
    .event(YorozuEvent(
        id: id, threadId: "home", ts: 0, agentId: "main", payload: .projectList(ProjectListData(projects: projects))
    ))
}

@MainActor @Test func projectRefreshDistinguishesLoadingFromAnEmptySuccess() async {
    let transport = ProjectTransport()
    let model = await connectedProjectModel(transport)
    let refresh = Task { await model.refreshProjects() }

    #expect(await eventuallyProject { await transport.projectRequests == 1 })
    #expect(model.projectListStatus == .loading)
    await transport.yield(projectResponse([]))
    await refresh.value

    #expect(model.projectListStatus == .ready)
    #expect(model.projects.isEmpty)
    await transport.close()
}

@MainActor @Test func projectRefreshCoalescesInFlightRequestsAndCanRefreshAgain() async {
    let transport = ProjectTransport()
    let model = await connectedProjectModel(transport)
    let first = Task { await model.refreshProjects() }
    #expect(await eventuallyProject { await transport.projectRequests == 1 })
    await model.refreshProjects()
    #expect(await transport.projectRequests == 1)

    let old = ProjectFolder(path: "/Projects/old", name: "old")
    await transport.yield(projectResponse([old]))
    await first.value
    #expect(model.projects == [old])

    let second = Task { await model.refreshProjects() }
    #expect(await eventuallyProject { await transport.projectRequests == 2 })
    #expect(model.projectListStatus == .loading)
    #expect(model.projects == [old])
    let added = ProjectFolder(path: "/Projects/new", name: "new")
    await transport.yield(projectResponse([old, added], id: "projects-new"))
    await second.value
    #expect(model.projects == [old, added])
    #expect(model.projectListStatus == .ready)
    await transport.close()
}

@MainActor @Test func projectRefreshReportsOfflineWithoutDiscardingKnownFolders() async {
    let transport = ProjectTransport()
    let model = await connectedProjectModel(transport)
    let folder = ProjectFolder(path: "/Projects/retained", name: "retained")
    await transport.yield(projectResponse([folder]))
    #expect(await eventuallyProject { model.projects == [folder] })

    let refresh = Task { await model.refreshProjects() }
    #expect(await eventuallyProject { await transport.projectRequests == 1 })
    await transport.yield(.ownerOnline(false))
    await refresh.value
    #expect(model.projectListStatus == .offline)
    #expect(model.projects == [folder])
    await model.refreshProjects()
    #expect(await transport.projectRequests == 1)

    await transport.yield(.ownerOnline(true))
    #expect(await eventuallyProject { model.canDeliver })
    let reconnectRefresh = Task { await model.refreshProjects() }
    #expect(await eventuallyProject { await transport.projectRequests == 2 })
    await transport.yield(projectResponse([], id: "empty-after-reconnect"))
    await reconnectRefresh.value
    #expect(model.projectListStatus == .ready)
    #expect(model.projects.isEmpty)
    await transport.close()
}

@MainActor @Test func projectRefreshTimeoutAllowsLateResponsesAndRetry() async {
    let transport = ProjectTransport()
    let model = await connectedProjectModel(transport)
    await model.refreshProjects(timeout: .zero)
    #expect(model.projectListStatus == .failed)
    #expect(await eventuallyProject { await transport.projectRequests == 1 })

    // A delayed runtime response remains useful after the spinner has timed out.
    let folder = ProjectFolder(path: "/Projects/late", name: "late")
    await transport.yield(projectResponse([folder]))
    #expect(await eventuallyProject { model.projectListStatus == .ready })
    #expect(model.projects == [folder])

    await model.refreshProjects(timeout: .zero)
    #expect(model.projectListStatus == .failed)
    #expect(model.projects == [folder])
    let retry = Task { await model.refreshProjects() }
    #expect(await eventuallyProject { await transport.projectRequests == 3 })
    await transport.yield(projectResponse([folder], id: "retry-success"))
    await retry.value
    #expect(model.projectListStatus == .ready)
    await transport.close()
}

@MainActor @Test func projectFolderSelectionKeepsItsFullPathWhenNamesMatch() async {
    let transport = ProjectTransport()
    let model = await connectedProjectModel(transport)
    let folders = [
        ProjectFolder(path: "/Users/demo/Projects/client one/app", name: "app"),
        ProjectFolder(path: "/Volumes/Work/client two/app", name: "app"),
    ]
    await transport.yield(projectResponse(folders))
    #expect(await eventuallyProject { model.projects == folders })
    let selected = model.projects[1]
    let draft = model.newDraft(agent: .codex, cwd: selected.path)
    #expect(draft.cwd == "/Volumes/Work/client two/app")
    model.send("Inspect this project", in: draft.id)
    #expect(await eventuallyProject {
        await transport.sent.contains { event in
            guard case .threadCreate(let data) = event.payload else { return false }
            return data.cwd == "/Volumes/Work/client two/app" && data.agent == .codex
        }
    })
    await transport.close()
}

@MainActor @Test func projectRefreshCancellationDoesNotLeaveTheNextPickerLoadingForever() async {
    let transport = ProjectTransport()
    let model = await connectedProjectModel(transport)
    let abandoned = Task { await model.refreshProjects() }
    #expect(await eventuallyProject { await transport.projectRequests == 1 })
    abandoned.cancel()
    await abandoned.value
    #expect(model.projectListStatus == .failed)

    let reopened = Task { await model.refreshProjects() }
    #expect(await eventuallyProject { await transport.projectRequests == 2 })
    await transport.yield(projectResponse([]))
    await reopened.value
    #expect(model.projectListStatus == .ready)
    await transport.close()
}
