import ReplayKit
import SwiftUI
import UIKit

struct CicadaRootView: View {
    @StateObject private var vm = CicadaMobileViewModel()
    @State private var selectedTab = 0
    @State private var shareText: String?

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            languageStrip
            tabSelector
            Group {
                switch selectedTab {
                case 0: transcriptView
                case 1: notesView
                case 2: historyView
                default: settingsView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            holdToTalkBar
        }
        .background(CicadaPalette.ground.ignoresSafeArea())
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11)
                    .fill(CicadaPalette.ink)
                    .frame(width: 38, height: 38)
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(CicadaPalette.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("知了 · Cicada")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(CicadaPalette.ink)
                    Text(vm.genai.activeRouteLabel)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(CicadaPalette.ok)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(CicadaPalette.okPale))
                }
                Text(vm.genai.connectionStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(CicadaPalette.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                vm.toggleListening()
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(vm.isListening ? CicadaPalette.accent : Color.gray.opacity(0.4))
                        .frame(width: 8, height: 8)
                    Text(vm.isListening ? "正在听" : "开始听")
                        .font(.system(size: 13, weight: .bold))
                }
                .foregroundStyle(vm.isListening ? .white : CicadaPalette.ink)
                .padding(.horizontal, 14).frame(height: 36)
                .background(Capsule().fill(vm.isListening ? CicadaPalette.ink : Color.white))
                .overlay(Capsule().stroke(CicadaPalette.line, lineWidth: 1))
            }
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8)
        .background(Color.white)
    }

    private var languageStrip: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(supportedLanguages) { lang in
                    Button(lang.name) { vm.sourceLang = lang.id }
                }
            } label: {
                langPill(prefix: "听到", value: supportedLanguages.first { $0.id == vm.sourceLang }?.name ?? vm.sourceLang)
            }
            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(CicadaPalette.tertiary)
            Menu {
                ForEach(supportedLanguages) { lang in
                    Button(lang.name) { vm.targetLang = lang.id }
                }
            } label: {
                langPill(prefix: "译成", value: supportedLanguages.first { $0.id == vm.targetLang }?.name ?? vm.targetLang)
            }
            Spacer()
            Button {
                vm.toggleReplayKitAudioCapture()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: vm.replayKitActive ? "record.circle.fill" : "app.connected.to.app.below.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(vm.replayKitActive ? CicadaPalette.accent : CicadaPalette.ink)
                    Text(vm.replayKitActive ? "内录中" : "跨App内录")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(CicadaPalette.ink)
                }
                .padding(.horizontal, 9).frame(height: 30)
                .background(Capsule().fill(vm.replayKitActive ? CicadaPalette.accentPale : CicadaPalette.ground))
                .overlay(Capsule().stroke(vm.replayKitActive ? CicadaPalette.accent.opacity(0.45) : CicadaPalette.line, lineWidth: 1))
            }
            if vm.updatingNotes {
                ProgressView().scaleEffect(0.75)
            } else if !vm.currentSession.lines.isEmpty {
                Button {
                    vm.updateNotesNow()
                    selectedTab = 1
                } label: {
                    Text("生成纪要")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CicadaPalette.accent)
                        .padding(.horizontal, 10).frame(height: 30)
                        .background(Capsule().fill(CicadaPalette.accentPale))
                }
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 10)
        .background(Color.white)
    }

    private func langPill(prefix: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(prefix).font(.system(size: 11)).foregroundStyle(CicadaPalette.secondary)
            Text(value).font(.system(size: 12, weight: .semibold)).foregroundStyle(CicadaPalette.ink)
            Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(CicadaPalette.tertiary)
        }
        .padding(.horizontal, 10).frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8).fill(CicadaPalette.ground))
    }

    private var tabSelector: some View {
        HStack(spacing: 0) {
            ForEach(Array(["实时字幕", "AI 纪要", "会议记录", "VPN / AI"].enumerated()), id: \.offset) { idx, title in
                Button {
                    selectedTab = idx
                } label: {
                    VStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 13, weight: selectedTab == idx ? .bold : .medium))
                            .foregroundStyle(selectedTab == idx ? CicadaPalette.ink : CicadaPalette.secondary)
                        Rectangle()
                            .fill(selectedTab == idx ? CicadaPalette.accent : Color.clear)
                            .frame(height: 2.5)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                }
            }
        }
        .background(Color.white)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var transcriptView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if vm.currentSession.lines.isEmpty && vm.liveSourceVolatile.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "waveform.and.mic")
                                .font(.system(size: 34))
                                .foregroundStyle(CicadaPalette.tertiary)
                            Text("点击右上角「开始听」或按住底部按钮说话")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(CicadaPalette.secondary)
                            Text("连上 Apple VPN 时直连 floodgate.g.apple.com (gemini-3.8-flash)")
                                .font(.system(size: 12))
                                .foregroundStyle(CicadaPalette.tertiary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 64)
                    }
                    ForEach(vm.currentSession.lines) { line in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(line.speaker)
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(line.isMe ? CicadaPalette.accent : CicadaPalette.secondary)
                                Text(CicadaMobileViewModel.clock(line.timestamp))
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(CicadaPalette.tertiary)
                                Spacer()
                            }
                            Text(line.sourceText)
                                .font(.system(size: 14))
                                .foregroundStyle(CicadaPalette.secondary)
                            Text(line.translatedText)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(CicadaPalette.ink)
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 14).fill(line.isMe ? CicadaPalette.accentPale : Color.white))
                        .id(line.id)
                    }
                    if !vm.liveSourceVolatile.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Circle().fill(CicadaPalette.accent).frame(width: 6, height: 6)
                                Text("正在听写…").font(.system(size: 11, weight: .semibold)).foregroundStyle(CicadaPalette.accent)
                            }
                            Text(vm.liveSourceVolatile)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(CicadaPalette.ink)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(CicadaPalette.accent.opacity(0.4), lineWidth: 1))
                        .id("volatile")
                    }
                }
                .padding(14)
            }
            .onChange(of: vm.currentSession.lines.count) { _, _ in
                if let last = vm.currentSession.lines.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }
}

extension CicadaRootView {
    var notesView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(vm.currentSession.title)
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(CicadaPalette.ink)
                    Spacer()
                    Menu {
                        ForEach(supportedLanguages) { lang in
                            Button(lang.name) { vm.notesLang = lang.id }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "globe")
                            Text(supportedLanguages.first { $0.id == vm.notesLang }?.name ?? vm.notesLang)
                            Image(systemName: "chevron.down").font(.system(size: 8))
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CicadaPalette.ink)
                        .padding(.horizontal, 10).frame(height: 30)
                        .background(Capsule().fill(CicadaPalette.ground))
                    }
                    Button {
                        vm.updateNotesNow()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                            Text(vm.updatingNotes ? "整理中…" : "立即刷新")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CicadaPalette.accent)
                        .padding(.horizontal, 12).frame(height: 30)
                        .background(Capsule().fill(CicadaPalette.accentPale))
                    }
                    .disabled(vm.currentSession.lines.isEmpty || vm.updatingNotes)
                }

                if vm.currentSession.notes.isEmpty {
                    Text(vm.currentSession.lines.isEmpty ? "开始听会后，GenAI 会自动将字幕整理成结构化总结、议题、结论与待办。" : "点击右上角「立即刷新」由 gemini-3.8-flash 生成会议纪要。")
                        .font(.system(size: 13))
                        .foregroundStyle(CicadaPalette.secondary)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
                } else {
                    if !vm.currentSession.notes.summary.isEmpty {
                        noteCard(title: "总结") {
                            Text(vm.currentSession.notes.summary)
                                .font(.system(size: 14))
                                .foregroundStyle(CicadaPalette.ink)
                                .lineSpacing(4)
                        }
                    }
                    if !vm.currentSession.notes.topics.isEmpty {
                        noteCard(title: "议题要点") {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(vm.currentSession.notes.topics) { t in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(t.title).font(.system(size: 14, weight: .bold)).foregroundStyle(CicadaPalette.ink)
                                        ForEach(t.points, id: \.self) { p in
                                            Text("• " + p).font(.system(size: 13)).foregroundStyle(CicadaPalette.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if !vm.currentSession.notes.conclusions.isEmpty {
                        noteCard(title: "结论") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(vm.currentSession.notes.conclusions) { c in
                                    Text("✓ " + c.text).font(.system(size: 13, weight: .medium)).foregroundStyle(CicadaPalette.ink)
                                }
                            }
                        }
                    }
                    if !vm.currentSession.notes.todos.isEmpty {
                        noteCard(title: "待办 (To-Do)") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(vm.currentSession.notes.todos) { td in
                                    HStack {
                                        Image(systemName: "circle").font(.system(size: 12)).foregroundStyle(CicadaPalette.accent)
                                        Text(td.text).font(.system(size: 13)).foregroundStyle(CicadaPalette.ink)
                                        if let owner = td.owner, !owner.isEmpty {
                                            Text("@" + owner).font(.system(size: 11, weight: .semibold)).foregroundStyle(CicadaPalette.accent)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Button {
                        UIPasteboard.general.string = vm.exportMarkdown(vm.currentSession)
                    } label: {
                        HStack {
                            Image(systemName: "doc.on.doc")
                            Text("复制 Markdown 完整纪要")
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 12).fill(CicadaPalette.ink))
                    }
                }
            }
            .padding(14)
        }
    }

    private func noteCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .bold)).foregroundStyle(CicadaPalette.secondary)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
    }

    var historyView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if vm.history.isEmpty {
                    Text("暂无历史会议记录")
                        .font(.system(size: 14))
                        .foregroundStyle(CicadaPalette.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                }
                ForEach(vm.history) { item in
                    Button {
                        vm.currentSession = item
                        selectedTab = 0
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title).font(.system(size: 15, weight: .bold)).foregroundStyle(CicadaPalette.ink)
                                Text("\(item.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(item.lines.count) 句")
                                    .font(.system(size: 12)).foregroundStyle(CicadaPalette.secondary)
                            }
                            Spacer()
                            Button {
                                UIPasteboard.general.string = vm.exportMarkdown(item)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 14))
                                    .foregroundStyle(CicadaPalette.secondary)
                                    .padding(8)
                            }
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
                    }
                }
            }
            .padding(14)
        }
    }

    var settingsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                noteCard(title: "Webex / 跨 App 录制模式") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(isOn: $vm.speakerVoicesEnabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("本机声纹区分说话人 (WeSpeaker Core ML)")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(CicadaPalette.ink)
                                Text("自动提取 256 维声纹向量并将发言人标记为「说话人 1 / 2 / 3」")
                                    .font(.system(size: 11))
                                    .foregroundStyle(CicadaPalette.secondary)
                            }
                        }
                        .tint(CicadaPalette.accent)

                        Toggle(isOn: $vm.webexMixMode) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("后台与 Webex 混音共存 (.mixWithOthers)")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(CicadaPalette.ink)
                                Text("切到 Webex 时保持知了在后台持续收音并自动恢复音频中断")
                                    .font(.system(size: 11))
                                    .foregroundStyle(CicadaPalette.secondary)
                            }
                        }
                        .tint(CicadaPalette.accent)

                        HStack(spacing: 10) {
                            Button {
                                vm.toggleReplayKitAudioCapture()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: vm.replayKitActive ? "stop.circle.fill" : "record.circle")
                                    Text(vm.replayKitActive ? "停止 ReplayKit 内录" : "开启 ReplayKit 音频流采集 (.audioApp)")
                                }
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity).frame(height: 38)
                                .background(RoundedRectangle(cornerRadius: 10).fill(vm.replayKitActive ? CicadaPalette.accent : CicadaPalette.ink))
                            }
                            SystemBroadcastButton()
                                .frame(width: 38, height: 38)
                                .background(RoundedRectangle(cornerRadius: 10).fill(CicadaPalette.ground))
                        }
                    }
                }
                noteCard(title: "Apple VPN · GenAI 路由模式") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("连接通道", selection: $vm.genai.routeMode) {
                            Text("自动（Apple VPN 优先）").tag(GenAIClient.RouteMode.autoVPN)
                            Text("Floodgate 云端直连").tag(GenAIClient.RouteMode.directFloodgate)
                            Text("Mac 桥接直连").tag(GenAIClient.RouteMode.macBridge)
                            Text("Ling 云端备用").tag(GenAIClient.RouteMode.antLing)
                        }
                        .pickerStyle(.segmented)

                        HStack {
                            Text("AI 模型").font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Picker("AI 模型", selection: $vm.genai.aiModel) {
                                ForEach(GenAIClient.models, id: \.self) { m in Text(m).tag(m) }
                            }
                        }

                        HStack {
                            Text("同传语音音色 (Gemini TTS)").font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Picker("音色", selection: $vm.ttsVoice) {
                                Text("Kore (女·清亮)").tag("Kore")
                                Text("Aoede (女·温和)").tag("Aoede")
                                Text("Puck (男·自然)").tag("Puck")
                                Text("Charon (男·沉稳)").tag("Charon")
                            }
                        }

                        Button {
                            Task { await vm.genai.refreshFloodgateTokenAndProbe() }
                        } label: {
                            HStack {
                                Image(systemName: "bolt.horizontal.circle.fill")
                                Text("刷新 Apple VPN Floodgate 令牌并测速")
                            }
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity).frame(height: 40)
                            .background(RoundedRectangle(cornerRadius: 10).fill(CicadaPalette.ink))
                        }
                    }
                }

                noteCard(title: "Mac 令牌同步 / 局域网中枢 IP（支持快捷填入）") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("例如 17.87.15.76 或 xis-MacBook-Pro.local", text: $vm.genai.macBridgeURL)
                            .font(.system(size: 13, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 8).fill(CicadaPalette.ground))
                            .onSubmit {
                                vm.genai.macBridgeURL = GenAIClient.normalizeBridgeURL(vm.genai.macBridgeURL)
                            }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(GenAIClient.quickHosts, id: \.0) { chip in
                                    Button {
                                        vm.genai.macBridgeURL = chip.1
                                        Task { await vm.genai.refreshFloodgateTokenAndProbe() }
                                    } label: {
                                        Text(chip.0)
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(CicadaPalette.ink)
                                            .padding(.horizontal, 10).padding(.vertical, 6)
                                            .background(Capsule().fill(CicadaPalette.ground))
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    var holdToTalkBar: some View {
        VStack(spacing: 6) {
            if !vm.speakingStatus.isEmpty {
                Text(vm.speakingStatus)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(CicadaPalette.accent)
            }
            HStack(spacing: 10) {
                Menu {
                    ForEach(supportedLanguages) { lang in
                        Button("我说: " + lang.name) { vm.speakFromLang = lang.id }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("我说: \(supportedLanguages.first { $0.id == vm.speakFromLang }?.name ?? vm.speakFromLang)")
                            .font(.system(size: 12, weight: .semibold))
                        Image(systemName: "chevron.up").font(.system(size: 9))
                    }
                    .foregroundStyle(CicadaPalette.ink)
                    .padding(.horizontal, 12).frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 13).fill(CicadaPalette.ground))
                }

                Text(vm.isInterpretingHold ? "松开立即传译播报…" : "按住说话 · 同声传译")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 13).fill(vm.isInterpretingHold ? CicadaPalette.accent : CicadaPalette.ink))
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in
                                if !vm.isInterpretingHold { vm.holdToSpeakBegan() }
                            }
                            .onEnded { _ in
                                vm.holdToSpeakEnded()
                            }
                    )
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.white)
        .overlay(alignment: .top) { Divider() }
    }
}

struct SystemBroadcastButton: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 38, height: 38))
        picker.showsMicrophoneButton = true
        return picker
    }
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}
