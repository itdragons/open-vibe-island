@preconcurrency import CoreBluetooth
import Foundation
import Observation
import OpenIslandCore

enum SignalLightConnectionStatus: Equatable {
    case unauthorized
    case poweredOff
    case disconnected
    case scanning
    case connecting
    case connected(name: String)
}

struct SignalLightDiscoveredDevice: Identifiable, Equatable {
    let id: UUID
    let name: String
}

/// Owns the BLE connection to a single paired signal-light device: scanning,
/// connecting, disconnecting, auto-reconnecting after drops, and sending
/// effect commands. Talks directly to the peripheral defined in
/// `signal-light/led_esp32c3/led_esp32c3.ino` / `signal-light/led_esp32c3/config.h`.
@MainActor
@Observable
final class SignalLightCoordinator: NSObject {
    private static let serviceUUID = CBUUID(string: "77697364-6f6d-6761-7264-656e00000001")
    private static let commandCharacteristicUUID = CBUUID(string: "77697364-6f6d-6761-7264-656e00000002")
    private static let otaControlCharacteristicUUID = CBUUID(string: "77697364-6f6d-6761-7264-656e00000003")
    private static let otaDataCharacteristicUUID = CBUUID(string: "77697364-6f6d-6761-7264-656e00000004")
    private static let infoCharacteristicUUID = CBUUID(string: "77697364-6f6d-6761-7264-656e00000005")
    private static let pairedPeripheralIDDefaultsKey = "signalLight.pairedPeripheralID"

    private(set) var status: SignalLightConnectionStatus = .disconnected
    private(set) var discoveredDevices: [SignalLightDiscoveredDevice] = []
    private(set) var firmwareVersion: String?
    let firmwareUpdater = SignalLightFirmwareUpdater()

    /// Supplies the effect that should currently be showing. Called right
    /// after a (re)connection completes so the light can resync to current
    /// reality instead of being left on whatever it displayed before a drop.
    var currentEffectProvider: (() -> SignalLightEffect?)?

    @ObservationIgnored private var centralManager: CBCentralManager?
    @ObservationIgnored private var connectedPeripheral: CBPeripheral?
    @ObservationIgnored private var commandCharacteristic: CBCharacteristic?
    @ObservationIgnored private var otaControlCharacteristic: CBCharacteristic?
    @ObservationIgnored private var otaDataCharacteristic: CBCharacteristic?
    @ObservationIgnored private var discoveredPeripherals: [UUID: CBPeripheral] = [:]

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    func startScan() {
        guard let centralManager, centralManager.state == .poweredOn else {
            return
        }
        discoveredDevices = []
        discoveredPeripherals = [:]
        status = .scanning
        centralManager.scanForPeripherals(withServices: [Self.serviceUUID])
    }

    func stopScan() {
        centralManager?.stopScan()
        if status == .scanning {
            status = .disconnected
        }
    }

    func connect(deviceID: UUID) {
        guard let centralManager, let peripheral = discoveredPeripherals[deviceID] else {
            return
        }
        stopScan()
        status = .connecting
        connectedPeripheral = peripheral
        centralManager.connect(peripheral)
    }

    func disconnect() {
        UserDefaults.standard.removeObject(forKey: Self.pairedPeripheralIDDefaultsKey)
        guard let centralManager, let peripheral = connectedPeripheral else {
            return
        }
        centralManager.cancelPeripheralConnection(peripheral)
    }

    func send(_ effect: SignalLightEffect) {
        guard let peripheral = connectedPeripheral,
              let characteristic = commandCharacteristic,
              peripheral.state == .connected else {
            return
        }
        let command = SignalLightCommandEncoder.encode(effect)
        peripheral.writeValue(Data(command.utf8), for: characteristic, type: .withResponse)
    }

    func beginFirmwareUpdate(fileURL: URL) {
        guard let peripheral = connectedPeripheral,
              let otaControlCharacteristic,
              let otaDataCharacteristic,
              peripheral.state == .connected else {
            firmwareUpdater.failImmediately(SignalLightFirmwareUpdateError.notReady.errorDescription ?? "Not connected")
            return
        }
        firmwareUpdater.beginUpdate(
            fileURL: fileURL,
            peripheral: peripheral,
            otaControlCharacteristic: otaControlCharacteristic,
            otaDataCharacteristic: otaDataCharacteristic
        )
    }

    func cancelFirmwareUpdate() {
        firmwareUpdater.cancel()
    }

    private func attemptAutoReconnect() {
        guard let centralManager,
              let idString = UserDefaults.standard.string(forKey: Self.pairedPeripheralIDDefaultsKey),
              let id = UUID(uuidString: idString),
              let peripheral = centralManager.retrievePeripherals(withIdentifiers: [id]).first else {
            return
        }
        status = .connecting
        connectedPeripheral = peripheral
        centralManager.connect(peripheral)
    }
}

extension SignalLightCoordinator: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn:
                attemptAutoReconnect()
            case .unauthorized:
                status = .unauthorized
            case .poweredOff:
                status = .poweredOff
            default:
                break
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        MainActor.assumeIsolated {
            discoveredPeripherals[peripheral.identifier] = peripheral
            guard !discoveredDevices.contains(where: { $0.id == peripheral.identifier }) else {
                return
            }
            discoveredDevices.append(
                SignalLightDiscoveredDevice(id: peripheral.identifier, name: peripheral.name ?? "Signal Light")
            )
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.pairedPeripheralIDDefaultsKey)
            peripheral.delegate = self
            peripheral.discoverServices([Self.serviceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        MainActor.assumeIsolated {
            connectedPeripheral = nil
            status = .disconnected
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        MainActor.assumeIsolated {
            connectedPeripheral = nil
            commandCharacteristic = nil
            otaControlCharacteristic = nil
            otaDataCharacteristic = nil
            firmwareVersion = nil
            firmwareUpdater.handleUnexpectedDisconnect()
            status = .disconnected
            attemptAutoReconnect()
        }
    }
}

extension SignalLightCoordinator: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        MainActor.assumeIsolated {
            guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
                return
            }
            peripheral.discoverCharacteristics(
                [Self.commandCharacteristicUUID, Self.otaControlCharacteristicUUID, Self.otaDataCharacteristicUUID, Self.infoCharacteristicUUID],
                for: service
            )
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        MainActor.assumeIsolated {
            guard let characteristics = service.characteristics else {
                return
            }

            for characteristic in characteristics {
                switch characteristic.uuid {
                case Self.commandCharacteristicUUID:
                    commandCharacteristic = characteristic
                case Self.otaControlCharacteristicUUID:
                    otaControlCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                case Self.otaDataCharacteristicUUID:
                    otaDataCharacteristic = characteristic
                case Self.infoCharacteristicUUID:
                    peripheral.readValue(for: characteristic)
                default:
                    break
                }
            }

            guard commandCharacteristic != nil else {
                return
            }
            status = .connected(name: peripheral.name ?? "Signal Light")
            firmwareUpdater.acknowledgeSuccess()
            if let effect = currentEffectProvider?() {
                send(effect)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        MainActor.assumeIsolated {
            firmwareUpdater.handleWriteResponse(for: characteristic, error: error)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        MainActor.assumeIsolated {
            guard error == nil, let value = characteristic.value, let text = String(data: value, encoding: .utf8) else {
                return
            }

            if characteristic.uuid == Self.infoCharacteristicUUID {
                firmwareVersion = text
            } else if characteristic.uuid == Self.otaControlCharacteristicUUID {
                firmwareUpdater.handleControlStatusUpdate(text)
            }
        }
    }
}
