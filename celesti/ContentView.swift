import AVKit
import Combine
import KSPlayer
import Sabella
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appModel: CelestiAppModel

    var body: some View {
        ZStack {
            if appModel.layoutMode == .emergency {
                EmergencyPlaybackView()
                    .environmentObject(appModel)
            } else if appModel.layoutMode == .quad {
                QuadPlaybackView()
                    .environmentObject(appModel)
            } else if let group = appModel.activeChannelGroup {
                LiveChannelGroupView(group: group)
            } else if let playback = appModel.playback {
                PlaybackRootView(playback: playback)
            } else {
                registrationRoot
            }

            if let callsign = appModel.callsign {
                SabellaTVCallsignOverlay(nickname: callsign.nickname, deviceCode: callsign.deviceCode)
            }
        }
        .task {
            appModel.startIfNeeded()
        }
        .onExitCommand {
            // Channel playback owns Menu so the first press reveals the guide
            // and the second returns to the authenticated group browser.
            if appModel.activeChannelGroup == nil {
                appModel.handleExitCommand()
            }
        }
    }

    @ViewBuilder
    private var registrationRoot: some View {
        switch appModel.registrationState {
        case .pending:
            SabellaTVChromeScreen(productName: "Celesti") {
                SabellaTVRegistration(deviceID: appModel.deviceId, demo: appModel.showDemoMode) {
                    if let image = QRCodeFactory.image(for: "https://api.celesti.gaulatti.com/register/\(appModel.deviceId)", size: 360) {
                        Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                    } else {
                        ProgressView().tint(.black)
                    }
                }
            }
        case .standby:
            signedInHome
        case .demo:
            SabellaTVChromeScreen(productName: "Celesti") {
                SabellaTVLoadingState("Launching demo mode…")
            }
        }
    }

    private var signedInHome: some View {
        SabellaTVChannelHome(
            productName: "Celesti",
            state: channelHomeState,
            retry: { Task { await appModel.refreshChannelGroups() } }
        ) { selected in
            guard let group = appModel.channelGroups.first(where: { $0.id == selected.id }) else { return }
            Task { await appModel.selectChannelGroup(group) }
        }
    }

    private var channelHomeState: SabellaTVChannelHomeState {
        if appModel.channelGroupsLoading { return .loading }
        if let error = appModel.channelGroupsError { return .failed(message: error) }
        if appModel.channelGroups.isEmpty { return .empty }
        return .ready(appModel.channelGroups.map {
            SabellaTVChannelGroupSummary(
                id: $0.id,
                name: $0.name,
                channelCount: $0.channelCount,
                systemImage: $0.kind == .collection ? "rectangle.stack.fill" : "tray.full.fill"
            )
        })
    }
}

private struct LiveChannelGroupView: View {
    @EnvironmentObject private var appModel: CelestiAppModel
    let group: CelestiChannelGroup

    var body: some View {
        SabellaTVLivePlayer(
            channels: channels,
            selection: Binding(
                get: { appModel.selectedChannelID ?? group.channels[0].id },
                set: { appModel.selectedChannelID = $0 }
            ),
            guideVisible: $appModel.channelGuideVisible,
            guideTitle: group.name,
            hasMoreChannels: group.channels.count < group.total,
            loadingMoreChannels: appModel.channelGuideLoadingMore,
            loadMoreChannels: appModel.loadMoreChannelsIfNeeded,
            onSelectionChanged: { selected in
                guard let channel = group.channels.first(where: { $0.id == selected.id }) else { return }
                appModel.selectLiveChannel(channel)
            },
            onExit: appModel.leaveChannelGroupPlayback
        )
    }

    private var channels: [SabellaTVChannel] {
        group.channels.enumerated().map { index, channel in
            SabellaTVChannel(
                id: channel.id,
                streamURL: URL(string: channel.streamUrl)!,
                number: String(format: "%03d", index + 1),
                name: channel.tvgName,
                mark: String(channel.tvgName.prefix(3)).uppercased(),
                tone: [.sea, .red, .gold, .terracotta][index % 4],
                now: channel.tvgName,
                progress: 1
            )
        }
    }
}

private struct PlaybackRootView: View {
    @EnvironmentObject private var appModel: CelestiAppModel

    let playback: PlaybackPresentation
    private static let qualityLabels = ["AUTO", "HD", "SD", "MED", "LOW", "MIN"]

    var body: some View {
        SabellaTVSinglePlayback(
            productName: "Celesti",
            station: playback.failedStreamName ?? playback.radioName ?? "Live stream",
            title: playback.streamTitle,
            isAudioOnly: playback.isAudioOnly,
            isBuffering: playback.isBuffering,
            isPlaying: !playback.isPaused,
            isFailed: playback.isPlaybackFailed,
            isDemo: playback.source == .demo,
            dvrVisible: appModel.dvrVisible,
            currentTime: playback.currentTime,
            duration: playback.duration,
            quality: qualityLabel,
            dvrAction: sabellaDVRAction,
            retry: appModel.retryPlayback,
            select: appModel.handlePlaybackSelect,
            restart: appModel.restartPlayback,
            togglePlayback: appModel.togglePlayPause,
            skipBackward: appModel.seekBackward,
            skipForward: appModel.seekForward,
            showTransport: { appModel.showDvrOverlay(action: .none) },
            exit: appModel.dismissPlayback
        ) {
            ZStack {
                if let coordinator = appModel.playerController.ksCoordinator,
                   let currentURL = appModel.playerController.currentURL {
                    KSVideoPlayer(coordinator: coordinator, url: currentURL, options: KSOptions())
                        .opacity(appModel.playerController.isUsingKSPlayer ? 1 : 0)
                }

                if !appModel.playerController.isUsingKSPlayer {
                    SabellaTVPlayerSurface(player: appModel.playerController.player, gravity: .resizeAspectFill)
                }
            }
        }
    }

    private var qualityLabel: String? {
        guard Self.qualityLabels.indices.contains(playback.qualityTier) else { return nil }
        return Self.qualityLabels[playback.qualityTier]
    }

    private var sabellaDVRAction: SabellaTVDVRAction {
        switch appModel.dvrAction {
        case .none: .none
        case .play: .play
        case .pause: .pause
        case .rewind: .rewind
        case .fastForward: .fastForward
        }
    }
}


#Preview {
    ContentView()
        .environmentObject(CelestiAppModel())
}
