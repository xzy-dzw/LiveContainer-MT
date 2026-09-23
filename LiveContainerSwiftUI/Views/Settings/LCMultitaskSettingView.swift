//
//  LCMultitaskSettingView.swift
//  LiveContainer
//
//  Created by s s on 2026/3/21.
//

import SwiftUI

struct LCMultitaskSettingView: View {
    @AppStorage("LCMultitaskMode", store: LCUtils.appGroupUserDefault) var multitaskMode: MultitaskMode = .virtualWindow
    @AppStorage("LCLaunchInMultitaskMode") var launchInMultitaskMode = false
    @AppStorage("LCLaunchMultitaskMaximized") var launchMultitaskMaximized = false
    @AppStorage("LCAutoEndPiP", store: LCUtils.appGroupUserDefault) var autoEndPiP = false
    @AppStorage("LCSkipTerminatedScreen", store: LCUtils.appGroupUserDefault) var skipTerminatedScreen = false
    @AppStorage("LCRestartTerminatedApp", store: LCUtils.appGroupUserDefault) var restartTerminatedApp = false
    @AppStorage("LCRedirectURLToHost", store: LCUtils.appGroupUserDefault) var redirectURLToHost = false
    // Default ON: the AppStorage literal only drives the UI when the key is absent; the host
    // and guests treat a missing key as ON as well, so a fresh install shows and runs keep-alive.
    @AppStorage("LCStageKeepAliveAudio", store: LCUtils.appGroupUserDefault) var keepAliveAudio = true
    @AppStorage("LCAutoRecoverGuest", store: LCUtils.appGroupUserDefault) var autoRecoverGuest = true
    @AppStorage("LCStageKeepAlivePiP", store: LCUtils.appGroupUserDefault) var keepAlivePiP = true
    @AppStorage("LCStageKeepAliveLocation", store: LCUtils.appGroupUserDefault) var keepAliveLocation = true

    var body: some View {
        List {
            Section {
                if(UIApplication.shared.supportsMultipleScenes) {
                    Picker(selection: $multitaskMode) {
                        Text("lc.settings.multitaskMode.virtualWindow".loc).tag(MultitaskMode.virtualWindow)
                        Text("lc.settings.multitaskMode.nativeWindow".loc).tag(MultitaskMode.nativeWindow)
                    } label: {
                        Text("lc.settings.multitaskMode".loc)
                    }
                }
                Toggle(isOn: $launchInMultitaskMode) {
                    Text("lc.settings.autoLaunchInMultitaskMode".loc)
                }
                
                if multitaskMode == .virtualWindow {
                    Toggle(isOn: $launchMultitaskMaximized) {
                        Text("lc.settings.launchMultitaskMaximized".loc)
                    }
                    Toggle(isOn: $autoEndPiP) {
                        Text("lc.settings.autoEndPiP".loc)
                    }
                    Toggle(isOn: $skipTerminatedScreen) {
                        Text("lc.settings.skipTerminatedScreen".loc)
                    }
                    if skipTerminatedScreen {
                        Toggle(isOn: $restartTerminatedApp) {
                            Text("lc.settings.restartTerminatedApp".loc)
                        }
                    }
                    Toggle(isOn: $redirectURLToHost) {
                        Text("lc.settings.redirectURLToHost".loc)
                    }
                    Toggle(isOn: $keepAliveAudio) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("lc.settings.stageKeepAliveAudio".loc)
                            Text("lc.settings.stageKeepAliveAudio.detail".loc)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .onChange(of: keepAliveAudio) { _ in
                        if #available(iOS 16.0, *) {
                            MultitaskDockManager.shared.applyKeepAliveSettings()
                        }
                    }
                    Toggle(isOn: $keepAlivePiP) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("lc.settings.stageKeepAlivePiP".loc)
                            Text("lc.settings.stageKeepAlivePiP.detail".loc)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .onChange(of: keepAlivePiP) { _ in
                        if #available(iOS 16.0, *) {
                            MultitaskDockManager.shared.applyKeepAliveSettings()
                        }
                    }
                    Toggle(isOn: $keepAliveLocation) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("lc.settings.stageKeepAliveLocation".loc)
                            Text("lc.settings.stageKeepAliveLocation.detail".loc)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .onChange(of: keepAliveLocation) { _ in
                        if #available(iOS 16.0, *) {
                            MultitaskDockManager.shared.applyKeepAliveSettings()
                        }
                    }
                    Toggle(isOn: $autoRecoverGuest) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("lc.settings.autoRecoverGuest".loc)
                            Text("lc.settings.autoRecoverGuest.detail".loc)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                }
            }
        }
        .navigationTitle("lc.appBanner.multitask".loc)
        .navigationBarTitleDisplayMode(.inline)
    }
}
