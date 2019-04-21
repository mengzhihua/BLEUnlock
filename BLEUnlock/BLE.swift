import Foundation
import CoreBluetooth

class Device: NSObject {
    let uuid : UUID!
    var peripheral : CBPeripheral?
    var manufacture : String?
    var model : String?
    var rssi: Int = 0
    var scanTimer: Timer?
    
    override var description: String {
        get {
            if let name = peripheral?.name {
                return name
            }
            if let manu = manufacture {
                if let mod = model {
                    if manu == "Apple Inc." && appleDeviceNames[mod] != nil {
                        return appleDeviceNames[mod]!
                    }
                    return String(format: "%@/%@", manu, mod)
                } else {
                    return manu
                }
            } else {
                if let mod = model {
                    return mod
                }
            }
            return uuid.description
        }
    }
    
    init(uuid _uuid: UUID) {
        uuid = _uuid
    }
}

let DeviceInformation = CBUUID(string:"180A")
let ManufacturerName = CBUUID(string:"2A29")
let ModelName = CBUUID(string:"2A24")

protocol BLEDelegate {
    func newDevice(device: Device)
    func updateDevice(device: Device)
    func removeDevice(device: Device)
    func updateRSSI(rssi: Int?)
    func updatePresence(presence: Bool)
}

class BLE: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var centralMgr : CBCentralManager!
    var devices : [UUID : Device] = [:]
    var delegate: BLEDelegate?
    var scanMode = false
    var monitorUUID: UUID?
    var signalTimer: Timer?
    var lastStableTime = Date().timeIntervalSince1970
    var presence = false
    var proximityRSSI = -70
    var proximityDelay = 3.0
    var signalTimeout = 20.0
    
    func startScanning() {
        scanMode = true
        for device in devices.values {
            resetScanTimer(device: device)
        }
    }
    
    func stopScanning() {
        scanMode = false
        for device in devices.values {
            device.scanTimer?.invalidate()
        }
    }
    
    func startMonitor(uuid: UUID) {
        monitorUUID = uuid
        lastStableTime = Date().timeIntervalSince1970
        resetSignalTimer()
        presence = false
    }
    
    func resetSignalTimer() {
        signalTimer?.invalidate()
        signalTimer = Timer.scheduledTimer(withTimeInterval: signalTimeout, repeats: false, block: { _ in
            print("Signal timer expired")
            self.delegate?.updateRSSI(rssi: nil)
            if self.presence {
                self.presence = false
                self.delegate?.updatePresence(presence: self.presence)
            }
        })
        if let timer = signalTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            centralMgr.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
    }
    
    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber)
    {
        let rssi = RSSI.intValue > 0 ? 0 : RSSI.intValue
        if let uuid = monitorUUID {
            if peripheral.identifier == uuid {
                delegate?.updateRSSI(rssi: rssi)
                let now = Date().timeIntervalSince1970
                if (rssi > proximityRSSI && presence) || (rssi <= proximityRSSI && !presence) {
                    lastStableTime = now
                } else {
                    print("Proximity changing")
                    if now - lastStableTime > proximityDelay {
                        print("Change presence")
                        presence = !presence
                        delegate?.updatePresence(presence: presence)
                        lastStableTime = now
                    }
                }
                resetSignalTimer()
            }
        }
        if (scanMode) {
            let dev = devices[peripheral.identifier]
            var device: Device
            if (dev == nil) {
                device = Device(uuid: peripheral.identifier)
                device.peripheral = peripheral
                device.rssi = rssi
                devices[peripheral.identifier] = device
                central.connect(peripheral, options: nil)
                delegate?.newDevice(device: device)
            } else {
                device = dev!
                device.rssi = rssi
                delegate?.updateDevice(device: device)
            }
            resetScanTimer(device: device)
        }
    }
    
    func resetScanTimer(device: Device) {
        device.scanTimer?.invalidate()
        device.scanTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false, block: { _ in
            print("\(String(describing: device.uuid)) timeout")
            self.delegate?.removeDevice(device: device)
            if let p = device.peripheral {
                self.centralMgr.cancelPeripheralConnection(p)
            }
            self.devices.removeValue(forKey: device.uuid)
        })
        if let timer = device.scanTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    
    func centralManager(_ central: CBCentralManager,
                        didConnect peripheral: CBPeripheral)
    {
        peripheral.delegate = self
        peripheral.discoverServices([DeviceInformation])
    }
    
    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverServices error: Error?) {
        if let services = peripheral.services {
            for service in services {
                if service.uuid == DeviceInformation {
                    peripheral.discoverCharacteristics([ManufacturerName, ModelName], for: service)
                }
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?)
    {
        if let chars = service.characteristics {
            for chara in chars {
                if chara.uuid == ManufacturerName || chara.uuid == ModelName {
                    peripheral.readValue(for:chara)
                }
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?)
    {
        if let value = characteristic.value {
            let str: String? = String(data: value, encoding: .utf8)
            if let s = str {
                if let device = devices[peripheral.identifier] {
                    if characteristic.uuid == ManufacturerName {
                        device.manufacture = s
                        delegate?.updateDevice(device: device)
                    }
                    if characteristic.uuid == ModelName {
                        device.model = s
                        delegate?.updateDevice(device: device)
                    }
                    if device.model != nil && device.model != nil {
                        centralMgr.cancelPeripheralConnection(peripheral)
                    }
                }
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral,
                    didModifyServices invalidatedServices: [CBService])
    {
        peripheral.discoverServices(nil)
    }
    
    override init() {
        super.init()
        centralMgr = CBCentralManager(delegate: self, queue: nil)
    }
}