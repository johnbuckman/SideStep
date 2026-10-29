//
//  ALTAppleAPI+Operations.swift
//  AltSign
//
//  Created by Magesh K on 2026-06-28.
//

import Foundation
import SwiftBridge

public extension ALTAppleAPI {
    
    static var shared: ALTAppleAPI {
        return sharedAPI
    }
    
    /* Teams */
    func processResponse(
        _ responseDictionary: [String: Any],
        parseHandler: (() -> Any?)?,
        resultCodeHandler: ((Int) -> Error?)?
    ) throws -> Any? {
        var error: Error? = nil
        let result = self.processResponse(responseDictionary, parseHandler: parseHandler, resultCodeHandler: resultCodeHandler, error: &error)
        if let error {
            throw error
        }
        return result
    }
    
    func fetchTeams(for account: ALTAccount, session: ALTAppleAPISession, completionHandler: @escaping ([ALTTeam]?, Error?) -> Void) {
        verboseLog("[AltSign] fetchTeams starting for account: \(account.appleID)")
        let url = URL(string: "listTeams.action", relativeTo: self.baseURL)!
        
        self.sendRequest(url: url, additionalParameters: nil, session: session, team: nil) { responseDictionary, requestError in
            if let error = requestError {
                verboseLog("[AltSign] fetchTeams request failed with error: \(error)")
            }
            guard let responseDictionary else {
                completionHandler(nil, requestError)
                return
            }
            
            var error: Error? = nil
            let teams = self.processResponse(responseDictionary, parseHandler: {
                guard let array = responseDictionary["teams"] as? [[String: Any]] else { return nil }
                var list = [ALTTeam]()
                for dict in array {
                    guard let team = ALTTeam(account: account, responseDictionary: dict) else { return nil }
                    list.append(team)
                }
                return list
            }, resultCodeHandler: nil, error: &error) as? [ALTTeam]
            
            verboseLog("[AltSign] fetchTeams completed: \(teams?.map { "\($0.name) (\($0.identifier))" } ?? [])")
            if let teams, teams.isEmpty {
                completionHandler(nil, NSError(domain: ALTAppleAPIErrorDomain, code: ALTAppleAPIError.noTeams.rawValue, userInfo: nil))
            } else {
                completionHandler(teams, error)
            }
        }
    }
    
    /* Devices */
    func fetchDevices(for team: ALTTeam, types: ALTDeviceType, session: ALTAppleAPISession, completionHandler: @escaping ([ALTDevice]?, Error?) -> Void) {
        verboseLog("[AltSign] fetchDevices starting for team: \(team.name), types: \(types)")
        let url = URL(string: "ios/listDevices.action", relativeTo: self.baseURL)!
        
        self.sendRequest(url: url, additionalParameters: nil, session: session, team: team) { responseDictionary, requestError in
            if let error = requestError {
                verboseLog("[AltSign] fetchDevices request failed with error: \(error)")
            }
            guard let responseDictionary else {
                completionHandler(nil, requestError)
                return
            }
            
            var error: Error? = nil
            let devices = self.processResponse(responseDictionary, parseHandler: {
                guard let array = responseDictionary["devices"] as? [[String: Any]] else { return nil }
                var list = [ALTDevice]()
                for dict in array {
                    guard let device = ALTDevice(responseDictionary: dict) else { return nil }
                    if !types.contains(device.type) {
                        continue
                    }
                    list.append(device)
                }
                return list
            }, resultCodeHandler: nil, error: &error) as? [ALTDevice]
            
            verboseLog("[AltSign] fetchDevices completed: \(devices?.map { "\($0.name) (\($0.identifier))" } ?? [])")
            completionHandler(devices, error)
        }
    }
    
    func registerDevice(name: String, identifier: String, type: ALTDeviceType, team: ALTTeam, session: ALTAppleAPISession, completionHandler: @escaping (ALTDevice?, Error?) -> Void) {
        verboseLog("[AltSign] registerDevice starting with name: \(name), identifier: \(identifier), type: \(type)")
        let url = URL(string: "ios/addDevice.action", relativeTo: self.baseURL)!
        
        var parameters = [
            "deviceNumber": identifier,
            "name": name
        ]
        
        if type.contains(.iphone) || type.contains(.ipad) {
            parameters["DTDK_Platform"] = "ios"
        } else if type.contains(.appleTV) {
            parameters["DTDK_Platform"] = "tvos"
            parameters["subPlatform"] = "tvOS"
        }
        
        self.sendRequest(url: url, additionalParameters: parameters, session: session, team: team) { responseDictionary, requestError in
            if let error = requestError {
                verboseLog("[AltSign] registerDevice request failed with error: \(error)")
            }
            guard let responseDictionary else {
                completionHandler(nil, requestError)
                return
            }
            
            var error: Error? = nil
            let device = self.processResponse(responseDictionary, parseHandler: {
                guard let dict = responseDictionary["device"] as? [String: Any] else { return nil }
                return ALTDevice(responseDictionary: dict)
            }, resultCodeHandler: { resultCode in
                if resultCode == 35 {
                    if let userString = (responseDictionary["userString"] as? String)?.lowercased(), userString.contains("already exists") {
                        return NSError(domain: ALTAppleAPIErrorDomain, code: ALTAppleAPIError.deviceAlreadyRegistered.rawValue, userInfo: nil) as Error
                    } else {
                        return NSError(domain: ALTAppleAPIErrorDomain, code: ALTAppleAPIError.invalidDeviceID.rawValue, userInfo: nil) as Error
                    }
                }
                return nil
            }, error: &error) as? ALTDevice
            
            verboseLog("[AltSign] registerDevice completed: \(device?.name ?? "nil") (error: \(error?.localizedDescription ?? "nil"))")
            completionHandler(device, error)
        }
    }
    
    /* Certificates */
    func fetchCertificates(for team: ALTTeam, session: ALTAppleAPISession, completionHandler: @escaping ([ALTCertificate]?, Error?) -> Void) {
        verboseLog("[AltSign] fetchCertificates starting for team: \(team.name)")
        let url = URL(string: "certificates", relativeTo: self.servicesBaseURL)!
        let request = URLRequest(url: url)
        
        self.sendServicesRequest(request, additionalParameters: ["filter[certificateType]": "IOS_DEVELOPMENT,DEVELOPMENT"], session: session, team: team) { responseDictionary, requestError in
            if let error = requestError {
                verboseLog("[AltSign] fetchCertificates request failed with error: \(error)")
            }
            guard let responseDictionary else {
                completionHandler(nil, requestError)
                return
            }
            
            var error: Error? = nil
            let certificates = self.processResponse(responseDictionary, parseHandler: {
                guard let array = responseDictionary["data"] as? [[String: Any]] else { return nil }
                var list = [ALTCertificate]()
                for dict in array {
                    guard let certificate = ALTCertificate(responseDictionary: dict) else { return nil }
                    list.append(certificate)
                }
                return list
            }, resultCodeHandler: nil, error: &error) as? [ALTCertificate]
            
            verboseLog("[AltSign] fetchCertificates completed: \(certificates?.map { "\($0.name ?? "nil") (\($0.identifier ?? "nil"))" } ?? [])")
            completionHandler(certificates, error)
        }
    }
    
    func addCertificate(machineName: String, to team: ALTTeam, session: ALTAppleAPISession, completionHandler: @escaping (ALTCertificate?, Error?) -> Void) {
        verboseLog("[AltSign] addCertificate starting with machineName: \(machineName)")
        guard let request = ALTCertificateRequest.makeRequest() else {
            completionHandler(nil, NSError(domain: ALTAppleAPIErrorDomain, code: ALTAppleAPIError.invalidCertificateRequest.rawValue, userInfo: nil))
            return
        }
        
        let url = URL(string: "ios/submitDevelopmentCSR.action", relativeTo: self.baseURL)!
        guard let encodedCSR = String(data: request.data, encoding: .utf8) else {
            completionHandler(nil, NSError(domain: ALTAppleAPIErrorDomain, code: ALTAppleAPIError.invalidCertificateRequest.rawValue, userInfo: nil))
            return
        }
        
        let parameters = [
            "csrContent": encodedCSR,
            "machineId": UUID().uuidString.uppercased(),
            "machineName": machineName
        ]
        
        self.sendRequest(url: url, additionalParameters: parameters, session: session, team: team) { responseDictionary, requestError in
            if let error = requestError {
                verboseLog("[AltSign] addCertificate request failed with error: \(error)")
            }
            guard let responseDictionary else {
                completionHandler(nil, requestError)
                return
            }
            
            var error: Error? = nil
            let certificate = self.processResponse(responseDictionary, parseHandler: {
                guard let dict = responseDictionary["certRequest"] as? [String: Any] else { return nil }
                let cert = ALTCertificate(responseDictionary: dict)
                cert?.privateKey = request.privateKey
                return cert
            }, resultCodeHandler: { resultCode in
                if resultCode == 3250 {
                    return NSError(domain: ALTAppleAPIErrorDomain, code: ALTAppleAPIError.invalidCertificateRequest.rawValue, userInfo: nil) as Error
                }
                if resultCode == 7460 {
                    return NSError(domain: ALTAppleAPIErrorDomain, code: ALTAppleAPIError.tooManyCertificates.rawValue, userInfo: nil) as Error
                }
                return nil
            }, error: &error) as? ALTCertificate
            
            verboseLog("[AltSign] addCertificate completed: \(certificate?.name ?? "nil") (error: \(error?.localizedDescription ?? "nil"))")
            completionHandler(certificate, error)
        }
    }
    
    func revoke(_ certificate: ALTCertificate, for team: ALTTeam, session: ALTAppleAPISession, completionHandler: @escaping (Bool, Error?) -> Void) {
        verboseLog("[AltSign] revoke certificate starting for: \(certificate.name ?? "nil") (ID: \(certificate.identifier ?? "nil"))")
        let url = URL(string: "certificates/\(certificate.identifier ?? "nil")", relativeTo: self.servicesBaseURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        
        self.sendServicesRequest(request, additionalParameters: nil, session: session, team: team) { responseDictionary, requestError in
            if let error = requestError {
                verboseLog("[AltSign] revoke certificate request failed with error: \(error)")
            }
            guard let responseDictionary else {
                completionHandler(false, requestError)
                return
            }
            
            var error: Error? = nil
            let result = self.processResponse(responseDictionary, parseHandler: {
                return responseDictionary
            }, resultCodeHandler: { resultCode in
                if resultCode == 7252 {
                    return NSError(domain: ALTAppleAPIErrorDomain, code: ALTAppleAPIError.certificateDoesNotExist.rawValue, userInfo: nil) as Error
                }
                return nil
            }, error: &error)
            
            verboseLog("[AltSign] revoke completed with success: \(result != nil) (error: \(error?.localizedDescription ?? "nil"))")
            completionHandler(result != nil, error)
        }
    }
    
    /* App IDs */
    func fetchAppIDs(for team: ALTTeam, session: ALTAppleAPISession, completionHandler: @escaping ([ALTAppID]?, Error?) -> Void) {
        verboseLog("[AltSign] fetchAppIDs starting for team: \(team.name)")
        let url = URL(string: "ios/listAppIds.action", relativeTo: self.baseURL)!
        
        self.sendRequest(url: url, additionalParameters: nil, session: session, team: team) { responseDictionary, requestError in
            if let error = requestError {
                verboseLog("[AltSign] fetchAppIDs request failed with error: \(error)")
            }
            guard let responseDictionary else {
                completionHandler(nil, requestError)
                return
            }
            
            var error: Error? = nil
            let appIDs = self.processResponse(responseDictionary, parseHandler: {
                guard let array = responseDictionary["appIds"] as? [[String: Any]] else { return nil }
                var list = [ALTAppID]()
                for dict in array {
                    guard let appID = ALTAppID(responseDictionary: dict) else { return nil }
                    list.append(appID)
                }
                return list
            }, resultCodeHandler: nil, error: &error) as? [ALTAppID]
            
            verboseLog("[AltSign] fetchAppIDs completed: \(appIDs?.map { $0.bundleIdentifier } ?? [])")
            completionHandler(appIDs, error)
        }
    }
    
    func addAppID(withName name: String, bundleIdentifier: String, team: ALTTeam, session: ALTAppleAPISession, completionHandler: @escaping (ALTAppID?, Error?) -> Void) {
        verboseLog("[AltSign] addAppID starting with name: \(name), bundleIdentifier: \(bundleIdentifier)")
        let url = URL(string: "ios/addAppId.action", relativeTo: self.baseURL)!
        
        var allowedCharacters = CharacterSet.alphanumerics
        allowedCharacters.formUnion(CharacterSet.whitespaces)
        
        let foldedName = name.folding(options: .diacriticInsensitive, locale: nil)
        var sanitizedName = String(foldedName.unicodeScalars.filter { allowedCharacters.contains($0) })
        if sanitizedName.isEmpty {
            sanitizedName = "App"
        }
        
        let parameters = [
            "identifier": bundleIdentifier,
            "name": sanitizedName
        ]
        
        self.sendRequest(url: url, additionalParameters: parameters, session: session, team: team) { responseDictionary, requestError in
            if let error = requestError {
                verboseLog("[AltSign] addAppID request failed with error: \(error)")
            }
            guard let responseDictionary else {
                completionHandler(nil, requestError)
                return
            }
            
            var error: Error? = nil
            let appID = self.processResponse(responseDictionary, parseHandler: {
                guard let dict = responseDictionary["appId"] as? [String: Any] else { return nil }
                return ALTAppID(responseDictionary: dict)
            }, resultCodeHandler: { resultCode in
                switch resultCode {
                case 35:
                    return NSError(domain: ALTAppleAPIErrorDomain, code: ALTAppleAPIError.invalidAppIDName.rawValue, userInfo: [(ALTAppNameErrorKey as String): sanitizedName]) as Error
                case 9120:
                    return NSError(domain: ALTAppleAPIErrorDomain, code: ALTAppleAPIError.maximumAppIDLimitReached.rawValue, userInfo: nil) as Error
                case 9401:
                    return NSError(domain: ALTAppleAPIErrorDomain, code: ALTAppleAPIError.bundleIdentifierUnavailable.rawValue, userInfo: nil) as Error
                case 9412:
                    return NSError(domain: ALTAppleAPIErrorDomain, code: ALTAppleAPIError.invalidBundleIdentifier.rawValue, userInfo: nil) as Error
                default:
                    return nil
                }
            }, error: &error) as? ALTAppID
            
            verboseLog("[AltSign] addAppID completed: \(appID?.bundleIdentifier ?? "nil") (error: \(error?.localizedDescription ?? "nil"))")
            completionHandler(appID, error)
        }
    }
    
    func update(_ appID: ALTAppID, team: ALTTeam, session: ALTAppleAPISession, completionHandler: @escaping (ALTAppID?, Error?) -> Void) {
        verboseLog("[AltSign] update starting for App ID: \(appID.bundleIdentifier)")
        let url = URL(string: "ios/updateAppId.action", relativeTo: self.baseURL)!
        
        var parameters: [String: Any] = ["appIdId": appID.identifier]
        for (feature, value) in appID.features {
            parameters[feature] = value
        }
        
        var entitlements = appID.entitlements
        if team.type == .free {
            for (entitlement, _) in appID.entitlements {
                if !ALTFreeDeveloperCanUseEntitlement(entitlement) {
                    entitlements.removeValue(forKey: entitlement)
                }
            }
        }
        
        parameters["entitlements"] = entitlements
        
        self.sendRequest(url: url, plistParameters: parameters, session: session, team: team) { responseDictionary, requestError in
            if let error = requestError {
                verboseLog("[AltSign] update App ID request failed with error: \(error)")
            }
            guard let responseDictionary else {
                completionHandler(nil, requestError)
                return
            }
            
            var error: Error? = nil
            let updatedAppID = self.processResponse(responseDictionary, parseHandler: {
                guard let dict = responseDictionary["appId"] as? [String: Any] else { return nil }
                return ALTAppID(responseDictionary: dict)
            }, resultCodeHandler: { resultCode in
                switch resultCode {
                case 35:
                    return NSError(domain: ALTAppleAPIErrorDomain, code: ALTAppleAPIError.invalidAppIDName.rawValue, userInfo: nil) as Error
                case 9100:
                    return NSError(domain: ALTAppleAPIErrorDomain, code: ALTAppleAPIError.appIDDoesNotExist.rawValue, userInfo: nil) as Error
                case 9412:
                    return NSError(domain: ALTAppleAPIErrorDomain, code: ALTAppleAPIError.invalidBundleIdentifier.rawValue, userInfo: nil) as Error
                default:
                    return nil
                }
            }, error: &error) as? ALTAppID
            
            verboseLog("[AltSign] update App ID completed: \(updatedAppID?.bundleIdentifier ?? "nil") (error: \(error?.localizedDescription ?? "nil"))")
            completionHandler(updatedAppID, error)
        }
    }
    
    func deleteAppID(_ appID: ALTAppID, for team: ALTTeam, session: ALTAppleAPISession, completionHandler: @escaping (Bool, Error?) -> Void) {
        verboseLog("[AltSign] deleteAppID starting for App ID: \(appID.bundleIdentifier)")
        let url = URL(string: "ios/deleteAppId.action", relativeTo: self.baseURL)!
        
        self.sendRequest(url: url, additionalParameters: ["appIdId": appID.identifier], session: session, team: team) { responseDictionary, requestError in
            if let error = requestError {
                verboseLog("[AltSign] deleteAppID request failed with error: \(error)")
            }
            guard let responseDictionary else {
                completionHandler(false, requestError)
                return
            }
            
            var error: Error? = nil
            let value = self.processResponse(responseDictionary, parseHandler: {
                guard let result = responseDictionary["resultCode"] as? Int else { return nil }
                return result == 0 ? result as Any : nil
            }, resultCodeHandler: { resultCode in
                if resultCode == 9100 {
                    return NSError(domain: ALTAppleAPIErrorDomain, code: ALTAppleAPIError.appIDDoesNotExist.rawValue, userInfo: nil) as Error
                }
                return nil
            }, error: &error)
            
            verboseLog("[AltSign] deleteAppID completed with success: \(value != nil) (error: \(error?.localizedDescription ?? "nil"))")
            completionHandler(value != nil, error)
        }
    }
    
    /* App Groups */
    func fetchAppGroups(for team: ALTTeam, session: ALTAppleAPISession, completionHandler: @escaping ([ALTAppGroup]?, Error?) -> Void) {
        verboseLog("[AltSign] fetchAppGroups starting for team: \(team.name)")
        let url = URL(string: "ios/listApplicationGroups.action", relativeTo: self.baseURL)!
        
        self.sendRequest(url: url, additionalParameters: nil, session: session, team: team) { responseDictionary, requestError in
            if let error = requestError {
                verboseLog("[AltSign] fetchAppGroups request failed with error: \(error)")
            }
            guard let responseDictionary else {
                completionHandler(nil, requestError)
                return
            }
            
            var error: Error? = nil
            let groups = self.processResponse(responseDictionary, parseHandler: {
                guard let array = responseDictionary["applicationGroupList"] as? [[String: Any]] else { return nil }
                var list = [ALTAppGroup]()
                for dict in array {
                    guard let group = ALTAppGroup(responseDictionary: dict) else { return nil }
                    list.append(group)
                }
                return list
            }, resultCodeHandler: nil, error: &error) as? [ALTAppGroup]
            
            verboseLog("[AltSign] fetchAppGroups completed: \(groups?.map { $0.groupIdentifier } ?? [])")
            completionHandler(groups, error)
        }
    }
    
    func addAppGroup(withName name: String, groupIdentifier: String, team: ALTTeam, session: ALTAppleAPISession, completionHandler: @escaping (ALTAppGroup?, Error?) -> Void) {
        verboseLog("[AltSign] addAppGroup starting with name: \(name), groupIdentifier: \(groupIdentifier)")
        let url = URL(string: "ios/addApplicationGroup.action", relativeTo: self.baseURL)!
        
        self.sendRequest(url: url, additionalParameters: ["identifier": groupIdentifier, "name": name], session: session, team: team) { responseDictionary, requestError in
            if let error = requestError {
                verboseLog("[AltSign] addAppGroup request failed with error: \(error)")
            }
            guard let responseDictionary else {
                completionHandler(nil, requestError)
                return
            }
            
            var error: Error? = nil
            let group = self.processResponse(responseDictionary, parseHandler: {
                guard let dict = responseDictionary["applicationGroup"] as? [String: Any] else { return nil }
                return ALTAppGroup(responseDictionary: dict)
            }, resultCodeHandler: { resultCode in
                if resultCode == 35 {
                    return NSError(domain: ALTAppleAPIErrorDomain, code: ALTAppleAPIError.invalidAppGroup.rawValue, userInfo: nil) as Error
                }
                return nil
            }, error: &error) as? ALTAppGroup
            
            verboseLog("[AltSign] addAppGroup completed: \(group?.groupIdentifier ?? "nil") (error: \(error?.localizedDescription ?? "nil"))")
            completionHandler(group, error)
        }
    }
    
    func assign(_ appID: ALTAppID, to groups: [ALTAppGroup], team: ALTTeam, session: ALTAppleAPISession, completionHandler: @escaping (Bool, Error?) -> Void) {
        verboseLog("[AltSign] assign App ID: \(appID.bundleIdentifier) to groups: \(groups.map { $0.groupIdentifier })")
        let url = URL(string: "ios/assignApplicationGroupToAppId.action", relativeTo: self.baseURL)!
        
        let groupIDs = groups.map { $0.identifier }
        let parameters: [String: Any] = [
            "appIdId": appID.identifier,
            "applicationGroups": groupIDs
        ]
        
        self.sendRequest(url: url, plistParameters: parameters, session: session, team: team) { responseDictionary, requestError in
            if let error = requestError {
                verboseLog("[AltSign] assign request failed with error: \(error)")
            }
            guard let responseDictionary else {
                completionHandler(false, requestError)
                return
            }
            
            var error: Error? = nil
            let value = self.processResponse(responseDictionary, parseHandler: {
                guard let result = responseDictionary["resultCode"] as? Int else { return nil }
                return result == 0 ? result as Any : nil
            }, resultCodeHandler: { resultCode in
                switch resultCode {
                case 9115:
                    return NSError(domain: ALTAppleAPIErrorDomain, code: ALTAppleAPIError.appIDDoesNotExist.rawValue, userInfo: nil) as Error
                case 35:
                    return NSError(domain: ALTAppleAPIErrorDomain, code: ALTAppleAPIError.appGroupDoesNotExist.rawValue, userInfo: nil) as Error
                default:
                    return nil
                }
            }, error: &error)
            
            verboseLog("[AltSign] assign completed with success: \(value != nil) (error: \(error?.localizedDescription ?? "nil"))")
            completionHandler(value != nil, error)
        }
    }
    
    /* Provisioning Profiles */
    func fetchProvisioningProfile(for appID: ALTAppID, deviceType: ALTDeviceType, team: ALTTeam, session: ALTAppleAPISession, completionHandler: @escaping (ALTProvisioningProfile?, Error?) -> Void) {
        verboseLog("[AltSign] fetchProvisioningProfile starting for App ID: \(appID.bundleIdentifier), deviceType: \(deviceType)")
        let url = URL(string: "ios/downloadTeamProvisioningProfile.action", relativeTo: self.baseURL)!
        
        var parameters = ["appIdId": appID.identifier]
        if deviceType.contains(.iphone) || deviceType.contains(.ipad) {
            parameters["DTDK_Platform"] = "ios"
        } else if deviceType.contains(.appleTV) {
            parameters["DTDK_Platform"] = "tvos"
            parameters["subPlatform"] = "tvOS"
        }
        
        self.sendRequest(url: url, additionalParameters: parameters, session: session, team: team) { responseDictionary, requestError in
            if let error = requestError {
                verboseLog("[AltSign] fetchProvisioningProfile request failed with error: \(error)")
            }
            guard let responseDictionary else {
                completionHandler(nil, requestError)
                return
            }
            
            var error: Error? = nil
            let profile = self.processResponse(responseDictionary, parseHandler: {
                guard let dict = responseDictionary["provisioningProfile"] as? [String: Any] else { return nil }
                return ALTProvisioningProfile(responseDictionary: dict)
            }, resultCodeHandler: { resultCode in
                if resultCode == 8201 {
                    return NSError(domain: ALTAppleAPIErrorDomain, code: ALTAppleAPIError.appIDDoesNotExist.rawValue, userInfo: nil) as Error
                }
                return nil
            }, error: &error) as? ALTProvisioningProfile
            
            verboseLog("[AltSign] fetchProvisioningProfile completed: \(profile?.name ?? "nil") (error: \(error?.localizedDescription ?? "nil"))")
            completionHandler(profile, error)
        }
    }
    
    func deleteProvisioningProfile(_ provisioningProfile: ALTProvisioningProfile, for team: ALTTeam, session: ALTAppleAPISession, completionHandler: @escaping (Bool, Error?) -> Void) {
        verboseLog("[AltSign] delete provisioning profile starting: \(provisioningProfile.name) (ID: \(provisioningProfile.identifier ?? "nil"))")
        let url = URL(string: "ios/deleteProvisioningProfile.action", relativeTo: self.baseURL)!
        
        let parameters = [
            "provisioningProfileId": provisioningProfile.identifier ?? "",
            "teamId": team.identifier
        ]
        
        self.sendRequest(url: url, additionalParameters: parameters, session: session, team: team) { responseDictionary, requestError in
            if let error = requestError {
                verboseLog("[AltSign] delete provisioning profile request failed with error: \(error)")
            }
            guard let responseDictionary else {
                completionHandler(false, requestError)
                return
            }
            
            var error: Error? = nil
            let value = self.processResponse(responseDictionary, parseHandler: {
                guard let result = responseDictionary["resultCode"] as? Int else { return nil }
                return result == 0 ? result as Any : nil
            }, resultCodeHandler: { resultCode in
                switch resultCode {
                case 35:
                    return NSError(domain: ALTAppleAPIErrorDomain, code: ALTAppleAPIError.invalidProvisioningProfileIdentifier.rawValue, userInfo: nil) as Error
                case 8101:
                    return NSError(domain: ALTAppleAPIErrorDomain, code: ALTAppleAPIError.provisioningProfileDoesNotExist.rawValue, userInfo: nil) as Error
                default:
                    return nil
                }
            }, error: &error)
            
            verboseLog("[AltSign] delete provisioning profile completed with success: \(value != nil) (error: \(error?.localizedDescription ?? "nil"))")
            completionHandler(value != nil, error)
        }
    }
    
    // MARK: - Helper plist request with [String: Any]
    
    func sendRequest(
        url requestURL: URL,
        plistParameters: [String: Any]?,
        session apiSession: ALTAppleAPISession,
        team: ALTTeam?,
        completionHandler: @escaping ([String: Any]?, Error?) -> Void
    ) {
        var parameters: [String: Any] = [
            "clientId": ALTClientID,
            "protocolVersion": ALTProtocolVersion,
            "requestId": UUID().uuidString.uppercased()
        ]

        if let team {
            parameters["teamId"] = team.identifier
        }

        plistParameters?.forEach { parameters[$0] = $1 }

        let bodyData: Data
        do {
            bodyData = try PropertyListSerialization.data(
                fromPropertyList: parameters,
                format: .xml,
                options: 0
            )
        } catch {
            verboseLog("[AltSign] sendRequest(plist) serialization failed: \(error)")
            completionHandler(
                nil,
                NSError(
                    domain: ALTAppleAPIErrorDomain,
                    code: ALTAppleAPIError.invalidParameters.rawValue,
                    userInfo: [NSUnderlyingErrorKey: error]
                )
            )
            return
        }

        let url = URL(
            string: "\(requestURL.absoluteString)?clientId=\(ALTClientID)"
        )!

        verboseLog("[AltSign] sendRequest(plist) to: \(url.absoluteString)")
        verboseLog("[AltSign] sendRequest(plist) parameters: \(parameters)")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyData

        let a = apiSession.anisetteData

        let headers: [String: String] = [
            "Content-Type": "text/x-xml-plist",
            "User-Agent": "Xcode",
            "Accept": "text/x-xml-plist",
            "Accept-Language": "en-us",
            "X-Apple-App-Info": "com.apple.gs.xcode.auth",
            "X-Xcode-Version": "11.2 (11B41)",
            "X-Apple-I-Identity-Id": apiSession.dsid,
            "X-Apple-GS-Token": apiSession.authToken,
            "X-Apple-I-MD-M": a.machineID,
            "X-Apple-I-MD": a.oneTimePassword,
            "X-Apple-I-MD-LU": a.localUserID,
            "X-Apple-I-MD-RINFO": "\(a.routingInfo)",
            "X-Mme-Device-Id": a.deviceUniqueIdentifier,
            "X-MMe-Client-Info": a.deviceDescription,
            "X-Apple-I-Client-Time": dateFormatter.string(from: a.date),
            "X-Apple-Locale": a.localeHeader,
            "X-Apple-I-Locale": a.localeHeader,
            "X-Apple-I-TimeZone": a.timeZone.abbreviation(for: a.date) ?? ""
        ]

        headers.forEach {
            request.setValue($1, forHTTPHeaderField: $0)
        }

        session.dataTask(with: request) { data, _, error in
            if let error {
                verboseLog("[AltSign] sendRequest(plist) failed with error: \(error)")
            }
            guard let data else {
                completionHandler(nil, error)
                return
            }

            do {
                let plist = try PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: nil
                )
                verboseLog("[AltSign] sendRequest(plist) response: \(plist as? [String: Any] ?? [:])")
                completionHandler(plist as? [String: Any], nil)
            } catch {
                verboseLog("[AltSign] sendRequest(plist) failed to parse response plist. Raw: \(String(data: data, encoding: .utf8) ?? "unable to decode")")
                completionHandler(
                    nil,
                    NSError(
                        domain: NSURLErrorDomain,
                        code: NSURLErrorBadServerResponse,
                        userInfo: [NSUnderlyingErrorKey: error]
                    )
                )
            }
        }.resume()
    }

    func sendRequest(
        with requestURL: URL,
        additionalParameters: [String: String]?,
        session apiSession: ALTAppleAPISession,
        team: ALTTeam?,
        completionHandler: @escaping ([String: Any]?, Error?) -> Void
    ) {
        self.sendRequest(
            url: requestURL,
            additionalParameters: additionalParameters,
            session: apiSession,
            team: team,
            completionHandler: completionHandler
        )
    }
}

// MARK: - Async/Await Wrappers

extension ALTAppleAPI {
    public func fetchProvisioningProfile(for appID: ALTAppID, deviceType: ALTDeviceType, team: ALTTeam, session: ALTAppleAPISession) async throws -> ALTProvisioningProfile {
        try await withCheckedThrowingContinuation { continuation in
            self.fetchProvisioningProfile(for: appID, deviceType: deviceType, team: team, session: session) { (profile, error) in
                if let profile = profile {
                    continuation.resume(returning: profile)
                } else {
                    continuation.resume(throwing: error ?? ALTAppleAPIError.unknown())
                }
            }
        }
    }
    
    public func deleteProvisioningProfile(_ profile: ALTProvisioningProfile, for team: ALTTeam, session: ALTAppleAPISession) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.deleteProvisioningProfile(profile, for: team, session: session) { (success, error) in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? ALTAppleAPIError.unknown())
                }
            }
        }
    }
    
    public func fetchAppIDs(for team: ALTTeam, session: ALTAppleAPISession) async throws -> [ALTAppID] {
        try await withCheckedThrowingContinuation { continuation in
            self.fetchAppIDs(for: team, session: session) { (appIDs, error) in
                if let appIDs = appIDs {
                    continuation.resume(returning: appIDs)
                } else {
                    continuation.resume(throwing: error ?? ALTAppleAPIError.unknown())
                }
            }
        }
    }
    
    public func addAppID(withName name: String, bundleIdentifier: String, team: ALTTeam, session: ALTAppleAPISession) async throws -> ALTAppID {
        try await withCheckedThrowingContinuation { continuation in
            self.addAppID(withName: name, bundleIdentifier: bundleIdentifier, team: team, session: session) { (appID, error) in
                if let appID = appID {
                    continuation.resume(returning: appID)
                } else {
                    continuation.resume(throwing: error ?? ALTAppleAPIError.unknown())
                }
            }
        }
    }
    
    public func update(_ appID: ALTAppID, team: ALTTeam, session: ALTAppleAPISession) async throws -> ALTAppID {
        try await withCheckedThrowingContinuation { continuation in
            self.update(appID, team: team, session: session) { (updatedAppID, error) in
                if let updatedAppID = updatedAppID {
                    continuation.resume(returning: updatedAppID)
                } else {
                    continuation.resume(throwing: error ?? ALTAppleAPIError.unknown())
                }
            }
        }
    }
    
    public func fetchAppGroups(for team: ALTTeam, session: ALTAppleAPISession) async throws -> [ALTAppGroup] {
        try await withCheckedThrowingContinuation { continuation in
            self.fetchAppGroups(for: team, session: session) { (groups, error) in
                if let groups = groups {
                    continuation.resume(returning: groups)
                } else {
                    continuation.resume(throwing: error ?? ALTAppleAPIError.unknown())
                }
            }
        }
    }
    
    public func addAppGroup(withName name: String, groupIdentifier: String, team: ALTTeam, session: ALTAppleAPISession) async throws -> ALTAppGroup {
        try await withCheckedThrowingContinuation { continuation in
            self.addAppGroup(withName: name, groupIdentifier: groupIdentifier, team: team, session: session) { (group, error) in
                if let group = group {
                    continuation.resume(returning: group)
                } else {
                    continuation.resume(throwing: error ?? ALTAppleAPIError.unknown())
                }
            }
        }
    }
    
    public func assign(_ appID: ALTAppID, to groups: [ALTAppGroup], team: ALTTeam, session: ALTAppleAPISession) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.assign(appID, to: groups, team: team, session: session) { (success, error) in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? ALTAppleAPIError.unknown())
                }
            }
        }
    }
}
