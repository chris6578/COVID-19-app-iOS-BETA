//
//  Persistence.swift
//  Sonar
//
//  Created by NHSX on 18.03.20.
//  Copyright © 2020 NHSX. All rights reserved.
//

import Foundation
import Logging

struct Registration: Equatable {
    let id: UUID
    // TODO: This should be wrapped in a "HMACKey" value type!
    let secretKey: Data // HMAC for HTTP headers and bluetooth payload
    let broadcastRotationKey: SecKey

    init(id: UUID, secretKey: Data, broadcastRotationKey: SecKey) {
        self.id = id
        self.secretKey = secretKey
        self.broadcastRotationKey = broadcastRotationKey
    }
}

protocol Persisting {
    var delegate: PersistenceDelegate? { get nonmutating set }

    var registration: Registration? { get nonmutating set }
    var potentiallyExposed: Date? { get nonmutating set }
    var selfDiagnosis: SelfDiagnosis? { get nonmutating set }
    var partialPostcode: String? { get nonmutating set }
    var bluetoothPermissionRequested: Bool { get nonmutating set }
    var uploadLog: [UploadLog] { get nonmutating set }
    var linkingId: LinkingId? { get nonmutating set }
    var lastInstalledVersion: String? { get nonmutating set }
    var lastInstalledBuildNumber: String? { get nonmutating set }
    var acknowledgmentUrls: Set<URL> { get nonmutating set }

    func clear()
}

protocol PersistenceDelegate: class {
    func persistence(_ persistence: Persisting, didUpdateRegistration registration: Registration)
}

class Persistence: Persisting {

    enum Keys: String, CaseIterable {
        case potentiallyExposed
        case selfDiagnosis
        case partialPostcode
        case bluetoothPermissionRequested
        case uploadLog
        case linkingId
        case lastInstalledBuildNumber
        case lastInstalledVersion
        case acknowledgmentUrls
    }
    
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let secureRegistrationStorage: SecureRegistrationStorage
    private let broadcastKeyStorage: BroadcastRotationKeyStorage
    private let monitor: AppMonitoring

    weak var delegate: PersistenceDelegate?
    
    init(
        secureRegistrationStorage: SecureRegistrationStorage,
        broadcastKeyStorage: BroadcastRotationKeyStorage,
        monitor: AppMonitoring,
        storageChecker: StorageChecking
    ) {
        self.secureRegistrationStorage = secureRegistrationStorage
        self.broadcastKeyStorage = broadcastKeyStorage
        self.monitor = monitor
        
        let storageState = storageChecker.state
        if storageState == .keyChainAndUserDefaultsOutOfSync {
            clear()
        }
        
        if storageState != .inSync {
            storageChecker.markAsSynced()
        }
    }

    var registration: Registration? {
        get {
            guard let partial = secureRegistrationStorage.get() else { return nil }
            guard let broadcastRotationKey = broadcastKeyStorage.read() else {
                logger.error("Ignoring the existing registration because there is no broadcast roation key")
                return nil
            }
                        
            return Registration(id: partial.id, secretKey: partial.secretKey, broadcastRotationKey: broadcastRotationKey)
        }
        
        set {
            guard let registration = newValue else {
                try! secureRegistrationStorage.clear()
                return
            }

            let partial = PartialRegistration(id: registration.id, secretKey: registration.secretKey)
            try! secureRegistrationStorage.set(registration: partial)
            try! broadcastKeyStorage.save(publicKey: registration.broadcastRotationKey)

            delegate?.persistence(self, didUpdateRegistration: registration)
            monitor.report(.registrationSucceeded)
        }
    }

    var potentiallyExposed: Date? {
        get {
            UserDefaults.standard.object(forKey: Keys.potentiallyExposed.rawValue) as? Date
        }
        set { UserDefaults.standard.set(newValue, forKey: Keys.potentiallyExposed.rawValue) }
    }

    var selfDiagnosis: SelfDiagnosis? {
        get {
            guard
                let data = UserDefaults.standard.data(forKey: Keys.selfDiagnosis.rawValue),
                let decoded = try? decoder.decode(SelfDiagnosis.self, from: data)
            else {
                return nil
            }

            return decoded
        }
        set {
            guard let newValue = newValue else {
                UserDefaults.standard.removeObject(forKey: Keys.selfDiagnosis.rawValue)
                return
            }

            guard let data = try? encoder.encode(newValue) else {
                logger.critical("Unable to encode a self-diagnosis")
                return
            }

            UserDefaults.standard.set(data, forKey: Keys.selfDiagnosis.rawValue)
        }
    }
    
    var partialPostcode: String? {
        get { UserDefaults.standard.string(forKey: Keys.partialPostcode.rawValue) }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.partialPostcode.rawValue)
            if newValue != nil {
                monitor.report(.partialPostcodeProvided)
            }
        }
    }

    var uploadLog: [UploadLog] {
        get {
            guard
                let data = UserDefaults.standard.data(forKey: Keys.uploadLog.rawValue),
                let decoded = try? decoder.decode([UploadLog].self, from: data)
            else {
                return []
            }

            return decoded
        }
        set {
            guard let data = try? encoder.encode(newValue.suffix(100)) else {
                logger.critical("Unable to encode the upload log")
                return
            }

            UserDefaults.standard.set(data, forKey: Keys.uploadLog.rawValue)
        }
    }
    
    var bluetoothPermissionRequested: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.bluetoothPermissionRequested.rawValue) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.bluetoothPermissionRequested.rawValue) }
    }

    var linkingId: LinkingId? {
        get { UserDefaults.standard.string(forKey: Keys.linkingId.rawValue) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.linkingId.rawValue) }
    }
    
    var lastInstalledVersion: String? {
        get { UserDefaults.standard.string(forKey: Keys.lastInstalledVersion.rawValue) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.lastInstalledVersion.rawValue) }
    }

    var lastInstalledBuildNumber: String? {
        get { UserDefaults.standard.string(forKey: Keys.lastInstalledBuildNumber.rawValue) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.lastInstalledBuildNumber.rawValue) }
    }

    var acknowledgmentUrls: Set<URL> {
        get {
            guard
                let data = UserDefaults.standard.data(forKey: Keys.acknowledgmentUrls.rawValue),
                let decoded = try? decoder.decode(Set<URL>.self, from: data)
            else {
                return []
            }

            return decoded
        }
        set {
            guard let data = try? encoder.encode(newValue.suffix(100)) else {
                logger.critical("Unable to encode the upload log")
                return
            }

            UserDefaults.standard.set(data, forKey: Keys.acknowledgmentUrls.rawValue)
        }
    }
    
    func clear() {
        for key in Keys.allCases {
            UserDefaults.standard.removeObject(forKey: key.rawValue)
        }

        try! secureRegistrationStorage.clear()
        try! broadcastKeyStorage.clear()
    }

}


fileprivate let logger = Logger(label: "Persistence")
