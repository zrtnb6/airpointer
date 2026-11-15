import Foundation
import CoreBluetooth

let airPointerDataFolder=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
    .appendingPathComponent("AirPointer",isDirectory:true)

// The AirPods the closed-case pointer connects to, found among this Mac's paired devices by
// Apple's vendor and product IDs rather than by name. The address stays in Application Support
// and never goes into a log.
struct ClosedCaseAirPods:Equatable {
    let name:String,model:String,address:String,connected:Bool
    // Apple's product ID, which the lid broadcast also carries.
    var productID:UInt16=0
    var title:String{name.localizedCaseInsensitiveContains(model) ? name:"\(name) · \(model)"}
    // Tested with AirPods Pro 3. AirPods Pro 2 share the case the pointer talks to.
    static let models=["0x2014":"AirPods Pro 2","0x2024":"AirPods Pro 2","0x2027":"AirPods Pro 3"]
    static let targetURL=airPointerDataFolder.appendingPathComponent("closed-case-target.txt")

    enum Choice:Equatable {
        case chosen(ClosedCaseAirPods),missing,several,bluetoothOff,unreadable
        var failure:String? {
            switch self {
            case .chosen:return nil
            case .missing:return "这台 Mac 没有配对 AirPods Pro。请先在「系统设置 → 蓝牙」中配对，然后重新连接。"
            case .several:return "这台 Mac 配对了多副 AirPods Pro。请在设置中选择你的那副，然后重新连接。"
            case .bluetoothOff:return "蓝牙已关闭。请在控制中心打开蓝牙，然后重新连接。"
            case .unreadable:return "AirPointer 无法读取这台 Mac 的蓝牙设备。请重新连接。"
            }
        }
    }
    struct Survey{let poweredOn:Bool,pairs:[ClosedCaseAirPods]}

    static func normalized(_ address:String)->String {
        address.trimmingCharacters(in:.whitespacesAndNewlines).replacingOccurrences(of:"-",with:":").uppercased()
    }
    // `system_profiler SPBluetoothDataType -json`, connected pairs first. Same-named entries
    // without a product ID (the case's own radio, for one) are left out.
    static func parse(_ data:Data)->Survey? {
        guard let root=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
              let info=(root["SPBluetoothDataType"] as? [[String:Any]])?.first else{return nil}
        let state=(info["controller_properties"] as? [String:Any])?["controller_state"] as? String
        var pairs:[ClosedCaseAirPods]=[]
        for (key,connected) in [("device_connected",true),("device_not_connected",false)] {
            for entry in info[key] as? [[String:Any]] ?? [] {
                for (name,value) in entry {
                    guard let device=value as? [String:Any],(device["device_vendorID"] as? String)?.lowercased()=="0x004c",
                          let product=(device["device_productID"] as? String)?.lowercased(),let model=models[product],
                          let address=(device["device_address"] as? String).map(normalized),
                          address.range(of:"^(?:[0-9A-F]{2}:){5}[0-9A-F]{2}$",options:.regularExpression) != nil else{continue}
                    pairs.append(ClosedCaseAirPods(name:name,model:model,address:address,connected:connected,productID:UInt16(product.dropFirst(2),radix:16) ?? 0))
                }
            }
        }
        return Survey(poweredOn:state != "attrib_off",pairs:pairs)
    }
    // The saved pair while it's still paired; otherwise the only pair, or the only connected one.
    static func choose(_ survey:Survey?,saved:String?)->Choice {
        guard let survey else{return .unreadable}
        guard survey.poweredOn else{return .bluetoothOff}
        if let saved=saved.map(normalized),let pair=survey.pairs.first(where:{$0.address==saved}){return .chosen(pair)}
        if survey.pairs.count==1{return .chosen(survey.pairs[0])}
        let connected=survey.pairs.filter(\.connected)
        if connected.count==1{return .chosen(connected[0])}
        return survey.pairs.isEmpty ? .missing:.several
    }
    static var saved:String?{(try? String(contentsOf:targetURL,encoding:.utf8)).map(normalized)}
    // The same bytes an earlier build packaged, so saved calibrations keep matching.
    static func save(_ pair:ClosedCaseAirPods) throws {
        guard saved != pair.address else{return}
        try FileManager.default.createDirectory(at:targetURL.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data(pair.address.utf8).write(to:targetURL,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:targetURL.path)
    }
    // Asks the system on a utility queue and answers on the main one; nil when it couldn't be read.
    static func survey(completion:@escaping(Survey?)->Void) {
        DispatchQueue.global(qos:.userInitiated).async{
            let result=toolOutput("/usr/sbin/system_profiler",["SPBluetoothDataType","-json"],timeout:20).flatMap{parse($0)}
            DispatchQueue.main.async{completion(result)}
        }
    }
    // A system tool's output, or nil if it fails or outlasts the timeout, so a hung tool can't leave Connect waiting.
    static func toolOutput(_ path:String,_ arguments:[String],timeout:TimeInterval)->Data? {
        let process=Process(),output=Pipe()
        process.executableURL=URL(fileURLWithPath:path);process.arguments=arguments
        process.standardOutput=output;process.standardError=FileHandle.nullDevice
        guard (try? process.run()) != nil else{return nil}
        var data=Data();let finished=DispatchSemaphore(value:0)
        DispatchQueue.global(qos:.userInitiated).async{
            data=output.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit();finished.signal()
        }
        guard finished.wait(timeout:.now()+timeout) == .success else{
            if process.isRunning{process.terminate()}
            return nil
        }
        return process.terminationStatus==0 ? data:nil
    }
    static let bluetoothDenied="AirPointer 需要蓝牙权限才能连接 AirPods。请在「系统设置 → 隐私与安全性 → 蓝牙」中允许，然后重新连接。"
    // ClosedCaseRestore's exit codes, in plain words.
    static func restoreFailure(_ status:Int32)->String {
        switch status {
        case 3:return "AirPods 没有响应。请打开盖子，取出并重新放回一只耳机，再重新连接。"
        case 4:return bluetoothDenied
        case 5:return "这台 Mac 已经不再配对这副 AirPods。请在「系统设置 → 蓝牙」中重新配对，然后重新连接。"
        case 6:return Choice.bluetoothOff.failure!
        default:return "AirPointer 无法发起与 AirPods 的连接。请重新连接。"
        }
    }
    // Exits that mean the AirPods went quiet, not that anything here failed. They're usually asleep, and opening the lid wakes them.
    static func lostContact(_ status:Int32?)->Bool{status.map{[35,40,42,43,44].contains($0)} ?? false}
    // ClosedCaseMotion's exit codes (the table atop CaseSustainedRenewal.m), or nil for a crash.
    // Nil back means nothing to tell: a requested stop, or a case that finishes its own cleanup.
    static func helperFailure(_ status:Int32?,stopping:Bool)->String? {
        let reopen="打开盖子，取出一只耳机再放回去，然后重新连接。"
        switch status {
        case 0,46:return nil
        case 2:return "AirPointer 无法启动动作数据助手。请退出并重新打开 AirPointer，然后重新连接。"
        case 3:return "连接意外中断。请重新连接，然后打开盖子。"
        case 10,11:return "AirPointer 无法保存会话文件。请清理一些磁盘空间，然后重新连接。"
        case 12:return "AirPointer 丢失了要用哪副 AirPods 的记录。请重新连接。"
        case 20:return bluetoothDenied
        case 21:return "蓝牙尚未就绪。请打开蓝牙，等几秒钟，然后重新连接。"
        case 22:return restoreFailure(5)
        case 23:return "AirPods 未连接。请打开盖子，在蓝牙菜单中选择它们，然后重新连接。"
        case 24:return "这个版本的 macOS 改动了 AirPointer 依赖的蓝牙功能。在 AirPointer 更新之前，合盖指向功能无法使用。"
        case 25:return "其他 App 正在占用 AirPods 的控制连接。请退出其他 AirPods 工具，然后重新连接。"
        case 26:return "AirPods 没有重新连接。"+reopen
        case 27:return "AirPods 已重连，但没有建立动作数据连接。"+reopen
        case 28:return "AirPods 没有响应。"+reopen
        // Also what AirPods connected to an iPhone at the same time do: they answer the setup, then send nothing.
        case 30:return "没有收到 AirPods 的动作数据。如果它们同时连着 iPhone，请把手机关掉蓝牙。两只 AirPods 都留在打开的充电盒里，然后重新连接。"
        case 31:return "AirPods 没有报告自己的型号。"+reopen
        case 32:return "这副耳机没有报告为 AirPods Pro。合盖指向功能需要 AirPods Pro。"
        case 34:return "充电盒没有报告为 AirPods 充电盒。请使用与这副 AirPods 配套的充电盒，然后重新连接。"
        case 35:return "充电盒停止响应了。请重新连接，然后打开盖子。"
        case 36:return "充电盒拒绝了 AirPointer 的请求。请打开盖子，等几秒钟，然后重新连接。"
        case 40:return "AirPods 不再响应。请重新连接，然后打开盖子。"
        case 41:return "AirPods 发来了意外的数据，AirPointer 为安全起见已停止。请重新连接，然后打开盖子。"
        case 42:return "AirPointer 无法向 AirPods 发送数据。请重新连接，然后打开盖子。如果反复出现，请关掉蓝牙再打开。"
        case 43:return "AirPods 的动作数据中断了。请重新连接，然后打开盖子。"
        case 44:return "与 AirPods 的连接已结束。请重新连接，然后打开盖子。"
        case 45:return "指针已停止，但 AirPods 可能仍在发送动作数据。请关掉蓝牙再打开，把它们复位。"
        case 50:return stopping ? nil:"AirPointer 停止响应，AirPods 连接已关闭。请在「指向」页重新连接。"
        case 51:return stopping ? nil:"AirPointer 停止读取动作数据，AirPods 连接已关闭。请在「指向」页重新连接。"
        case 52:return stopping ? nil:"AirPointer 被停止时，AirPods 连接已关闭。请在「指向」页重新连接。"
        case 53:return "AirPointer 不得不强制关闭 AirPods 连接。如果指针或 AirPods 表现异常，请关掉蓝牙再打开，然后重新连接。"
        default:return stopping ? nil:"AirPods 连接意外中断。请重新连接，然后打开盖子。"
        }
    }
}

// Asks for Bluetooth at Connect, so the system prompt appears when it makes sense.
final class ClosedCaseBluetoothAccess:NSObject,CBCentralManagerDelegate {
    private var manager:CBCentralManager?,waiting:[(Bool)->Void]=[]
    static let settings=URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")
    func request(_ completion:@escaping(Bool)->Void) {
        switch CBManager.authorization {
        case .allowedAlways:completion(true)
        case .notDetermined:
            waiting.append(completion)
            if manager==nil{manager=CBCentralManager(delegate:self,queue:.main)}
        default:completion(false)
        }
    }
    func centralManagerDidUpdateState(_ central:CBCentralManager) {
        guard CBManager.authorization != .notDetermined else{return}
        let allowed=CBManager.authorization == .allowedAlways,answers=waiting
        waiting=[];manager=nil
        for answer in answers{answer(allowed)}
    }
}

// Apple's proximity-pairing broadcast as macOS hands it over (company ID first): 4C 00, type 07, length
// 19, prefix 01, the product ID little-endian, status, batteries, charge, then the lid byte, whose bit 3
// is set while the lid is closed. That byte is current only while an earbud reports being in the case
// (status bit 6 or bit 2). Nil for any other broadcast. The rest, an address fragment among it, is never read.
func closedCaseLidOpen(_ bytes:[UInt8],productID:UInt16)->Bool?{
    guard bytes.count==29,bytes[0]==0x4C,bytes[1]==0,bytes[2]==7,bytes[3]==0x19,bytes[4]==1,
          bytes[5]==UInt8(productID & 0xFF),bytes[6]==UInt8(productID>>8),bytes[7] & 0x44 != 0 else{return nil}
    return bytes[10] & 0x08==0
}

// After Connect with the lid shut, waits for it to open by listening for the AirPods' own broadcast, the
// one that shows the battery card on an iPhone. Only AirPods paired with this Mac carry a name. It runs
// only while Connect waits, so opening the case in everyday use does nothing.
final class ClosedCaseLidWatcher:NSObject,CBCentralManagerDelegate {
    private var manager:CBCentralManager?,opened:(()->Void)?,ended=false
    private let productID:UInt16
    private var lastOpen:[UUID:Double]=[:]
    init(productID:UInt16,opened:@escaping()->Void){self.productID=productID;self.opened=opened}
    func start(){manager=CBCentralManager(delegate:self,queue:.main)}
    func stop(){
        guard !ended else{return};ended=true
        manager?.stopScan();manager?.delegate=nil;manager=nil;opened=nil
    }
    func centralManagerDidUpdateState(_ central:CBCentralManager){
        if central.state == .poweredOn{central.scanForPeripherals(withServices:nil,options:[CBCentralManagerScanOptionAllowDuplicatesKey:true])}
    }
    func centralManager(_ central:CBCentralManager,didDiscover peripheral:CBPeripheral,advertisementData:[String:Any],rssi:NSNumber){
        guard let data=advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data else{return}
        let bytes=[UInt8](data)
        guard let open=closedCaseLidOpen(bytes,productID:productID) else{return}
        let now=ProcessInfo.processInfo.systemUptime,named=peripheral.name != nil
        guard named,open else{lastOpen[peripheral.identifier]=nil;return}
        // Two open frames within two seconds, so one stray frame can't start a connection.
        if let previous=lastOpen[peripheral.identifier],now-previous<=2{let fire=opened;opened=nil;fire?();return}
        lastOpen[peripheral.identifier]=now
    }
}
