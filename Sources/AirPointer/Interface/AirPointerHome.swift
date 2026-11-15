import AppKit

// The closed-case steps between connecting and ready: shut the lid, turn the
// case upright while it settles, then point at the calibration dots.
enum ClosedCaseStep:Equatable {case openLid,closeLid,turnUpright,holdStill,calibrate,recenter}
enum HomeControlPhase:Equatable {case needsInputs,connecting,needsAccessibility,ready,running,paused(String),closedCase(ClosedCaseStep)}

extension NSScreen {
    // Stays the same across unplugging and reordering, unlike the place in NSScreen.screens.
    var displayID:String? {
        guard let number=deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid=CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else{return nil}
        return CFUUIDCreateString(nil,uuid) as String
    }
}

struct PointerSettingsState:Equatable {
    var screens:[String]=[]
    var screen=0
    // The display someone picked in Settings. While it's unplugged the pointer uses another, and this waits for it to return.
    var screenID:String?=nil
    // Paired AirPods Pro by name; -1 until one is chosen among several.
    var pairs:[String]=[]
    var pair=0
    var speed=1.0
    var clickSound=true
    // The way this person's taps push the sensor, when setup learned one other than the usual.
    var tapDirection:[Double]?=nil

    // Slider legacy: 10…60 stored as pointerSensitivity; speed is that value / 25.
    private static let sensitivityKey="pointerSensitivity"
    private static let clickSoundKey="tapClickSound"
    private static let tapDirectionKey="tapDirection"
    private static let screenKey="pointerScreen"
    private static let screenIDKey="pointerScreenID"

    static func screenIndex(chosen:String?,current:Int,in displays:[String?])->Int {
        if let chosen,let found=displays.firstIndex(of:chosen){return found}
        return max(0,min(current,displays.count-1))
    }

    static func loadPersisted()->PointerSettingsState {
        var value=PointerSettingsState()
        if let saved=UserDefaults.standard.object(forKey:sensitivityKey) as? Double,saved.isFinite{
            value.speed=min(60,max(10,saved))/25
        }
        value.clickSound=UserDefaults.standard.object(forKey:clickSoundKey) as? Bool ?? true
        value.tapDirection=(UserDefaults.standard.array(forKey:tapDirectionKey) as? [Double]).flatMap{$0.count==3 ? $0:nil}
        if let saved=UserDefaults.standard.object(forKey:screenKey) as? Int{value.screen=max(0,saved)}
        value.screenID=UserDefaults.standard.string(forKey:screenIDKey)
        return value
    }

    mutating func clampSpeed(){speed=min(60,max(10,speed*25))/25}

    func persist(){
        UserDefaults.standard.set(min(60,max(10,speed*25)),forKey:Self.sensitivityKey)
        UserDefaults.standard.set(clickSound,forKey:Self.clickSoundKey)
        if let tapDirection{UserDefaults.standard.set(tapDirection,forKey:Self.tapDirectionKey)}else{UserDefaults.standard.removeObject(forKey:Self.tapDirectionKey)}
        UserDefaults.standard.set(screen,forKey:Self.screenKey)
        if let screenID{UserDefaults.standard.set(screenID,forKey:Self.screenIDKey)}else{UserDefaults.standard.removeObject(forKey:Self.screenIDKey)}
    }
}

func runPointerSettingsChecks()throws {
    let defaults=UserDefaults.standard
    let keys=["pointerSensitivity","tapClickSound","pointerScreen","pointerScreenID","tapDirection"]
    let prior=Dictionary(uniqueKeysWithValues:keys.map{($0,defaults.object(forKey:$0))})
    defer{for key in keys{if let value=prior[key]{defaults.set(value,forKey:key)}else{defaults.removeObject(forKey:key)}}}
    defaults.removeObject(forKey:"pointerSensitivity")
    defaults.removeObject(forKey:"tapClickSound")
    defaults.removeObject(forKey:"pointerScreen")
    defaults.removeObject(forKey:"pointerScreenID")
    defaults.removeObject(forKey:"tapDirection")
    let fresh=PointerSettingsState.loadPersisted()
    guard fresh.speed==1,fresh.clickSound,fresh.screen==0,fresh.screenID==nil,fresh.tapDirection==nil else{
        throw LessonError.message("Default pointer settings should be speed 1, click sound on, screen 0.")
    }
    var sample=PointerSettingsState(screen:1,screenID:"side",speed:1.4,clickSound:false,tapDirection:[0.6,0,-0.8])
    sample.clampSpeed();sample.persist()
    let loaded=PointerSettingsState.loadPersisted()
    guard abs(loaded.speed-1.4)<1e-9,!loaded.clickSound,loaded.screen==1,loaded.screenID=="side",loaded.tapDirection==[0.6,0,-0.8] else{
        throw LessonError.message("Pointer settings did not round-trip through UserDefaults.")
    }
    // The chosen display wherever it now sits; with it unplugged, a display that exists; with no choice, the same place.
    guard PointerSettingsState.screenIndex(chosen:"side",current:0,in:["main","other","side"])==2,
          PointerSettingsState.screenIndex(chosen:"side",current:2,in:["main","other"])==1,
          PointerSettingsState.screenIndex(chosen:"side",current:1,in:[nil,"other"])==1,
          PointerSettingsState.screenIndex(chosen:nil,current:1,in:["main","other"])==1,
          PointerSettingsState.screenIndex(chosen:"side",current:3,in:[])==0 else{
        throw LessonError.message("The chosen display wasn’t found after the displays changed.")
    }
}

// MARK: - Copy

private struct HomeControlKey:Equatable {let phase:HomeControlPhase;let inputs:Bool}

private func hmCommand(_ phase:HomeControlPhase)->(title:String,hint:String?) {
    switch phase {
    case .needsInputs:return ("连接 AirPods",nil)
    case .connecting:return ("取消","esc")
    case .needsAccessibility:return ("允许",nil)
    case .ready:return ("开始指向",PointerShortcut.current.label)
    case .running:return ("暂停",PointerShortcut.current.label)
    case .paused:return ("继续",PointerShortcut.current.label)
    case .closedCase(.openLid):return ("取消","esc")
    case .closedCase(.closeLid):return ("已合盖","Return")
    case .closedCase(.turnUpright),.closedCase(.holdStill):return ("取消","esc")
    case .closedCase(.calibrate):return ("开始校准",nil)
    case .closedCase(.recenter):return ("重新居中",nil)
    }
}
private func hmHero(_ phase:HomeControlPhase)->(String,String) {
    switch phase {
    case .needsInputs:return ("连接你的 AirPods","拿着合上盖的充电盒，两只 AirPods 都在里面。先连接，再打开盖子。")
    case .connecting:return ("正在寻找你的 AirPods…","盖子保持打开一会儿。")
    case .needsAccessibility:return ("允许控制","点按「允许」打开「辅助功能」列表，再把 AirPointer 拖进去，它就能移动指针并点击。")
    case .ready:return ("准备就绪","竖着拿住合盖的充电盒，对准屏幕。")
    case .running:return ("正在指向","用充电盒瞄准，轻敲正面即可点击。")
    case .paused(let reason):return ("已暂停",reason=="Paused" || reason.isEmpty ? "准备好了就继续。":reason)
    case .closedCase(.openLid):return ("打开盖子","打开盖子时 AirPointer 会连接。两只 AirPods 都留在里面。")
    case .closedCase(.closeLid):return ("合上盖子","两只 AirPods 都留在里面。AirPointer 会自动继续，也可以按 Return。")
    case .closedCase(.turnUpright):return ("把它竖起来","把合上的充电盒顺时针转四分之一圈。")
    case .closedCase(.holdStill):return ("放下它","把合上的充电盒在平整桌面上放一会儿。")
    case .closedCase(.calibrate):return ("指向圆点","对准屏幕上的每个圆点并保持不动，按 Esc 取消。")
    case .closedCase(.recenter):return ("指向中心","边缘位置已保存，所以只用一个点。按 Esc 取消。")
    }
}

// MARK: - Building blocks

// A vertical page column whose full-width rows track the column's width.
private final class PageColumn:NSStackView {
    init(spacing:CGFloat=12) {
        super.init(frame:.zero)
        orientation = .vertical;alignment = .leading;self.spacing=spacing
        translatesAutoresizingMaskIntoConstraints=false
    }
    required init?(coder:NSCoder){fatalError("init(coder:) is not used")}
    func addFull(_ view:NSView) {
        view.translatesAutoresizingMaskIntoConstraints=false
        addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo:widthAnchor).isActive=true
    }
    // The column pins leading edges, so centered rows sit in a full-width holder.
    func addCentered(_ view:NSView) {
        let holder=NSView();view.translatesAutoresizingMaskIntoConstraints=false;holder.addSubview(view)
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo:holder.centerXAnchor),
            view.topAnchor.constraint(equalTo:holder.topAnchor),view.bottomAnchor.constraint(equalTo:holder.bottomAnchor),
            view.leadingAnchor.constraint(greaterThanOrEqualTo:holder.leadingAnchor),
        ])
        addFull(holder)
    }
    func gap(_ value:CGFloat){if let last=arrangedSubviews.last{setCustomSpacing(value,after:last)}}
    @discardableResult func addHeader(_ text:String)->NSTextField {
        gap(24)
        let label=hmEyebrow(text);addFull(label);setCustomSpacing(8,after:label)
        return label
    }
}
private func hmEyebrow(_ text:String)->NSTextField {
    let label=rkLabel(text,11,.semibold,.secondaryLabelColor)
    label.attributedStringValue=NSAttributedString(string:text.uppercased(),attributes:[.font:NSFont.systemFont(ofSize:11,weight:.semibold),.foregroundColor:NSColor.secondaryLabelColor,.kern:0.6])
    label.setAccessibilityLabel(text)
    return label
}
private func hmScrollPage(top:CGFloat=8)->(NSScrollView,PageColumn) {
    let scroll=NSScrollView();scroll.drawsBackground=false;scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true
    scroll.borderType = .noBorder;scroll.scrollerStyle = .overlay;scroll.translatesAutoresizingMaskIntoConstraints=false
    let document=RemoteFlipped();document.translatesAutoresizingMaskIntoConstraints=false
    scroll.documentView=document
    let column=PageColumn();document.addSubview(column)
    let clip=scroll.contentView
    NSLayoutConstraint.activate([
        document.leadingAnchor.constraint(equalTo:clip.leadingAnchor),
        document.trailingAnchor.constraint(equalTo:clip.trailingAnchor),
        document.topAnchor.constraint(equalTo:clip.topAnchor),
        column.leadingAnchor.constraint(equalTo:document.leadingAnchor,constant:24),
        column.trailingAnchor.constraint(equalTo:document.trailingAnchor,constant:-24),
        column.topAnchor.constraint(equalTo:document.topAnchor,constant:top),
        column.bottomAnchor.constraint(equalTo:document.bottomAnchor,constant:-24),
    ])
    return (scroll,column)
}
private func hmRow(_ leading:[NSView],trailing:[NSView]=[],spacing:CGFloat=8)->NSStackView {
    let row=rkHStack(leading+[rkSpacer()]+trailing,spacing:spacing)
    return row
}
private func hmSettingRow(_ title:String,_ caption:String?,_ control:NSView)->NSStackView {
    hmSettingRow(title,detail:caption.map{rkWrap($0,12)},control)
}
private func hmSettingRow(_ title:String,detail:NSView?,_ control:NSView)->NSStackView {
    let text=rkVStack([rkLabel(title,13,.medium)],spacing:2)
    if let detail{text.addArrangedSubview(detail)}
    text.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
    control.setContentHuggingPriority(.required,for:.horizontal)
    let row=rkHStack([text,rkSpacer(),control],spacing:16)
    row.heightAnchor.constraint(greaterThanOrEqualToConstant:44).isActive=true
    return row
}

// A dismissible line at the top of the window for things that went wrong.
private final class NoticeBar:NSView {
    private let text=rkWrap("",12,.labelColor)
    private let icon=rkSymbolView("exclamationmark.circle",13,.secondaryLabelColor)
    private let close=NSButton()
    init() {
        super.init(frame:.zero);translatesAutoresizingMaskIntoConstraints=false
        close.image=rkSymbol("xmark",10,.semibold);close.isBordered=false;close.imagePosition = .imageOnly
        close.contentTintColor = .secondaryLabelColor;close.target=self;close.action=#selector(dismiss)
        close.setAccessibilityLabel("关闭")
        // The message takes the width left over, so the dismiss button sits at the trailing edge.
        text.setContentHuggingPriority(.init(1),for:.horizontal);close.setContentHuggingPriority(.required,for:.horizontal)
        let row=rkHStack([icon,text,close],spacing:10);row.alignment = .firstBaseline;row.distribution = .fill
        let surface=RemoteSurface(HomePalette.raised,radius:10)
        rkPin(surface,in:self,insets:NSEdgeInsets(top:4,left:16,bottom:8,right:16))
        rkPin(row,in:surface,insets:NSEdgeInsets(top:10,left:12,bottom:10,right:10))
        isHidden=true
    }
    required init?(coder:NSCoder){fatalError("init(coder:) is not used")}
    func set(_ value:String?) {
        let value=value?.trimmingCharacters(in:.whitespacesAndNewlines)
        isHidden=value?.isEmpty ?? true
        if let value,!value.isEmpty,text.stringValue != value {
            text.stringValue=value
            NSAccessibility.post(element:text,notification:.announcementRequested,userInfo:[.announcement:value,.priority:NSAccessibilityPriorityLevel.high.rawValue])
        }
    }
    @objc private func dismiss(){isHidden=true}
}

// MARK: - Window

private enum HomePage:Equatable {case pointer,settings}

// A key window where bare Esc goes to the page unless a field is being edited.
final class HomeWindow:NSWindow {
    var onEscape:(()->Void)?
    override func sendEvent(_ event:NSEvent) {
        if event.type == .keyDown,!event.isARepeat,
           event.modifierFlags.intersection([.command,.control,.option]).isEmpty {
            let editing=firstResponder is NSTextView || firstResponder is NSTextField
            if event.keyCode==53,!editing,let onEscape{onEscape();return}
        }
        super.sendEvent(event)
    }
}

final class AirPointerHome:NSObject,NSWindowDelegate {
    let window:HomeWindow
    var onControl:(()->Void)?
    var onRecenter:(()->Void)?
    var onLearnGrip:(()->Void)?
    var onDisconnect:(()->Void)?
    var onSetup:(()->Void)?
    var onTeachTap:(()->Void)?
    var onSettings:(()->Void)?
    var onPointerSettingsChange:((PointerSettingsState)->Void)?
    var onClose:(()->Void)?

    fileprivate var phase=HomeControlPhase.needsInputs
    fileprivate var inputsReady=false
    fileprivate var pointerSettings=PointerSettingsState()

    let pad:AimPadView
    private let pageHost=NSView()
    private let notice=NoticeBar()
    private lazy var pointerPage=PointerPage(home:self)
    private lazy var settingsPage=SettingsPage(home:self)
    fileprivate private(set) var page=HomePage.pointer
    private var controlKey:HomeControlKey?

    init(pad:AimPadView=AimPadView()) {
        self.pad=pad;pad.setAccessibilityElement(true);pad.setAccessibilityRole(.image)
        window=HomeWindow(contentRect:NSRect(x:0,y:0,width:440,height:700),styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        super.init()
        window.title="AirPointer";window.titleVisibility = .hidden
        window.isReleasedWhenClosed=false;window.delegate=self
        window.titlebarAppearsTransparent=true;window.titlebarSeparatorStyle = .none
        window.backgroundColor=HomePalette.canvas
        window.contentMinSize=NSSize(width:400,height:620);window.contentMaxSize=NSSize(width:560,height:4000)
        let toolbar=NSToolbar(identifier:"AirPointerRemote")
        toolbar.delegate=self;toolbar.displayMode = .iconOnly;toolbar.allowsUserCustomization=false
        if #available(macOS 15,*){toolbar.allowsDisplayModeCustomization=false}
        window.toolbar=toolbar;window.toolbarStyle = .unified
        let root=RemoteSurface(HomePalette.canvas)
        let stack=rkVStack([notice,pageHost],spacing:0,align:.leading)
        pageHost.translatesAutoresizingMaskIntoConstraints=false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo:root.safeAreaLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo:root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo:root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo:root.bottomAnchor),
            notice.widthAnchor.constraint(equalTo:stack.widthAnchor),
            pageHost.widthAnchor.constraint(equalTo:stack.widthAnchor),
        ])
        window.contentView=root
        window.setContentSize(NSSize(width:440,height:700))
        window.center()
        window.onEscape={[weak self] in self?.handleEscape()}
        present(.pointer)
    }

    // MARK: Public API

    func show() {
        if window.isMiniaturized{window.deminiaturize(nil)}
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
    }

    // Called about 12 times a second: returns early unless something visible changed.
    func updateControl(phase:HomeControlPhase,inputsReady:Bool) {
        let key=HomeControlKey(phase:phase,inputs:inputsReady)
        guard key != controlKey else{return}
        let announce=controlKey != nil && phase != self.phase
        controlKey=key
        self.phase=phase;self.inputsReady=inputsReady
        pointerPage.render()
        if announce{NSAccessibility.post(element:window,notification:.announcementRequested,userInfo:[.announcement:hmHero(phase).0,.priority:NSAccessibilityPriorityLevel.high.rawValue])}
    }

    func updateHold(_ progress:CGFloat?){pointerPage.updateHold(progress)}
    func setNotice(_ text:String?){notice.set(text)}
    func selectPointer(){present(.pointer)}
    func selectSettings() {
        guard page != .settings else{return}
        present(.settings)
        NSAccessibility.post(element:window,notification:.announcementRequested,userInfo:[.announcement:"设置",.priority:NSAccessibilityPriorityLevel.medium.rawValue])
    }
    func updatePointerSettings(_ value:PointerSettingsState) {
        guard value != pointerSettings else{return}
        pointerSettings=value;settingsPage.apply();pointerPage.render()
    }

    // MARK: Shared with pages

    fileprivate func changePointerSettings(_ value:PointerSettingsState) {
        pointerSettings=value;settingsPage.apply();pointerPage.render();onPointerSettingsChange?(value)
    }

    fileprivate func present(_ next:HomePage) {
        if next != page {
            if let responder=window.firstResponder as? NSView,responder.isDescendant(of:pageHost){_ = window.makeFirstResponder(nil)}
        }
        page=next
        let view:NSView
        switch next {
        case .pointer:pointerPage.render();view=pointerPage.view
        case .settings:settingsPage.apply();view=settingsPage.view
        }
        guard pageHost.subviews.first !== view else{return}
        pageHost.subviews.forEach{$0.removeFromSuperview()}
        rkPin(view,in:pageHost)
    }

    // MARK: Actions and keys

    @objc fileprivate func openSettings(){onSettings?()}

    private func handleEscape() {
        switch phase {
        case .running,.connecting,.closedCase(.openLid),.closedCase(.turnUpright),.closedCase(.holdStill):onControl?();return
        default:break
        }
        if page == .settings{present(.pointer)}
    }

    func windowWillClose(_ notification:Notification) {
        onClose?()
    }
}

private extension NSToolbarItem.Identifier {
    static let homeSettings=NSToolbarItem.Identifier("AirPointerSettings")
}

extension AirPointerHome:NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar:NSToolbar)->[NSToolbarItem.Identifier]{[.flexibleSpace,.homeSettings]}
    func toolbarAllowedItemIdentifiers(_ toolbar:NSToolbar)->[NSToolbarItem.Identifier]{toolbarDefaultItemIdentifiers(toolbar)}
    func toolbar(_ toolbar:NSToolbar,itemForItemIdentifier identifier:NSToolbarItem.Identifier,willBeInsertedIntoToolbar flag:Bool)->NSToolbarItem? {
        let item=NSToolbarItem(itemIdentifier:identifier)
        if identifier == .homeSettings {
            item.image=rkSymbol("gearshape",15);item.label="设置";item.toolTip="设置 (⌘,)"
            item.isBordered=true;item.target=self;item.action=#selector(openSettings)
        } else{return nil}
        return item
    }
}

// MARK: - Pointer

private final class PointerPage:NSObject {
    unowned let home:AirPointerHome
    let view:NSScrollView
    private let stage=RemoteSurface(HomePalette.stage,radius:18)
    private let art=CaseStepView()
    private let chip=StatusChip()
    private let title=rkTitle("",26,align:.center)
    private let subtitle=rkWrap("",13,align:.center)
    private let primary=RemoteButton("开始指向",height:48)
    private let recenter=RemoteButton("重新居中",style:.tertiary,symbol:"scope",height:32)
    private let recalibrate=RemoteButton("重新校准…",style:.tertiary,symbol:"dot.viewfinder",height:32)
    private let disconnect=RemoteButton("断开连接",style:.tertiary,symbol:"xmark.circle",height:32)
    private let secondary=NSStackView()
    private var showingPad:Bool?

    init(home:AirPointerHome) {
        self.home=home
        let page=hmScrollPage(top:4);view=page.0
        super.init()
        let column=page.1
        stage.translatesAutoresizingMaskIntoConstraints=false
        stage.heightAnchor.constraint(equalToConstant:228).isActive=true
        art.fill=0.86
        for view in [art,home.pad] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints=false;stage.addSubview(view)
        }
        NSLayoutConstraint.activate([
            art.topAnchor.constraint(equalTo:stage.topAnchor,constant:8),art.bottomAnchor.constraint(equalTo:stage.bottomAnchor,constant:-8),
            art.leadingAnchor.constraint(equalTo:stage.leadingAnchor),art.trailingAnchor.constraint(equalTo:stage.trailingAnchor),
            home.pad.centerXAnchor.constraint(equalTo:stage.centerXAnchor),home.pad.centerYAnchor.constraint(equalTo:stage.centerYAnchor),
            home.pad.heightAnchor.constraint(equalTo:stage.heightAnchor,constant:-32),
            home.pad.widthAnchor.constraint(equalTo:home.pad.heightAnchor,multiplier:1.6),
        ])
        column.addFull(stage);column.gap(18)
        column.addCentered(chip);column.gap(12)
        column.addFull(title);column.gap(6)
        column.addFull(subtitle);column.gap(22)
        primary.target=self;primary.action=#selector(primaryPressed)
        column.addFull(primary);column.gap(8)
        recenter.target=self;recenter.action=#selector(recenterPressed)
        recalibrate.target=self;recalibrate.action=#selector(recalibratePressed)
        disconnect.target=self;disconnect.action=#selector(disconnectPressed)
        recenter.toolTip="以当前瞄准的位置重新居中";recalibrate.toolTip="指向三个圆点，让 AirPointer 知道屏幕的位置"
        disconnect.toolTip="结束连接。要重新连接，请再连接一次并打开盖子。"
        secondary.orientation = .horizontal;secondary.spacing=4
        secondary.addArrangedSubview(recenter);secondary.addArrangedSubview(recalibrate);secondary.addArrangedSubview(disconnect)
        column.addCentered(secondary)
        render()
    }

    func render() {
        let phase=home.phase
        let hero=hmHero(phase),command=hmCommand(phase)
        rkSetText(title,hero.0);rkSetText(subtitle,hero.1)
        if primary.title != command.title{primary.title=command.title}
        if primary.hint != command.hint{primary.hint=command.hint}
        // The hint names the key: Return confirms the closed lid, esc cancels.
        let key=command.hint=="Return" ? "\r":command.hint=="esc" ? "\u{1b}":""
        if primary.keyEquivalent != key{primary.keyEquivalent=key}
        // Until the closed case is upright and held, the stage shows the step to do with it.
        let connected:Bool
        switch phase {
        // Closed before Connect and while asking for Accessibility, the lid opening while Connect waits, then the open case.
        case .needsInputs:connected=false;art.step = .closed
        case .closedCase(.openLid):connected=false;art.step = .opening
        case .connecting:connected=false;art.step = .open
        case .closedCase(.closeLid):connected=false;art.step = .close
        case .closedCase(.turnUpright):connected=false;art.step = .turn
        case .closedCase(.holdStill):connected=false;art.step = .closed
        case .needsAccessibility:connected=home.inputsReady;art.step = .closed
        default:connected=true
        }
        let live:Bool
        switch phase {
        case .needsInputs:chip.set("未连接",dot:false);live=false
        case .connecting:chip.set("正在连接…",dot:false);live=false
        case .closedCase(.openLid):chip.set("等待开盖",dot:false);live=false
        case .needsAccessibility:chip.set(connected ? "已连接":"未连接",dot:connected);live=false
        case .ready:chip.set("已连接");live=false
        case .running:chip.set("指向中",live:true);live=true
        case .paused:chip.set("已暂停");live=false
        case .closedCase(.closeLid):chip.set("已连接");live=false
        case .closedCase(.turnUpright):chip.set("已连接");live=false
        case .closedCase(.holdStill):chip.set("保持不动",dot:false);live=false
        case .closedCase(.calibrate):chip.set("正在校准",dot:false);live=false
        case .closedCase(.recenter):chip.set("正在居中",dot:false);live=false
        }
        if showingPad != connected {
            showingPad=connected
            home.pad.isHidden = !connected;art.isHidden=connected
        }
        home.pad.live=live;home.pad.setAccessibilityLabel(live ? "指针预览，实时":"指针预览")
        let screens=home.pointerSettings.screens
        home.pad.caption=screens.indices.contains(home.pointerSettings.screen) && screens.count>1 ? screens[home.pointerSettings.screen]:""
        // Centered rows live in holders; hiding the holder collapses the row.
        // The closed case stays connected through Pause until Disconnect.
        switch phase {
        case .running,.paused:recenter.isHidden=false;recalibrate.isHidden=false;disconnect.isHidden=false;secondary.superview?.isHidden=false
        case .ready:recenter.isHidden=true;recalibrate.isHidden=false;disconnect.isHidden=false;secondary.superview?.isHidden=false
        case .closedCase(.calibrate):recenter.isHidden=true;recalibrate.isHidden=true;disconnect.isHidden=false;secondary.superview?.isHidden=false
        // Saved edges might not suit a new grip, so all three dots stay one click away.
        case .closedCase(.recenter):recenter.isHidden=true;recalibrate.isHidden=false;disconnect.isHidden=false;secondary.superview?.isHidden=false
        default:secondary.superview?.isHidden=true
        }
    }

    func updateHold(_ progress:CGFloat?){art.holdProgress=progress}
    @objc private func primaryPressed(){home.onControl?()}
    @objc private func recenterPressed(){home.onRecenter?()}
    @objc private func recalibratePressed(){home.onLearnGrip?()}
    @objc private func disconnectPressed(){home.onDisconnect?()}
}

// MARK: - Settings

private final class SettingsPage:NSObject {
    unowned let home:AirPointerHome
    let view:NSScrollView
    private let screens=NSPopUpButton()
    private let pairs=NSPopUpButton()
    private let speed=NSSlider(value:1,minValue:0.4,maxValue:2.4,target:nil,action:nil)
    private let clickSound=InkSwitch()
    private let shortcutControl=PointerShortcutControl()
    private let speedValue=rkLabel("1.0×",13,.medium)

    init(home:AirPointerHome) {
        self.home=home
        let page=hmScrollPage(top:2);view=page.0
        super.init()
        let column=page.1
        // With no section tabs, this is the way back besides esc and ⌘1.
        let back=RemoteButton("指向",style:.tertiary,symbol:"chevron.left",height:28,target:self,action:#selector(backPressed))
        back.setAccessibilityLabel("返回指向页")
        column.addFull(hmRow([back]));column.gap(4)
        column.addFull(rkLabel("设置",22,.bold))
        column.addHeader("AirPods")
        pairs.target=self;pairs.action=#selector(changed(_:));pairs.setAccessibilityLabel("要连接的 AirPods")
        column.addFull(hmSettingRow("连接到",nil,pairs))
        column.addHeader("屏幕")
        screens.target=self;screens.action=#selector(changed(_:));screens.setAccessibilityLabel("要控制的屏幕")
        column.addFull(hmSettingRow("指向屏幕",nil,screens))
        column.addHeader("指针速度")
        speed.target=self;speed.action=#selector(changed(_:));speed.isContinuous=true;speed.setAccessibilityLabel("指针速度")
        speedValue.font = .monospacedDigitSystemFont(ofSize:13,weight:.medium)
        speedValue.setContentHuggingPriority(.required,for:.horizontal)
        let ends=hmRow([rkLabel("更慢",12,.regular,.secondaryLabelColor)],trailing:[rkLabel("更快",12,.regular,.secondaryLabelColor)])
        let track=rkVStack([speed,ends],spacing:2,align:.leading)
        ends.widthAnchor.constraint(equalTo:speed.widthAnchor).isActive=true
        speed.widthAnchor.constraint(equalTo:track.widthAnchor).isActive=true
        track.setHuggingPriority(.init(1),for:.horizontal)
        let slider=rkHStack([track,speedValue],spacing:14);slider.alignment = .top
        column.addFull(slider)
        column.addHeader("轻敲点击")
        clickSound.setAccessibilityLabel("点击音效");clickSound.onChange={[weak self] _ in self?.changed(nil)}
        column.addFull(hmSettingRow("点击音效","轻敲充电盒触发点击时，在这台 Mac 上播放声音。",clickSound))
        let teachTap=RemoteButton("轻敲教学…",style:.secondary,height:32,target:self,action:#selector(teachTap))
        column.addFull(hmSettingRow("你的轻敲","在充电盒上轻敲三次，让 AirPointer 熟悉你的敲击力度。",teachTap))
        column.addHeader("校准")
        let recalibrate=RemoteButton("重新校准…",style:.secondary,height:32,target:self,action:#selector(recalibrate))
        column.addFull(hmSettingRow("你的屏幕","指向三个圆点，让 AirPointer 知道屏幕在哪。",recalibrate))
        column.addHeader("快捷键")
        column.addFull(hmSettingRow("开关指针",detail:shortcutControl.note,shortcutControl))
        column.addFull(RemoteRule())
        let setup=RemoteButton("重新运行设置…",style:.secondary,height:32,target:self,action:#selector(setup))
        column.addFull(hmSettingRow("设置引导","重新走一遍连接、权限和校准流程。",setup))
        apply()
    }

    func apply() {
        let state=home.pointerSettings
        if screens.itemTitles != state.screens{screens.removeAllItems();screens.addItems(withTitles:state.screens)}
        if screens.itemArray.indices.contains(state.screen){screens.selectItem(at:state.screen)}
        screens.isEnabled=state.screens.count>1
        let pairTitles=state.pairs.isEmpty ? ["未找到 AirPods Pro"]:state.pair<0 ? ["选择你的 AirPods"]+state.pairs:state.pairs
        if pairs.itemTitles != pairTitles{pairs.removeAllItems();pairs.addItems(withTitles:pairTitles)}
        pairs.selectItem(at:max(0,state.pair));pairs.isEnabled=state.pairs.count>1
        speed.doubleValue=state.speed
        rkSetText(speedValue,String(format:"%.1f×",state.speed))
        speed.setAccessibilityValueDescription(String(format:"是正常速度的 %.1f 倍",state.speed))
        clickSound.setOn(state.clickSound,animated:false)
    }
    @objc private func changed(_ sender:Any?) {
        var value=home.pointerSettings
        value.screen=max(0,screens.indexOfSelectedItem);value.speed=(speed.doubleValue*10).rounded()/10;value.clickSound=clickSound.isOn
        if !value.pairs.isEmpty{value.pair=pairs.indexOfSelectedItem-(value.pair<0 ? 1:0)}
        home.changePointerSettings(value)
    }
    @objc private func backPressed(){home.present(.pointer)}
    @objc private func recalibrate(){home.onLearnGrip?()}
    @objc private func setup(){home.onSetup?()}
    @objc private func teachTap(){home.onTeachTap?()}
}
