//
//  ALTAnisetteData.swift
//  AltSign
//

import Foundation


public final class ALTAnisetteData: NSObject, NSCopying, NSSecureCoding {

    // MARK: Properties

    public var machineID: String
    public var oneTimePassword: String
    public var localUserID: String
    public var routingInfo: UInt64

    public var deviceUniqueIdentifier: String
    public var deviceSerialNumber: String
    public var deviceDescription: String

    public var date: Date
    public var locale: Locale
    public var timeZone: TimeZone

    // MARK: Init

    @objc
    public init(
        machineID: String,
        oneTimePassword: String,
        localUserID: String,
        routingInfo: UInt64,
        deviceUniqueIdentifier: String,
        deviceSerialNumber: String,
        deviceDescription: String,
        date: Date,
        locale: Locale,
        timeZone: TimeZone
    ) {
        self.machineID = machineID
        self.oneTimePassword = oneTimePassword
        self.localUserID = localUserID
        self.routingInfo = routingInfo
        self.deviceUniqueIdentifier = deviceUniqueIdentifier
        self.deviceSerialNumber = deviceSerialNumber
        self.deviceDescription = deviceDescription
        self.date = date
        self.locale = locale
        self.timeZone = timeZone
        super.init()
    }

    // MARK: Description

    public override var description: String {
        """
        Machine ID: \(machineID)
        One-Time Password: \(oneTimePassword)
        Local User ID: \(localUserID)
        Routing Info: \(routingInfo)
        Device UDID: \(deviceUniqueIdentifier)
        Device Serial Number: \(deviceSerialNumber)
        Device Description: \(deviceDescription)
        Date: \(date)
        Locale: \(locale.identifier)
        Time Zone: \(timeZone)
        """
    }

    // MARK: Equality

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? ALTAnisetteData else { return false }

        return machineID == other.machineID &&
        oneTimePassword == other.oneTimePassword &&
        localUserID == other.localUserID &&
        routingInfo == other.routingInfo &&
        deviceUniqueIdentifier == other.deviceUniqueIdentifier &&
        deviceSerialNumber == other.deviceSerialNumber &&
        deviceDescription == other.deviceDescription &&
        date == other.date &&
        locale == other.locale &&
        timeZone == other.timeZone
    }

    public override var hash: Int {
        machineID.hashValue ^
        oneTimePassword.hashValue ^
        localUserID.hashValue ^
        routingInfo.hashValue ^
        deviceUniqueIdentifier.hashValue ^
        deviceSerialNumber.hashValue ^
        deviceDescription.hashValue ^
        date.hashValue ^
        locale.hashValue ^
        timeZone.hashValue
    }

    // MARK: NSCopying

    public func copy(with zone: NSZone? = nil) -> Any {
        ALTAnisetteData(
            machineID: machineID,
            oneTimePassword: oneTimePassword,
            localUserID: localUserID,
            routingInfo: routingInfo,
            deviceUniqueIdentifier: deviceUniqueIdentifier,
            deviceSerialNumber: deviceSerialNumber,
            deviceDescription: deviceDescription,
            date: date,
            locale: locale,
            timeZone: timeZone
        )
    }

    // MARK: NSSecureCoding

    public static var supportsSecureCoding: Bool { true }

    public required convenience init?(coder: NSCoder) {

        guard
            let machineID = coder.decodeObject(of: NSString.self, forKey: "machineID") as String?,
            let otp = coder.decodeObject(of: NSString.self, forKey: "oneTimePassword") as String?,
            let localUserID = coder.decodeObject(of: NSString.self, forKey: "localUserID") as String?,
            let routingInfo = coder.decodeObject(of: NSNumber.self, forKey: "routingInfo"),
            let deviceUID = coder.decodeObject(of: NSString.self, forKey: "deviceUniqueIdentifier") as String?,
            let serial = coder.decodeObject(of: NSString.self, forKey: "deviceSerialNumber") as String?,
            let desc = coder.decodeObject(of: NSString.self, forKey: "deviceDescription") as String?,
            let date = coder.decodeObject(of: NSDate.self, forKey: "date") as Date?,
            let locale = coder.decodeObject(of: NSLocale.self, forKey: "locale") as Locale?,
            let tz = coder.decodeObject(of: NSTimeZone.self, forKey: "timeZone") as TimeZone?
        else {
            return nil
        }

        self.init(
            machineID: machineID,
            oneTimePassword: otp,
            localUserID: localUserID,
            routingInfo: routingInfo.uint64Value,
            deviceUniqueIdentifier: deviceUID,
            deviceSerialNumber: serial,
            deviceDescription: desc,
            date: date,
            locale: locale,
            timeZone: tz
        )
    }

    public func encode(with coder: NSCoder) {
        coder.encode(machineID, forKey: "machineID")
        coder.encode(oneTimePassword, forKey: "oneTimePassword")
        coder.encode(localUserID, forKey: "localUserID")
        coder.encode(NSNumber(value: routingInfo), forKey: "routingInfo")

        coder.encode(deviceUniqueIdentifier, forKey: "deviceUniqueIdentifier")
        coder.encode(deviceSerialNumber, forKey: "deviceSerialNumber")
        coder.encode(deviceDescription, forKey: "deviceDescription")

        coder.encode(date, forKey: "date")
        coder.encode(locale, forKey: "locale")
        coder.encode(timeZone, forKey: "timeZone")
    }

    // MARK: JSON

    @objc
    public convenience init?(json: [String: String]) {

        guard
            let machineID = json["machineID"],
            let otp = json["oneTimePassword"],
            let localUserID = json["localUserID"],
            let routingInfoString = json["routingInfo"],
            let deviceUID = json["deviceUniqueIdentifier"],
            let serial = json["deviceSerialNumber"],
            let desc = json["deviceDescription"],
            let dateString = json["date"],
            let localeID = json["locale"],
            let tzID = json["timeZone"]
        else { return nil }

        let formatter = ISO8601DateFormatter()

        guard let date = formatter.date(from: dateString) else {
            return nil
        }

        let cleanLocaleID = localeID.components(separatedBy: "@").first ?? localeID
        let locale = Locale(identifier: cleanLocaleID)
        let tz =
            TimeZone(abbreviation: tzID)
            ?? .current

        self.init(
            machineID: machineID,
            oneTimePassword: otp,
            localUserID: localUserID,
            routingInfo: UInt64(routingInfoString) ?? 0,
            deviceUniqueIdentifier: deviceUID,
            deviceSerialNumber: serial,
            deviceDescription: desc,
            date: date,
            locale: locale,
            timeZone: tz
        )
    }

    @objc
    public func json() -> [String: String] {

        let formatter = ISO8601DateFormatter()

        return [
            "machineID": machineID,
            "oneTimePassword": oneTimePassword,
            "localUserID": localUserID,
            "routingInfo": String(routingInfo),
            "deviceUniqueIdentifier": deviceUniqueIdentifier,
            "deviceSerialNumber": deviceSerialNumber,
            "deviceDescription": deviceDescription,
            "date": formatter.string(from: date),
            "locale": locale.sanitizedIdentifier,
            "timeZone":
                timeZone.abbreviation() ??
                TimeZone.current.abbreviation() ??
                "PST"
        ]
    }
}

extension Locale {
    var sanitizedIdentifier: String {
        identifier.components(separatedBy: "@").first ?? "en_US"
    }
}
