import AppKit
import ApplicationServices
import Carbon

func screenPoint(_ normalized: CGPoint, bounds: CGRect) -> CGPoint {
    CGPoint(x: bounds.minX + 1 + normalized.x * (bounds.width - 2),
            y: bounds.minY + 1 + normalized.y * (bounds.height - 2))
}

final class App: NSObject, NSApplicationDelegate {
    var statusBar:StatusBarController?
    lazy var hud=ControlHUD()
    var hudPhase=HomeControlPhase.needsInputs
    var macAudioProtectionItem:NSMenuItem?
    var macAudioProtectionEnabled=true
    var closedCaseOwnsInput=false
    lazy var calibrator = CaseCalibrator()
    // Persisted pointer prefs. Settings UI and sessions read/write this value; no invisible AppKit controls.
    var pointerSettings=PointerSettingsState.loadPersisted()
    var closedCaseSession:ClosedCaseSession?
    var tapTestWindow:TapTestWindow?
    var setupTaps=SetupTaps()
    // Set when the person backs out of closed-case calibration, so the dots don't reopen on the next tick.
    var closedCalibrationDeclined=false
    // Paired AirPods Pro, refreshed when Settings opens.
    var closedCasePairs:[ClosedCaseAirPods]=[]
    var timer: Timer?
    var homeMenuItems:[NSMenuItem]=[]
    var disconnectMenuItem:NSMenuItem?
    var home:AirPointerHome?
    let homePreview=AimPadView()
    var homePhase=HomeControlPhase.needsInputs
    var setup:SetupAssistant?
    var notch:NotchFlow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.global(qos: .utility).async { pruneClosedCaseSessions(in: ClosedCaseSession.pointerSessions, keeping: ClosedCaseSession.keptSessions) }
        NSApp.setActivationPolicy(.regular)
        if let url=Bundle.main.url(forResource:"AppIcon",withExtension:"icns"),let icon=NSImage(contentsOf:url){
            NSApp.applicationIconImage=icon
            NSApp.dockTile.display()
        }
        refreshScreenList()
        calibrator.onCancel = { [weak self] in
            if self?.closedCaseSession?.isActive == true { self?.closedCalibrationDeclined = true; self?.refreshHome() }
        }
        CursorSize.shared.restore()
        AudioOutputGuard.shared.restoreAfterCrash()
        setupMenu()
        installNotch()
        let stateTimer=Timer(timeInterval:0.08,repeats:true){[weak self] _ in self?.checkState()}
        RunLoop.main.add(stateTimer,forMode:.common);timer=stateTimer
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        if needsSetup{showSetup()}
        else{showHome()}
    }

    @objc func recalibrate() {
        if let session=closedCaseSession,session.isActive{closedCalibrationDeclined=false;session.recalibrate();return}
        // Calibration captures from the closed case, so it needs a connection first.
        pause();showHome();home?.setNotice("请先连接 AirPods，再重新校准。")
    }
    func refreshScreenList() {
        pointerSettings.screen=PointerSettingsState.screenIndex(chosen:pointerSettings.screenID,current:pointerSettings.screen,in:NSScreen.screens.map(\.displayID))
    }
    @objc func screensChanged() {
        pause("显示器发生了变化。准备好了就继续。"); refreshScreenList(); pointerSettings.persist()
        closedCaseSession?.refreshDisplays(selecting: pointerSettings.screen)
    }
    @objc func willSleep() { pause(); calibrator.disconnected() }

    func setupMenu() {
        let main=NSMenu()
        func addMenu(_ title:String)->NSMenu {
            let menu=NSMenu(title:title),item=NSMenuItem(title:title,action:nil,keyEquivalent:"")
            item.submenu=menu;main.addItem(item);return menu
        }
        func item(_ title:String,_ action:Selector,_ key:String="")->NSMenuItem {
            let value=NSMenuItem(title:title,action:action,keyEquivalent:key);value.target=self;return value
        }
        let appMenu=addMenu("AirPointer")
        appMenu.addItem(withTitle:"关于 AirPointer",action:#selector(NSApplication.orderFrontStandardAboutPanel(_:)),keyEquivalent:"")
        appMenu.addItem(.separator())
        appMenu.addItem(item("设置…",#selector(openHomeSettings),","))
        appMenu.addItem(item("重新运行设置…",#selector(runSetupAgain)))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle:"隐藏 AirPointer",action:#selector(NSApplication.hide(_:)),keyEquivalent:"h")
        let others=appMenu.addItem(withTitle:"隐藏其他",action:#selector(NSApplication.hideOtherApplications(_:)),keyEquivalent:"h");others.keyEquivalentModifierMask=[.command,.option]
        appMenu.addItem(withTitle:"全部显示",action:#selector(NSApplication.unhideAllApplications(_:)),keyEquivalent:"")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle:"退出 AirPointer",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let file=addMenu("文件")
        let start=item("开始指向",#selector(homeMenuControl));file.addItem(start);homeMenuItems.append(start)
        file.addItem(item("重新居中",#selector(homeMenuRecenter),"r"))
        file.addItem(item("重新校准…",#selector(recalibrate)))
        let disconnect=item("断开连接",#selector(disconnectClosedCase));file.addItem(disconnect);disconnectMenuItem=disconnect
        file.addItem(.separator())
        let developer=NSMenu(title:"开发者"),developerItem=NSMenuItem(title:"开发者",action:nil,keyEquivalent:"")
        developerItem.submenu=developer;file.addItem(developerItem)
        let macAudio=item("声音保留在 Mac 上",#selector(toggleMacAudioProtection));macAudio.state = .on
        developer.addItem(macAudio);macAudioProtectionItem=macAudio
        developer.addItem(item("轻敲测试…",#selector(showTapTest)))
        let edit=addMenu("编辑")
        edit.addItem(withTitle:"撤销",action:Selector(("undo:")),keyEquivalent:"z")
        let redo=edit.addItem(withTitle:"重做",action:Selector(("redo:")),keyEquivalent:"z");redo.keyEquivalentModifierMask=[.command,.shift]
        edit.addItem(.separator())
        edit.addItem(withTitle:"剪切",action:#selector(NSText.cut(_:)),keyEquivalent:"x")
        edit.addItem(withTitle:"拷贝",action:#selector(NSText.copy(_:)),keyEquivalent:"c")
        edit.addItem(withTitle:"粘贴",action:#selector(NSText.paste(_:)),keyEquivalent:"v")
        edit.addItem(withTitle:"全选",action:#selector(NSText.selectAll(_:)),keyEquivalent:"a")
        let view=addMenu("显示")
        view.addItem(item("指向",#selector(showPointerPage),"1"))
        let windows=addMenu("窗口")
        windows.addItem(withTitle:"最小化",action:#selector(NSWindow.performMiniaturize(_:)),keyEquivalent:"m")
        windows.addItem(withTitle:"关闭",action:#selector(NSWindow.performClose(_:)),keyEquivalent:"w")
        windows.addItem(.separator())
        windows.addItem(item("AirPointer",#selector(showWindow),"0"))
        NSApp.windowsMenu=windows
        NSApp.mainMenu=main
        installStatusBar()
    }
    @objc func showWindow() { showHome() }
    @objc func toggleMacAudioProtection(){
        macAudioProtectionEnabled.toggle()
        macAudioProtectionItem?.state=macAudioProtectionEnabled ? .on:.off
        AudioOutputGuard.shared.protects=macAudioProtectionEnabled
    }
    @objc func showTapTest(){
        if tapTestWindow==nil{tapTestWindow=TapTestWindow{[weak self] in self?.closedCaseSession}}
        tapTestWindow?.show()
    }
    func pause(_ reason:String="Paused") {
        let wasActive=closedCaseSession?.isActive == true
        closedCaseSession?.pause(reason)
        if wasActive{homePhase = .paused(reason)}
    }
    func checkState() {
        guard !closedCaseOwnsInput else{return}
        refreshHome();refreshSetup();refreshStatusBar()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    // The Dock brings back a hidden, minimized or closed window. The notch and HUD panels don't count as windows.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        sender.unhide(nil)
        let windows=sender.windows.filter{ !($0 is NSPanel) }
        if !windows.contains(where:{ $0.isVisible && !$0.isMiniaturized }){
            if let minimized=windows.first(where:\.isMiniaturized){minimized.deminiaturize(nil)}else{showHome()}
        }
        sender.activate(ignoringOtherApps:true)
        return false
    }
    func applicationWillTerminate(_ notification: Notification) {
        closedCaseSession?.shutdown()
        CursorSize.shared.restore()
        timer?.invalidate()
        calibrator.disconnected()
        AudioOutputGuard.shared.stop()
    }
}

@main
struct AirPointerMain {
static func main() {
if CommandLine.arguments.contains("--check-audio-output-policy") {
    runAudioOutputPolicyChecks()
} else if let index=CommandLine.arguments.firstIndex(of:"--check-closed-case-tap") {
    let fixtures=CommandLine.arguments.indices.contains(index+1) ? URL(fileURLWithPath:CommandLine.arguments[index+1]):nil
    do{try runClosedCaseTapChecks(fixtures:fixtures)}catch{fputs("Closed-case tap check failed: \(error.localizedDescription)\n",stderr);exit(1)}
} else if CommandLine.arguments.contains("--check-closed-case-native") {
    do{try runClosedCaseNativeChecks()}catch{fputs("Closed-case native check failed: \(error.localizedDescription)\n",stderr);exit(1)}
} else if CommandLine.arguments.contains("--check-home") {
    do{try runHomeChecks()}catch{fputs("Home check failed: \(error.localizedDescription)\n",stderr);exit(1)}
} else if CommandLine.arguments.contains("--check-pointer-settings") {
    do{try runPointerSettingsChecks()}catch{fputs("Pointer settings check failed: \(error.localizedDescription)\n",stderr);exit(1)}
} else if CommandLine.arguments.contains("--self-test") {
    runAudioOutputPolicyChecks()
    let bounds = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
    selfCheck(screenPoint(CGPoint(x: 0.5, y: 0.5), bounds: bounds) == CGPoint(x: -960, y: 540))
    selfCheck(screenPoint(.zero, bounds: bounds) == CGPoint(x: -1919, y: 1))
    selfCheck(screenPoint(CGPoint(x: 1, y: 1), bounds: bounds) == CGPoint(x: -1, y: 1079))
    runPoseChecks()
    do{try runPointerSettingsChecks()}catch{fputs("Pointer settings check failed: \(error.localizedDescription)\n",stderr);exit(1)}
    do{try runClosedCaseStageChecks()}catch{fputs("Closed-case stage check failed: \(error.localizedDescription)\n",stderr);exit(1)}
    do{try runClosedCaseTapChecks(fixtures:nil)}catch{fputs("Closed-case tap check failed: \(error.localizedDescription)\n",stderr);exit(1)}
    do{try runTapTestChecks()}catch{fputs("Tap test check failed: \(error.localizedDescription)\n",stderr);exit(1)}
    print("PASS: audio output policy, screen mapping, pose math, pointer settings, session stages, closed-case tap detection and the tap test")
} else {
    let app = NSApplication.shared
    let delegate = App()
    app.delegate = delegate
    app.run()
}

}
}
