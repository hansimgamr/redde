import SwiftUI
import os

struct ContentView: View {
    @Environment(Conversation.self) private var conversation
    @Environment(VoiceSession.self) private var voiceSession
    @Environment(\.theme) private var theme
    @State private var settings = Settings.shared
    @State private var router = LaunchRouter.shared
    @State private var lock = AppLock.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var draft = ""
    private enum AppTab: Hashable { case chat, cron, kanban, settings }
    @State private var selectedTab: AppTab = .chat
    @State private var shareItem: ShareItem?
    @State private var showSetup = false
    private enum ChatRoute: Hashable { case transcript }
    @State private var chatPath = NavigationPath()
    @State private var hasOpenedConversation = false
    /// What's New was up when voice mode was asked for: voice wins, and it comes back after.
    @State private var deferredWhatsNew: WhatsNew.Release?
    @State private var showVoice = false
    @State private var showSearch = false
    @State private var showModelPicker = false
    /// "Edit & resend": the message being replaced; sending truncates the transcript from it.
    @State private var editing: Message?
    @State private var pendingAttachments: [Attachment] = []
    @FocusState private var composerFocused: Bool
    /// The update's highlights, shown once per version.
    @State private var whatsNew: WhatsNew.Release?
    #if DEBUG
    /// Dev hook: `-echo.screen profiles` opens the profile picker (screenshots, live tests).
    @State private var showProfilePicker = false
    @State private var showTips = false
    @State private var showServers = false
    #endif

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Chat", systemImage: "bubble.left.and.bubble.right", value: AppTab.chat) {
                chatLayout
            }
            Tab("Cron", systemImage: "clock", value: AppTab.cron) {
                NavigationStack {
                    CronView(isShowing: selectedTab == .cron)
                        .id(settings.connectionKey)
                        .navigationTitle("Cron")
                }
            }
            Tab("Kanban", systemImage: "rectangle.split.3x1", value: AppTab.kanban) {
                NavigationStack {
                    KanbanView(onOpenChat: openTranscript)
                        .id(settings.connectionKey)
                        .navigationTitle("Kanban")
                }
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                SettingsView(showDoneButton: false)
            }
        }
        .tabViewStyle(.tabBarOnly)
        .background { tabShortcuts }
        .onChange(of: selectedTab) { _, tab in
            if tab != .chat { composerFocused = false }
        }
        .onChange(of: chatPath.count) { _, count in
            if count == 0 { hasOpenedConversation = false; composerFocused = false }
        }
        .sheet(isPresented: $showModelPicker) { NavigationStack { ModelPickerView() }.presentationDetents([.medium, .large]) }
        .sheet(isPresented: $showSetup) { SetupView() }
        .sheet(item: $whatsNew) { WhatsNewView(release: $0) }
        #if DEBUG
        .sheet(isPresented: $showProfilePicker) { NavigationStack { ProfilePickerView() } }
        .sheet(isPresented: $showTips) { NavigationStack { TipJarView() } }
        .sheet(isPresented: $showServers) { NavigationStack { ServersView() } }
        #endif
        .fullScreenCover(isPresented: $showVoice) {
            VoiceView(session: voiceSession, onSwitchToTyping: {
                // Once the cover is gone, raise the keyboard in the composer.
                Task { try? await Task.sleep(for: .milliseconds(450)); composerFocused = true }
            })
        }
        .task {
            settings.applyLocalDefaultsIfPresent()
            if !settings.setupDone, !settings.isConfigured { showSetup = true }
            #if DEBUG
            applyDevHooks()
            #endif
            // Download the speech model early so the first voice turn isn't slow. In the background:
            // it can take a while (and never arrives in the simulator), and opening the voice
            // screen below must not wait on it. (It sat inside the DEBUG block from 2026-09-11,
            // so release builds skipped it.)
            Task { await warmSpeechAssets() }
            if Settings.shared.openToVoiceScreen, router.pendingVoice == nil, !showVoice { openVoice() }
            // After the voice screen may have opened: then it waits until that closes.
            presentWhatsNewIfDue()
            #if DEBUG
            if DevHooks.has("-echo.voiceView") { openVoice() }
            if DevHooks.has("-echo.autoVoice") { await launchVoice(handsFree: false) }
            #endif
        }
        .onOpenURL { url in
            // Control Center / Lock Screen controls open the app through echo://listen.
            if let handsFree = EchoURL.parseListen(url) { router.requestVoice(handsFree: handsFree) }
            if url.scheme == EchoURL.scheme, url.host == "share" { consumeSharedItems() }
        }
        .onAppear { consumeControlRequest(); handleLaunchRequest(); handleDraftRequest() }
        .onChange(of: router.pendingVoice) { handleLaunchRequest() }
        .onChange(of: router.pendingDraft) { handleDraftRequest() }
        .onChange(of: lock.isLocked) { _, locked in
            // A Siri / control / share request that arrived while locked runs once unlocked.
            if !locked { consumeControlRequest(); handleLaunchRequest(); consumeSharedItems(); handleDraftRequest() }
            // "What's New" held back by the lock. A moment later, so a voice request opens first.
            if !locked { Task { try? await Task.sleep(for: .milliseconds(600)); presentWhatsNewIfDue() } }
        }
        .onChange(of: showVoice) { _, open in
            if !open { Task { try? await Task.sleep(for: .milliseconds(600)); presentWhatsNewIfDue() } }
        }
        .onChange(of: conversation.id) {
            // A fresh conversation: have llama-swap load its model before the first message.
            if conversation.messages.isEmpty { ModelWarmer.warm(conversation) }
            editing = nil
            ReadState.markConversationRead(conversation.id)   // on screen = read, for Siri
        }
        .onChange(of: settings.setupDone) { _, done in
            // "Erase everything" in Settings: back to first run once its sheet is gone.
            guard !done, !settings.isConfigured else { return }
            Task { try? await Task.sleep(for: .milliseconds(500)); showSetup = true }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            consumeControlRequest()
            Notifier.shared.clearDelivered()
            ReadState.markConversationRead(conversation.id)
            HermesServeClient.shared.reconnectIfNeeded()
            ModelWarmer.warm(conversation)
            conversation.retryOutbox()   // back in the foreground: try anything still waiting to send
            consumeSharedItems()
            guard Settings.shared.listenOnOpen, router.pendingVoice == nil, !voiceSession.mightBeBusy else { return }
            Task { await launchVoice(handsFree: showVoice ? voiceSession.continuous : settings.handsFreeByDefault) }
        }
    }

    private var transcriptScreen: some View {
        TranscriptView(showSetup: $showSetup, showSearch: $showSearch, onEdit: beginEditing, onEditQueued: editQueued)
            .background(theme.background ?? Color(.systemBackground))
            .foregroundStyle(theme.text ?? Color.primary)
            .safeAreaInset(edge: .bottom) {
                ComposerView(draft: $draft, pendingAttachments: $pendingAttachments, editing: $editing,
                             focused: $composerFocused,
                             openHandsFree: { Task { await launchVoice(handsFree: settings.handsFreeByDefault) } },
                             openModelPicker: { showModelPicker = true })
                    .frame(maxWidth: 820).frame(maxWidth: .infinity)
                    // Solid themes have no glass field to hide the transcript scrolling past the composer.
                    .background(theme.usesGlass ? AnyShapeStyle(.clear) : AnyShapeStyle(theme.background ?? Color(.systemBackground)))
            }
            .navigationTitle(headerTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The conversation on top; the agent and model beneath, tap to pick the model —
                // the /model sheet without typing /model.
                ToolbarItem(placement: .principal) {
                    Button { showModelPicker = true } label: {
                        VStack(spacing: 1) {
                            Text(headerTitle)
                                .font(.headline)
                                .lineLimit(1)
                                .foregroundStyle(theme.text ?? Color.primary)
                            HStack(spacing: 3) {
                                Text("\(settings.headerTitle) · \(modelChipLabel)").font(.caption).lineLimit(1)
                                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                            }
                            .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: 220)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(headerTitle). Model: \(modelChipLabel)")
                    .accessibilityHint("Choose which model answers")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Button("Find in conversation", systemImage: "magnifyingglass") { withAnimation { showSearch.toggle() } }
                            .disabled(conversation.messages.isEmpty)
                        Button("Export as Markdown", systemImage: "square.and.arrow.up") {
                            if let url = try? TranscriptExporter.file(title: conversation.title, messages: conversation.messages) {
                                shareItem = ShareItem(url: url)
                            }
                        }
                        .disabled(conversation.messages.isEmpty)
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                    Button("New conversation", systemImage: "square.and.pencil") {
                        conversation.reset()
                    }
                    .disabled(conversation.messages.isEmpty)
                }
            }
            .sheet(item: $shareItem) { ShareSheet(items: [$0.url]) }
            .background { keyboardShortcuts }
    }

    private var chatLayout: some View {
        Group {
            if sizeClass == .regular {
                // iPad: sessions in the sidebar, transcript in the detail column.
                NavigationSplitView {
                    // The stack is what lets a project folder push its session list *inside*
                    // the sidebar. Without it the NavigationLink has nowhere to go: the row
                    // does nothing and there is no back button to escape with.
                    NavigationStack {
                        ConversationsList(onOpened: openTranscript,
                                          onOpenSettings: { selectedTab = .settings },
                                          isShowing: selectedTab == .chat)
                    }
                    .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 420)
                } detail: {
                    if hasOpenedConversation {
                        transcriptScreen
                    } else {
                        ContentUnavailableView("Select a conversation", systemImage: "bubble.left.and.bubble.right",
                                               description: Text("Choose a chat from the list or start a new conversation."))
                    }
                }
            } else {
                phoneLayout
            }
        }
    }

    private var tabShortcuts: some View {
        Group {
            Button("Chat") { selectedTab = .chat }.keyboardShortcut("1", modifiers: .command)
            Button("Conversations") { showConversationList() }.keyboardShortcut("k", modifiers: .command)
            Button("New conversation") { conversation.reset(); openTranscript() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(selectedTab != .chat)
            Button("Cron") { selectedTab = .cron }.keyboardShortcut("2", modifiers: .command)
            Button("Kanban") { selectedTab = .kanban }.keyboardShortcut("3", modifiers: .command)
            Button("Settings") { selectedTab = .settings }.keyboardShortcut("4", modifiers: .command)
            Button("Settings") { selectedTab = .settings }.keyboardShortcut(",", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    // MARK: - iPhone conversation list

    /// Conversations are the root; the system Back button and swipe return from a chat.
    private var phoneLayout: some View {
        NavigationStack(path: $chatPath) {
            ConversationsView(isShowing: selectedTab == .chat && chatPath.isEmpty,
                              onOpened: openTranscript, onOpenSettings: { selectedTab = .settings })
                .navigationDestination(for: ChatRoute.self) { _ in
                    transcriptScreen
                }
        }
    }

    private func openTranscript() {
        selectedTab = .chat
        hasOpenedConversation = true
        chatPath = NavigationPath([ChatRoute.transcript])
    }

    private func showConversationList() {
        selectedTab = .chat
        composerFocused = false
        hasOpenedConversation = false
        chatPath = NavigationPath()
    }

    /// Hardware-keyboard shortcuts (iPad, Mac). Zero-size buttons still receive key equivalents,
    /// and they show up in the ⌘ overlay with these titles.
    private var keyboardShortcuts: some View {
        Group {
            Button("Voice mode") { openVoice() }.keyboardShortcut("v", modifiers: [.command, .shift])
            Button("Focus composer") { composerFocused = true }.keyboardShortcut("l", modifiers: .command)
            Button("Find in conversation") { withAnimation { showSearch.toggle() } }.keyboardShortcut("f", modifiers: .command)
                .disabled(conversation.messages.isEmpty)
            Button("Stop reply") { conversation.cancel() }.keyboardShortcut(".", modifiers: .command).disabled(!conversation.isStreaming)
            Button("Export as Markdown") {
                if let url = try? TranscriptExporter.file(title: conversation.title, messages: conversation.messages) { shareItem = ShareItem(url: url) }
            }
            .keyboardShortcut("e", modifiers: .command).disabled(conversation.messages.isEmpty)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
        .disabled(selectedTab != .chat || !hasOpenedConversation)
    }

    /// The header's first line: this conversation, or "New conversation" before the first message.
    private var headerTitle: String {
        conversation.messages.isEmpty && conversation.outbox.isEmpty ? "New conversation" : conversation.title
    }

    /// What the title chip shows: the picked model, or the backend's default.
    private var modelChipLabel: String {
        switch settings.transport {
        case .chatCompletions: settings.fastLaneModel.nilIfEmpty ?? "model"
        default: settings.gatewayModel.nilIfEmpty ?? "default model"
        }
    }

    /// Voice mode as you'd open it by hand: Hands-free follows Settings → Voice.
    private func openVoice() {
        openTranscript()
        voiceSession.continuous = settings.handsFreeByDefault
        startFreshForVoice()
        showVoice = true
    }

    /// Settings → Voice → "New conversation in voice mode": every way into voice mode starts one,
    /// before the screen appears so the old conversation doesn't flash up. Not while a reply is
    /// still coming or a message waits to send, and not when this one is empty anyway. At a cold
    /// launch (Siri, the Action button) the last conversation may still be loading from disk: it
    /// counts, and the reset drops the load.
    private func startFreshForVoice() {
        guard settings.newConversationForVoice, !showVoice,
              !conversation.messages.isEmpty || conversation.initialLoad != nil,
              !conversation.isStreaming, conversation.outbox.isEmpty else { return }
        conversation.reset()
    }

    /// Items handed over by the share extension become the draft and pending attachments.
    private func consumeSharedItems() {
        guard !lock.isLocked else { return }
        Task {
            // The inbox decodes off the main actor; the lock can have engaged meanwhile.
            guard let payload = await ShareInbox.takePending(), !payload.isEmpty, !lock.isLocked else { return }
            showVoice = false
            openTranscript()
            let text = payload.draft
            if !text.isEmpty { draft = draft.isEmpty ? text : draft + "\n\n" + text }
            pendingAttachments += payload.attachments
            composerFocused = true
        }
    }

    /// Siri AI's "draft a message": the text lands in the open conversation's composer.
    private func handleDraftRequest() {
        guard !lock.isLocked, let request = router.consumeDraftRequest() else { return }
        showVoice = false
        openTranscript()
        if !request.text.isEmpty { draft = draft.isEmpty ? request.text : draft + "\n\n" + request.text }
        pendingAttachments += request.attachments
        composerFocused = true
    }

    /// Siri / Action Button entry: open voice mode and start listening at once.
    /// A control (Action Button, Control Center, Lock Screen) asked for voice via the App Group.
    private func consumeControlRequest() {
        if let handsFree = LaunchFlag.consumeVoice() { router.requestVoice(handsFree: handsFree) }
    }

    private func handleLaunchRequest() {
        guard !lock.isLocked, let request = router.consumeVoiceRequest() else { return }
        Logger(subsystem: "com.goosehouse.echo", category: "intent").info("UI consuming voice request handsFree=\(request.handsFree)")
        Task { await launchVoice(handsFree: request.handsFree) }
    }

    /// Voice mode asked for in a specific mode (the hands-free button, Siri, a control): that mode
    /// wins over the Settings default.
    private func launchVoice(handsFree: Bool) async {
        openTranscript()
        voiceSession.continuous = handsFree
        if !showVoice {
            startFreshForVoice()
            if let shown = whatsNew {
                // A cover can't present over the sheet; without this, voice silently never opened.
                deferredWhatsNew = shown
                whatsNew = nil
                try? await Task.sleep(for: .milliseconds(450))
            }
            showVoice = true
            // Let the cover present before the audio session and mic spin up.
            try? await Task.sleep(for: .milliseconds(400))
        }
        voiceSession.beginListening()
    }

    #if DEBUG
    /// The launch hooks that open this view's own sheets or fill its composer; the rest live in
    /// `DevHooks` (see there for every flag).
    private func applyDevHooks() {
        DevHooks.applyAtLaunch(conversation: conversation, settings: settings)
        switch DevHooks.value("-echo.screen") {
        case "settings": selectedTab = .settings
        case "sessions": showConversationList()
        case "chat": openTranscript()
        case "setup": showSetup = true
        case "profiles": showProfilePicker = true
        case "servers": showServers = true
        case "model": showModelPicker = true
        case "tips": showTips = true
        default: break
        }
        switch DevHooks.value("-echo.section") {
        case "cron": selectedTab = .cron
        case "kanban": selectedTab = .kanban
        default: break
        }
        if let text = DevHooks.value("-echo.draft") {
            openTranscript()
            draft = text
            Task { try? await Task.sleep(for: .milliseconds(450)); composerFocused = true }
        }
    }
    #endif

    /// "What's New" once per version after an update. A fresh install goes through setup and
    /// starts out current. While the app is locked, in voice mode or answering Siri it waits, and
    /// comes up once that's over (unlock and closing voice mode call this again).
    private func presentWhatsNewIfDue() {
        guard whatsNew == nil else { return }
        if let deferred = deferredWhatsNew {
            guard !showVoice, !lock.isLocked else { return }
            whatsNew = deferred
            deferredWhatsNew = nil
            return
        }
        let current = WhatsNew.currentVersion
        let isNewInstall = !settings.setupDone && !settings.isConfigured
        #if DEBUG
        if DevHooks.has("-echo.whatsNew") { whatsNew = WhatsNew.releases.first { $0.version == current } ?? WhatsNew.releases.first; return }
        if DevHooks.screenshotRun { return }   // App Store captures must not get a sheet on top
        #endif
        if isNewInstall { WhatsNew.markSeen(current); return }
        guard !lock.isLocked, !showVoice, router.pendingVoice == nil, !showSetup else { return }
        whatsNew = WhatsNew.pending(lastSeen: WhatsNew.lastSeen, current: current, isNewInstall: false)
        // Once shown it counts as seen, even if the app is quit before Continue.
        if whatsNew != nil { WhatsNew.markSeen(current) }
    }

    /// Download the on-device speech model early so the first voice turn isn't slow.
    private func warmSpeechAssets() async {
        try? await SpeechRecognizer().prepareAssets()
    }

    /// A message that hadn't been sent comes back into the composer to be changed and sent again.
    private func editQueued(_ message: Message) {
        editing = nil
        draft = message.text
        pendingAttachments = message.attachments
        composerFocused = true
    }

    /// Loads a sent message back into the composer; nothing changes until it is sent again.
    private func beginEditing(_ message: Message) {
        editing = message
        draft = message.text
        pendingAttachments = message.attachments
        composerFocused = true
    }
}
