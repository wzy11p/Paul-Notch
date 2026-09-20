import SwiftUI

/// Home is a projection of the existing stores, never another task repository.
struct TaskFirstHomeView: View {
    @ObservedObject var tasks: TaskStore
    @ObservedObject var settings: AppSettingsStore
    @ObservedObject var music: MusicService
    @ObservedObject var pomodoro: PomodoroStore
    let onOpenModule: (AppSettingsStore.HomeModule) -> Void

    @State private var showsTasks = false
    @State private var composingTask = false
    @State private var initialTaskID: UUID?
    @State private var showsConfiguration = false
    @State private var hoveredTask: UUID?
    @State private var showsMusicProviders = false
    @AppStorage("home.compact.music.v1", store: AppEnvironment.defaults) private var showsMusic = true
    @AppStorage("home.compact.focus.v1", store: AppEnvironment.defaults) private var showsFocus = true
    @AppStorage("home.compact.note.v1", store: AppEnvironment.defaults) private var showsNote = true

    private var pending: [TaskItem] { tasks.activeTasks.filter { !$0.isCompleted } }

    var body: some View {
        Group {
            if composingTask || initialTaskID != nil {
                MemoTaskEditor(store: tasks, settings: settings, task: tasks.tasks.first { $0.id == initialTaskID },
                               defaultCategory: nil, returnLabel: "返回首页") {
                    composingTask = false
                    initialTaskID = nil
                }
                .id(initialTaskID?.uuidString ?? "new")
                .onAppear { tasks.memoEditingActive = true }
                .onDisappear { tasks.memoEditingActive = false }
            } else if showsTasks {
                VStack(spacing: 4) {
                  if !tasks.memoEditingActive {
                    Button {
                        showsTasks = false
                        initialTaskID = nil
                    } label: {
                        Label("返回首页", systemImage: "chevron.left")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                  }
                    MemoTaskWorkspace(store: tasks, settings: settings, completed: false,
                                      initialTaskID: initialTaskID)
                }
            } else {
                overview
            }
        }
        .onAppear {
            if tasks.hasPendingMemoAddRequest { showsTasks = true }
        }
        .onChange(of: tasks.focusAddRequest) { _ in
            initialTaskID = nil
            showsTasks = true
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(context.date, format: .dateTime.month().day().weekday(.wide).hour().minute())
                        .font(.system(size: 13, weight: .medium)).monospacedDigit()
                        .foregroundStyle(IslandTheme.text2)
                }
                Spacer()
                Button { showsConfiguration.toggle() } label: {
                    Label("编辑首页", systemImage: "slider.horizontal.3")
                        .font(.system(size: 12))
                        .padding(.horizontal, 12).frame(height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showsConfiguration) { configuration }
            }
            HStack(alignment: .top, spacing: 16) {
                taskList.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                ScrollView {
                  VStack(spacing: 10) {
                    if showsMusic { musicControl }
                    if showsFocus { focusControl }
                    if showsNote {
                        utilityButton("随笔记", subtitle: "随手记下，随时找回", icon: "pencil.line") {
                            onOpenModule(.note)
                        }
                    }
                    Menu {
                        ForEach(settings.orderedVisibleModules(includeCompletions: true)) { module in
                            Button(module.rawValue) { onOpenModule(module) }
                        }
                    } label: {
                        Label("更多组件", systemImage: "ellipsis")
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .padding(.horizontal, 12)
                    Spacer(minLength: 0)
                  }
                }
                .frame(width: 224)
            }
        }
        .foregroundStyle(IslandTheme.text1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var taskList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("待办任务").font(.system(size: 18, weight: .semibold))
                Text("\(pending.count)").font(.callout).foregroundStyle(IslandTheme.text2)
                Spacer()
                Button {
                    // A local capture action must not emit the global tab-routing
                    // request or compete with another workspace for its intent.
                    composingTask = true
                } label: {
                    Label("新建任务", systemImage: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(IslandTheme.accentBlue)
                        .padding(.horizontal, 14).frame(height: 44)
                        .background(IslandTheme.surface3, in: RoundedRectangle(cornerRadius: 12))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).tint(IslandTheme.accentBlue)
                .disabled(!tasks.hasLoaded)
            }
            if !tasks.hasLoaded {
                VStack(spacing: 10) {
                    Text(tasks.errorMessage ?? "正在读取任务…")
                    if tasks.errorMessage != nil { Button("重试") { tasks.load() } }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if pending.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("暂时没有待办").font(.headline)
                    Text("想到什么就记下来，细节稍后再补。")
                        .font(.callout).foregroundStyle(IslandTheme.text2)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(pending) { task in taskRow(task) }
                    }
                }
            }
            Button {
                initialTaskID = nil
                showsTasks = true
            } label: {
                HStack {
                    Text("查看任务列表")
                    Spacer()
                    Image(systemName: "arrow.right")
                }
                .font(.callout).foregroundStyle(IslandTheme.text2)
                .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
    }

    private func taskRow(_ task: TaskItem) -> some View {
        HStack(spacing: 0) {
            Button { tasks.toggle(task) } label: {
                Image(systemName: "circle").font(.system(size: 20))
                    .foregroundStyle(IslandTheme.text2)
                    .frame(width: 44, height: 52).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("完成任务：\(task.title)")
            Button {
                initialTaskID = task.id
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.title).font(.system(size: 14, weight: .medium)).lineLimit(2)
                        if let due = task.dueDate {
                            Text(due, format: .dateTime.month().day().hour().minute())
                                .font(.system(size: 11)).foregroundStyle(IslandTheme.text2)
                        }
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.system(size: 10))
                        .foregroundStyle(IslandTheme.text2)
                }
                .padding(.trailing, 12).padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityHint("打开任务详情")
        }
        .background(hoveredTask == task.id ? IslandTheme.surface3 : IslandTheme.surface1,
                    in: RoundedRectangle(cornerRadius: 12))
        .onHover { hoveredTask = $0 ? task.id : nil }
    }

    private var musicControl: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
            Button { music.openPlayer() } label: {
                HStack {
                    Image(systemName: "music.note")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(music.isOpening ? "正在打开…" : (music.activeProvider == .qqMusic ? music.qqNowPlaying?.title : nil) ?? music.displayName)
                            .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        if music.activeProvider == .qqMusic, let track = music.qqNowPlaying, track.title != nil {
                            Text(track.artist ?? music.displayName)
                                .font(.system(size: 11)).foregroundStyle(IslandTheme.text2).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }.padding(.leading, 14).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(music.isOpening)
            .accessibilityLabel("打开" + music.displayName)
            .accessibilityValue(music.activeProvider == .qqMusic ? [music.qqNowPlaying?.title, music.qqNowPlaying?.artist].compactMap { $0 }.joined(separator: "，") : "")
            .help("打开播放器窗口，不需要播放控制权限")
            Button { music.refreshStatus(); showsMusicProviders = true } label: {
                Image(systemName: "chevron.down").font(.system(size: 10))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("选择音乐播放器")
            .accessibilityLabel("选择音乐播放器")
            .popover(isPresented: $showsMusicProviders) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(MusicService.Provider.allCases) { provider in
                        Button {
                            music.setEnabled(provider, enabled: true)
                            music.setDefault(provider)
                            showsMusicProviders = false
                        } label: {
                            HStack {
                                Text(provider.name)
                                Spacer()
                                if music.activeProvider == provider { Image(systemName: "checkmark") }
                            }.padding(.horizontal, 12).frame(width: 200, height: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(!music.isInstalled(provider))
                    }
                }.padding(8)
            }
            }
            HStack(spacing: 4) {
                mediaButton("上一首", icon: "backward.end.fill") { music.control(.previous) }
                mediaButton(music.playbackActionLabel, icon: music.playbackActionSymbol) {
                    music.control(music.isPlaying ? .pause : .play)
                }
                mediaButton("下一首", icon: "forward.end.fill") { music.control(.next) }
            }.frame(maxWidth: .infinity)
            if let error = music.connectionIssue, music.activeProvider != .qqMusic {
                Text(error).font(.caption).foregroundStyle(IslandTheme.text2)
                    .padding([.horizontal, .bottom], 12).fixedSize(horizontal: false, vertical: true)
            }
            if music.activeProvider == .qqMusic, music.connectionIssue != nil {
                MusicConnectionView(music: music, compact: true).padding(.horizontal, 12)
            }
        }
        .background(IslandTheme.surface2, in: RoundedRectangle(cornerRadius: 16))
        .task(id: music.activeProvider) { await music.observeVisiblePlayback() }
    }

    private var focusControl: some View {
        HStack(spacing: 0) {
            Button { onOpenModule(.pomodoro) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "timer")
                    VStack(alignment: .leading, spacing: 3) {
                        Text("专注").font(.system(size: 13, weight: .medium))
                        Text(pomodoro.displayText).font(.system(size: 16, weight: .semibold)).monospacedDigit()
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 14).padding(.trailing, 8)
                .frame(maxWidth: .infinity, minHeight: 68)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("编辑番茄钟时长")
            .accessibilityLabel("编辑番茄钟")
            .accessibilityValue(pomodoro.displayText)
            mediaButton(pomodoro.phase == .running ? "暂停专注" : "开始专注",
                        icon: pomodoro.phase == .running ? "pause.fill" : "play.fill") {
                if pomodoro.phase == .running { pomodoro.pause() } else { pomodoro.start() }
            }
            .padding(.trailing, 6)
        }
        .frame(height: 68)
        .background(IslandTheme.surface2, in: RoundedRectangle(cornerRadius: 16))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func mediaButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).help(title).accessibilityLabel(title)
    }

    private func utilityButton(_ title: String, subtitle: String, icon: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(IslandTheme.text2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 10))
            }
            .padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: 60)
            .background(IslandTheme.surface2, in: RoundedRectangle(cornerRadius: 16))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("首页快捷控件").font(.headline)
            Toggle("音乐", isOn: $showsMusic)
            Toggle("专注", isOn: $showsFocus)
            Toggle("随笔记", isOn: $showsNote)
            Text("任务始终在左侧。原有组件和布局设置保留，可从更多组件进入。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("完成") { showsConfiguration = false }.frame(minHeight: 44)
        }.padding(20).frame(width: 260)
    }
}
