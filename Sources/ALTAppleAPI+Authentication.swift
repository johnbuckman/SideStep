//
//  ALTAppleAPI+Authentication.swift
//  AltSign
//
//  Created by Riley Testut on 8/15/20.
//  Copyright © 2020 Riley Testut. All rights reserved.
//

import Foundation
import SwiftBridge

public extension ALTAppleAPI
{
    @objc func authenticate(appleID unsanitizedAppleID: String,
                            password: String,
                            anisetteData: ALTAnisetteData,
                            verificationHandler: ((@escaping (String?) -> Void) -> Void)?,
                            completionHandler: @escaping (ALTAccount?, ALTAppleAPISession?, Error?) -> Void) {
        authenticate(appleID: unsanitizedAppleID, password: password, anisetteData: anisetteData,
                     verificationHandler: verificationHandler, completionHandler: completionHandler, afterTwoFactor: false)
    }

    /// `afterTwoFactor`: this is the sign-in retry right after Apple accepted a 2FA code.
    /// If Apple still demands 2FA then, stop instead of requesting yet another code.
    private func authenticate(appleID unsanitizedAppleID: String,
                              password: String,
                              anisetteData: ALTAnisetteData,
                              verificationHandler: ((@escaping (String?) -> Void) -> Void)?,
                              completionHandler: @escaping (ALTAccount?, ALTAppleAPISession?, Error?) -> Void,
                              afterTwoFactor: Bool) {
        // Authenticating only works with lowercase email address, even if Apple ID contains capital letters.
        let sanitizedAppleID = unsanitizedAppleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        debugLog("[AltSign] Starting authenticate for Apple ID: \(sanitizedAppleID)")

        do {
            var clientDictionary = [
                "bootstrap": true,
                "icscrec": true,
                "pbe": false,
                "prkgen": true,
                "svct": "iCloud",
                "loc": anisetteData.locale.sanitizedIdentifier,
                "X-Apple-Locale": anisetteData.locale.sanitizedIdentifier,
                "X-Apple-I-MD": anisetteData.oneTimePassword,
                "X-Apple-I-MD-M": anisetteData.machineID,
                "X-Mme-Device-Id": anisetteData.deviceUniqueIdentifier,
                "X-Apple-I-MD-LU": anisetteData.localUserID,
                "X-Apple-I-MD-RINFO": anisetteData.routingInfo,
                "X-Apple-I-SRL-NO": anisetteData.deviceSerialNumber,
                "X-Apple-I-Client-Time": dateFormatter.string(from: anisetteData.date),
                "X-Apple-I-TimeZone": anisetteData.timeZone.abbreviation() ?? "PST"
            ] as [String: Any]
            if ALTAppleAPI.remoteAnisetteUserAgent != nil {
                // Remote Anisette describes a different (virtual) machine; send only what
                // isideload sends so nothing contradicts it: device id + MD + MD-M.
                for key in ["X-Apple-I-MD-LU", "X-Apple-I-MD-RINFO", "X-Apple-I-SRL-NO", "X-Apple-I-Client-Time", "X-Apple-I-TimeZone", "X-Apple-Locale"] {
                    clientDictionary.removeValue(forKey: key)
                }
                clientDictionary["loc"] = "en_US"
            }

            let context = GSAContext(username: sanitizedAppleID, password: password)
            guard let publicKey = context.start() else {
                verboseLog("[AltSign] Failed to start GSAContext / generate public key A")
                throw ALTAppleAPIError.authenticationHandshakeFailed
            }

            verboseLog("[AltSign] GSAContext started. Generated public key A (A2k): \(publicKey.hexEncodedString())")

            let parameters = [
                "A2k": publicKey,
                "cpd": clientDictionary,
                "ps": ["s2k", "s2k_fo"],
                "o": "init",
                "u": sanitizedAppleID
            ] as [String: Any]

            debugLog("[AltSign] Sending authentication 'init' request...")
            sendAuthenticationRequest(parameters: parameters, anisetteData: anisetteData) { result in
                do {
                    let responseDictionary = try result.get()

                    guard let c = responseDictionary["c"] as? String,
                          let salt = responseDictionary["s"] as? Data,
                          let iterations = responseDictionary["i"] as? Int,
                          let serverPublicKey = responseDictionary["B"] as? Data
                    else {
                        verboseLog("[AltSign] Failed to parse authentication init response dictionary: \(responseDictionary)")
                        throw ALTServerError.badServerResponse(reason: "Auth init response missing c/s/i/B parameters", jsonPayload: self.formatPayloadJSON(responseDictionary))
                    }

                    verboseLog("""
                    [AltSign] Received init response:
                      • c: \(c)
                      • salt: \(salt.hexEncodedString())
                      • iterations: \(iterations)
                      • B: \(serverPublicKey.hexEncodedString())
                    """)

                    context.salt = salt
                    context.serverPublicKey = serverPublicKey

                    let sp = responseDictionary["sp"] as? String
                    let isHexadecimal = (sp == "s2k_fo")

                    guard let verificationMessage = context.makeVerificationMessage(iterations: iterations, isHexadecimal: isHexadecimal) else {
                        verboseLog("[AltSign] Failed to generate verification message M1")
                        throw ALTAppleAPIError.authenticationHandshakeFailed
                    }

                    verboseLog("[AltSign] Generated verification message M1: \(verificationMessage.hexEncodedString())")

                    let parameters = [
                        "c": c,
                        "cpd": clientDictionary,
                        "M1": verificationMessage,
                        "o": "complete",
                        "u": sanitizedAppleID
                    ] as [String: Any]

                    debugLog("[AltSign] Sending authentication 'complete' request...")
                    self.sendAuthenticationRequest(parameters: parameters, anisetteData: anisetteData) { result in
                        do {
                            let responseDictionary = try result.get()

                            guard let serverVerificationMessage = responseDictionary["M2"] as? Data,
                                  let serverDictionary = responseDictionary["spd"] as? Data,
                                  let statusDictionary = responseDictionary["Status"] as? [String: Any]
                            else {
                                verboseLog("[AltSign] Failed to parse complete response dictionary: \(responseDictionary)")
                                throw ALTServerError.badServerResponse(reason: "Auth complete response missing M2/spd/Status parameters", jsonPayload: self.formatPayloadJSON(responseDictionary))
                            }

                            verboseLog("""
                            [AltSign] Received complete response:
                              • M2: \(serverVerificationMessage.hexEncodedString())
                              • spd size: \(serverDictionary.count) bytes
                            """)

                            guard context.verifyServerVerificationMessage(serverVerificationMessage) else {
                                verboseLog("[AltSign] Server verification message M2 failed validation!")
                                throw ALTAppleAPIError.authenticationHandshakeFailed
                            }
                            verboseLog("[AltSign] Server verification message M2 validated successfully.")

                            guard let decryptedData = serverDictionary.decryptedCBC(context: context) else {
                                verboseLog("[AltSign] Failed to decrypt server dictionary (spd)")
                                throw ALTAppleAPIError.authenticationHandshakeFailed
                            }
                            verboseLog("[AltSign] Decrypted server dictionary successfully.")

                            guard let decryptedDictionary = self.parsePlistOrJSON(decryptedData) else {
                                let rawDecrypted = "<\(decryptedData.count) bytes redacted>"
                                verboseLog("[AltSign] Decrypted payload format is invalid (neither Plist nor JSON): \(rawDecrypted)")
                                throw ALTServerError.invalidResponseFormat(rawPayload: rawDecrypted)
                            }

                            guard let dsid = (decryptedDictionary["adsid"] as? String) ?? (decryptedDictionary["dsid"] as? CustomStringConvertible)?.description,
                                  let idmsToken = (decryptedDictionary["GsIdmsToken"] as? String) ?? (decryptedDictionary["idmsToken"] as? String)
                            else {
                                let jsonStr = self.keyNames(decryptedDictionary)
                                verboseLog("[AltSign] Decrypted dictionary missing adsid/GsIdmsToken: \(jsonStr)")
                                throw ALTServerError.missingKey(key: "adsid/GsIdmsToken", jsonPayload: jsonStr)
                            }

                            verboseLog("[AltSign] Parse complete. dsid: \(dsid), token: <redacted>")
                            context.dsid = dsid

                            let authType = statusDictionary["au"] as? String
                            verboseLog("[AltSign] Authentication status type: \(authType ?? "nil")")

                            switch authType {
                            case "trustedDeviceSecondaryAuth":
                                if afterTwoFactor {
                                    verboseLog("[AltSign] Apple accepted the 2FA code but still requires \(authType ?? "2FA") — stopping instead of requesting another code")
                                    throw ALTAppleAPIError.requiresTwoFactorAuthentication
                                }
                                guard let verificationHandler = verificationHandler else { throw ALTAppleAPIError.requiresTwoFactorAuthentication }

                                if ALTAppleAPI.preferSMSTwoFactorCode {
                                    // Account has no signed-in Apple device: deliver the code by SMS instead.
                                    self.requestSMSTwoFactorCode(dsid: dsid, idmsToken: idmsToken, anisetteData: anisetteData, verificationHandler: verificationHandler) { result in
                                        switch result {
                                        case let .failure(error): completionHandler(nil, nil, error)
                                        case .success:
                                            self.authenticate(appleID: unsanitizedAppleID, password: password, anisetteData: ALTAppleAPI.freshAnisette?() ?? anisetteData, verificationHandler: verificationHandler, completionHandler: completionHandler, afterTwoFactor: true)
                                        }
                                    }
                                } else {
                                    self.requestTrustedDeviceTwoFactorCode(dsid: dsid, idmsToken: idmsToken, anisetteData: anisetteData, verificationHandler: verificationHandler) { result in
                                        switch result {
                                        case let .failure(error): completionHandler(nil, nil, error)
                                        case .success:
                                            self.authenticate(appleID: unsanitizedAppleID, password: password, anisetteData: ALTAppleAPI.freshAnisette?() ?? anisetteData, verificationHandler: verificationHandler, completionHandler: completionHandler, afterTwoFactor: true)
                                        }
                                    }
                                }

                            case "secondaryAuth":
                                if afterTwoFactor {
                                    verboseLog("[AltSign] Apple accepted the 2FA code but still requires \(authType ?? "2FA") — stopping instead of requesting another code")
                                    throw ALTAppleAPIError.requiresTwoFactorAuthentication
                                }
                                guard let verificationHandler = verificationHandler else { throw ALTAppleAPIError.requiresTwoFactorAuthentication }

                                self.requestSMSTwoFactorCode(dsid: dsid, idmsToken: idmsToken, anisetteData: anisetteData, verificationHandler: verificationHandler) { result in
                                    switch result {
                                    case let .failure(error): completionHandler(nil, nil, error)
                                    case .success:
                                        self.authenticate(appleID: unsanitizedAppleID, password: password, anisetteData: ALTAppleAPI.freshAnisette?() ?? anisetteData, verificationHandler: verificationHandler, completionHandler: completionHandler, afterTwoFactor: true)
                                    }
                                }

                            default:
                                guard let sessionKey = decryptedDictionary["sk"] as? Data,
                                      let c = decryptedDictionary["c"] as? Data
                                else { throw ALTServerError.missingKey(key: "sk/c", jsonPayload: self.keyNames(decryptedDictionary)) }

                                context.sessionKey = sessionKey

                                let app = "com.apple.gs.xcode.auth"
                                guard let checksum = context.makeChecksum(appName: app) else { throw ALTAppleAPIError.authenticationHandshakeFailed }

                                let parameters = [
                                    "app": [app],
                                    "c": c,
                                    "checksum": checksum,
                                    "cpd": clientDictionary,
                                    "o": "apptokens",
                                    "t": idmsToken,
                                    "u": dsid
                                ] as [String: Any]

                                self.fetchAuthToken(app: app, parameters: parameters, context: context, anisetteData: anisetteData) { result in
                                    switch result {
                                    case let .failure(error): completionHandler(nil, nil, error)
                                    case let .success(token):

                                        let session = ALTAppleAPISession(dsid: dsid, authToken: token, anisetteData: anisetteData)
                                        self.fetchAccount(session: session) { result in
                                            switch result {
                                            case let .failure(error): completionHandler(nil, nil, error)
                                            case let .success(account): completionHandler(account, session, nil)
                                            }
                                        }
                                    }
                                }
                            }
                        } catch {
                            completionHandler(nil, nil, error)
                        }
                    }
                } catch {
                    completionHandler(nil, nil, error)
                }
            }
        } catch {
            completionHandler(nil, nil, error)
        }
    }
}

private extension ALTAppleAPI {
    func fetchAuthToken(app: String, parameters: [String: Any], context: GSAContext, anisetteData: ALTAnisetteData, completionHandler: @escaping (Result<String, Error>) -> Void) {
        sendAuthenticationRequest(parameters: parameters, anisetteData: anisetteData) { result in
            do {
                let responseDictionary = try result.get()

                guard let encryptedToken = responseDictionary["et"] as? Data else {
                    throw ALTServerError.missingKey(key: "et", jsonPayload: self.formatPayloadJSON(responseDictionary))
                }
                guard let token = encryptedToken.decryptedGCM(context: context) else { throw ALTAppleAPIError.authenticationHandshakeFailed }

                guard let tokensDictionary = self.parsePlistOrJSON(token) else {
                    let rawTokenStr = "<\(token.count) bytes redacted>"
                    throw ALTServerError.invalidResponseFormat(rawPayload: rawTokenStr)
                }

                guard let appTokens = tokensDictionary["t"] as? [String: Any],
                      let tokens = appTokens[app] as? [String: Any],
                      let authToken = tokens["token"] as? String
                else { throw ALTServerError.missingKey(key: "t/\(app)/token", jsonPayload: self.keyNames(tokensDictionary)) }

                completionHandler(.success(authToken))
            } catch {
                completionHandler(.failure(error))
            }
        }
    }

    func requestTrustedDeviceTwoFactorCode(dsid: String,
                                           idmsToken: String,
                                           anisetteData: ALTAnisetteData,
                                           verificationHandler: @escaping (@escaping (String?) -> Void) -> Void,
                                           completionHandler: @escaping (Result<Void, Error>) -> Void) {
        verboseLog("[AltSign] requestTrustedDeviceTwoFactorCode starting for dsid: \(dsid)")
        let requestURL = URL(string: "https://gsa.apple.com/auth/verify/trusteddevice")!
        let verifyURL = URL(string: "https://gsa.apple.com/grandslam/GsService2/validate")!

        let request = makeTwoFactorCodeRequest(url: requestURL, dsid: dsid, idmsToken: idmsToken, anisetteData: anisetteData)

        let requestCodeTask = session.dataTask(with: request) { data, response, error in
            let httpResponse = response as? HTTPURLResponse
            let statusCode = httpResponse?.statusCode ?? 0
            let responseStr = data != nil ? self.formatPayloadJSON(data!) : "nil"
            if let error {
                verboseLog("[AltSign] requestTrustedDeviceTwoFactorCode request code task failed: \(error) (status: \(statusCode))")
            } else {
                verboseLog("[AltSign] requestTrustedDeviceTwoFactorCode request code task succeeded (status: \(statusCode), response: \(responseStr))")
            }
            do {
                guard error == nil else { throw error! }

                func responseHandler(verificationCode: String?) {
                    verboseLog("[AltSign] requestTrustedDeviceTwoFactorCode received code from user. Has code: \(verificationCode != nil)")
                    do {
                        guard let verificationCode = verificationCode else { throw ALTAppleAPIError.requiresTwoFactorAuthentication }

                        var request = self.makeTwoFactorCodeRequest(url: verifyURL, dsid: dsid, idmsToken: idmsToken, anisetteData: anisetteData)
                        request.allHTTPHeaderFields?["security-code"] = verificationCode

                        verboseLog("[AltSign] requestTrustedDeviceTwoFactorCode verifying code...")
                        let verifyCodeTask = self.session.dataTask(with: request) { (data, response, error) in
                            do
                            {
                                if let error {
                                    verboseLog("[AltSign] requestTrustedDeviceTwoFactorCode verification failed with error: \(error)")
                                }
                                guard let data = data else { throw error ?? ALTAppleAPIError.unknown }

                                guard let responseDictionary = self.parsePlistOrJSON(data) else {
                                    let rawVerifyStr = self.formatPayloadJSON(data)
                                    verboseLog("[AltSign] requestTrustedDeviceTwoFactorCode verify response is invalid: \(rawVerifyStr)")
                                    throw ALTServerError.invalidResponseFormat(rawPayload: rawVerifyStr)
                                }

                                let errorCode = responseDictionary["ec"] as? Int ?? 0
                                guard errorCode != 0 else {
                                    verboseLog("[AltSign] requestTrustedDeviceTwoFactorCode code verified successfully!")
                                    return completionHandler(.success(()))
                                }

                                verboseLog("[AltSign] requestTrustedDeviceTwoFactorCode verification error code: \(errorCode)")
                                switch errorCode {
                                case -21669: throw ALTAppleAPIError.incorrectVerificationCode
                                default:
                                    guard let errorDescription = responseDictionary["em"] as? String else { throw ALTAppleAPIError.unknown }

                                    let localizedDescription = errorDescription + " (\(errorCode))"
                                    throw NSError(domain: ALTUnderlyingAppleAPIErrorDomain, code: errorCode, userInfo: [NSLocalizedDescriptionKey: localizedDescription])
                                }
                            } catch {
                                completionHandler(.failure(error))
                            }
                        }

                        verifyCodeTask.resume()
                    } catch {
                        completionHandler(.failure(error))
                    }
                }

                verificationHandler(responseHandler)
            } catch {
                completionHandler(.failure(error))
            }
        }

        requestCodeTask.resume()
    }

    func requestSMSTwoFactorCode(dsid: String,
                                 idmsToken: String,
                                 anisetteData: ALTAnisetteData,
                                 verificationHandler: @escaping (@escaping (String?) -> Void) -> Void,
                                 completionHandler: @escaping (Result<Void, Error>) -> Void) {
        verboseLog("[AltSign] requestSMSTwoFactorCode starting for dsid: \(dsid)")
        // JSON phone-verification API, matching isideload (nab138/isideload, auth/apple_account.rs).
        // The older buddyml form flow (POST …/phone/put + …/securitycode?referrer=…) accepted
        // the code but left the follow-up sign-in still demanding secondaryAuth, so every
        // verified code just triggered another SMS. No trailing slash: "/phone/" answers 405.
        let requestURL = URL(string: "https://gsa.apple.com/auth/verify/phone")!
        let verifyURL = URL(string: "https://gsa.apple.com/auth/verify/phone/securitycode")!

        var request = makeSMSTwoFactorRequest(url: requestURL, dsid: dsid, idmsToken: idmsToken, anisetteData: anisetteData)
        request.httpMethod = "PUT"

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: ["phoneNumber": ["id": 1], "mode": "sms"])
        } catch {
            verboseLog("[AltSign] requestSMSTwoFactorCode serialization failed: \(error)")
            completionHandler(.failure(error))
            return
        }

        let requestCodeTask = session.dataTask(with: request) { data, response, error in
            let httpResponse = response as? HTTPURLResponse
            let statusCode = httpResponse?.statusCode ?? 0
            let responseStr = data != nil ? self.formatPayloadJSON(data!) : "nil"
            if let error {
                verboseLog("[AltSign] requestSMSTwoFactorCode request code task failed: \(error) (status: \(statusCode))")
            } else {
                verboseLog("[AltSign] requestSMSTwoFactorCode request code task succeeded (status: \(statusCode), response: \(responseStr))")
            }
            do {
                guard error == nil else { throw error! }
                // Don't prompt for a code Apple never sent.
                guard (200..<300).contains(statusCode) else {
                    throw ALTServerError.badServerResponse(reason: "Apple refused to send the SMS code (HTTP \(statusCode))", jsonPayload: "")
                }

                func responseHandler(verificationCode: String?) {
                    verboseLog("[AltSign] requestSMSTwoFactorCode received code from user. Has code: \(verificationCode != nil)")
                    do {
                        guard let verificationCode = verificationCode else { throw ALTAppleAPIError.requiresTwoFactorAuthentication }

                        var request = self.makeSMSTwoFactorRequest(url: verifyURL, dsid: dsid, idmsToken: idmsToken, anisetteData: anisetteData)
                        request.httpMethod = "POST"
                        request.httpBody = try JSONSerialization.data(withJSONObject: [
                            "phoneNumber": ["id": 1],
                            "mode": "sms",
                            "securityCode": ["code": verificationCode]
                        ])

                        verboseLog("[AltSign] requestSMSTwoFactorCode verifying code...")
                        let verifyCodeTask = self.session.dataTask(with: request) { data, response, error in
                            do {
                                if let error {
                                    verboseLog("[AltSign] requestSMSTwoFactorCode verification failed: \(error)")
                                }
                                guard error == nil else { throw error! }

                                let httpResponse = response as? HTTPURLResponse
                                let statusCode = httpResponse?.statusCode ?? 0
                                let hasPEToken = httpResponse?.allHeaderFields.keys.contains { ($0 as? String)?.lowercased() == "x-apple-pe-token" } ?? false
                                let json = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
                                verboseLog("[AltSign] requestSMSTwoFactorCode verify response: status \(statusCode), PE token: \(hasPEToken), keys: \(json.keys.sorted())")

                                guard statusCode == 200 else {
                                    // e.g. 400 {"serviceErrors":[{"code":"-21669","message":"Incorrect verification code."}]}
                                    let serviceError = (json["serviceErrors"] as? [[String: Any]])?.first
                                    if let message = serviceError?["message"] as? String {
                                        verboseLog("[AltSign] requestSMSTwoFactorCode verification rejected: \(serviceError?["code"] ?? "?") \(message)")
                                    }
                                    throw ALTAppleAPIError.incorrectVerificationCode
                                }

                                verboseLog("[AltSign] requestSMSTwoFactorCode code verified successfully!")
                                completionHandler(.success(()))
                            } catch {
                                completionHandler(.failure(error))
                            }
                        }

                        verifyCodeTask.resume()
                    } catch {
                        completionHandler(.failure(error))
                    }
                }

                verificationHandler(responseHandler)
            } catch {
                completionHandler(.failure(error))
            }
        }

        requestCodeTask.resume()
    }

    func fetchAccount(
        session: ALTAppleAPISession,
        completionHandler: @escaping (Result<ALTAccount, Error>) -> Void
    ) {
        verboseLog("[AltSign] fetchAccount starting for dsid: \(session.dsid)")
        let url = URL(string: "viewDeveloper.action", relativeTo: self.baseURL)!

        self.sendRequest(url: url,
                         additionalParameters: nil,
                         session: session,
                         team: nil) { responseDictionary, requestError in
            do {
                if let requestError {
                    verboseLog("[AltSign] fetchAccount request failed: \(requestError)")
                }

                guard let responseDictionary = responseDictionary else {
                    if let requestError { throw requestError }
                    throw ALTAppleAPIError.unknown
                }

                var processError: Error?

                guard let account = self.processResponse(
                    responseDictionary,
                    parseHandler: {
                        guard let dictionary =
                            responseDictionary["developer"] as? [String: Any]
                        else { return nil }
                        return ALTAccount(responseDictionary: dictionary)
                    },
                    resultCodeHandler: nil,
                    error: &processError
                ) as? ALTAccount else {
                    verboseLog("[AltSign] fetchAccount parsing response failed: \(processError ?? ALTAppleAPIError.unknown)")
                    throw processError ?? ALTAppleAPIError.unknown
                }

                verboseLog("[AltSign] fetchAccount succeeded: \(account.name) (Apple ID: \(account.appleID))")
                completionHandler(.success(account))

            } catch {
                completionHandler(.failure(error))
            }
        }
    }
}

private extension ALTAppleAPI {
    func sendAuthenticationRequest(parameters requestParameters: [String: Any], anisetteData: ALTAnisetteData, retries429: Int = 3, completionHandler: @escaping (Result<[String: Any], Error>) -> Void) {
        do {
            let requestURL = URL(string: "https://gsa.apple.com/grandslam/GsService2")!

            let parameters = [
                "Header": ["Version": "1.0.1"],
                "Request": requestParameters
            ]

            verboseLog("[AltSign] sendAuthenticationRequest payload: \(parameters)")

            var httpHeaders = [
                "Content-Type": "text/x-xml-plist",
                "X-MMe-Client-Info": anisetteData.deviceDescription,
                "Accept": "*/*",
                "User-Agent": "AuthKit/1 (Macintosh; OS X 26.5.2) (com.apple.dt.Xcode/26.0)"
            ]
            if let userAgent = ALTAppleAPI.remoteAnisetteUserAgent {
                // Match the Anisette server's client_info (as isideload does) instead of
                // claiming a macOS 26 AuthKit next to a macOS 13 client info.
                httpHeaders["User-Agent"] = userAgent
                httpHeaders["Accept"] = "text/x-xml-plist"
                httpHeaders["X-Xcode-Version"] = "27.0 (27A5218g)"
                httpHeaders["X-Apple-App-Info"] = "com.apple.gs.xcode.auth"
            }

            let bodyData = try PropertyListSerialization.data(fromPropertyList: parameters, format: .xml, options: 0)

            var request = URLRequest(url: requestURL)
            request.httpMethod = "POST"
            request.httpBody = bodyData
            httpHeaders.forEach { request.addValue($0.value, forHTTPHeaderField: $0.key) }
            // GrandSlam answers 429 to requests on a reused connection (isideload sends
            // Connection: close and builds a new connection per request), so use a
            // one-off session for each request.
            request.setValue("close", forHTTPHeaderField: "Connection")
            let oneShotSession = URLSession(configuration: .ephemeral)

            let dataTask = oneShotSession.dataTask(with: request) { (data, response, error) in
                oneShotSession.finishTasksAndInvalidate()
                do
                {
                    if let error {
                        verboseLog("[AltSign] sendAuthenticationRequest failed with error: \(error)")
                    }
                    if let http = response as? HTTPURLResponse, http.statusCode == 429, retries429 > 0 {
                        verboseLog("[AltSign] sendAuthenticationRequest 429, retrying (\(retries429) left)")
                        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                            self.sendAuthenticationRequest(parameters: requestParameters, anisetteData: anisetteData, retries429: retries429 - 1, completionHandler: completionHandler)
                        }
                        return
                    }
                    if let http = response as? HTTPURLResponse, http.statusCode == 429 {
                        verboseLog("[AltSign] sendAuthenticationRequest 429: Retry-After=\(http.value(forHTTPHeaderField: "Retry-After") ?? "none"), header names=\(http.allHeaderFields.keys.map { "\($0)" }.sorted()), body \(data?.count ?? 0) bytes")
                        throw NSError(domain: ALTAppleAPIErrorDomain, code: 429, userInfo: [
                            NSLocalizedDescriptionKey: "Apple is temporarily limiting sign-in attempts (HTTP 429 Too Many Requests). Wait a few hours before trying again."
                        ])
                    }
                    guard let data = data, !data.isEmpty else {
                        let err = error ?? ALTServerError.badServerResponse(reason: "Server returned empty response (Content-Length: 0) — session may have timed out", jsonPayload: "0 bytes")
                        throw err
                    }

                    guard let responseDictionary = self.parsePlistOrJSON(data),
                          let dictionary = responseDictionary["Response"] as? [String: Any] ?? responseDictionary["response"] as? [String: Any] ?? (responseDictionary["Status"] != nil ? responseDictionary : nil),
                          let status = dictionary["Status"] as? [String: Any] ?? responseDictionary["Status"] as? [String: Any]
                    else {
                        let rawResponse = self.formatPayloadJSON(data)
                        verboseLog("[AltSign] sendAuthenticationRequest response is invalid or could not be parsed: \(rawResponse)")
                        throw ALTServerError.invalidResponseFormat(rawPayload: rawResponse)
                    }

                    verboseLog("[AltSign] sendAuthenticationRequest response Status: \(status)")
                    verboseLog("[AltSign] sendAuthenticationRequest response Data: \(dictionary)")

                    let errorCode = status["ec"] as? Int ?? 0
                    guard errorCode != 0 else { return completionHandler(.success(dictionary)) }

                    verboseLog("[AltSign] sendAuthenticationRequest status returned error code: \(errorCode)")

                    switch errorCode
                    {
                    case -20101, -22406: throw ALTAppleAPIError.incorrectCredentials
                    case -22421: throw ALTAppleAPIError.invalidAnisetteData
                    default:
                        guard let errorDescription = status["em"] as? String else { throw ALTAppleAPIError.unknown }

                        let localizedDescription = errorDescription + " (\(errorCode))"
                        throw NSError(domain: ALTUnderlyingAppleAPIErrorDomain, code: errorCode, userInfo: [NSLocalizedDescriptionKey: localizedDescription])
                    }
                } catch {
                    verboseLog("[AltSign] sendAuthenticationRequest failed during response processing with error: \(error)")
                    completionHandler(.failure(error))
                }
            }

            dataTask.resume()
        } catch {
            verboseLog("[AltSign] sendAuthenticationRequest failed before sending: \(error)")
            completionHandler(.failure(error))
        }
    }

    /// Headers for the JSON phone (SMS) 2FA endpoints, as isideload sends them.
    func makeSMSTwoFactorRequest(url: URL, dsid: String, idmsToken: String, anisetteData: ALTAnisetteData) -> URLRequest {
        var request = makeTwoFactorCodeRequest(url: url, dsid: dsid, idmsToken: idmsToken, anisetteData: anisetteData)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("27.0 (27A5218g)", forHTTPHeaderField: "X-Xcode-Version")
        return request
    }

    func makeTwoFactorCodeRequest(url: URL,
                                  dsid: String,
                                  idmsToken: String,
                                  anisetteData: ALTAnisetteData) -> URLRequest {
        let identityToken = dsid + ":" + idmsToken

        let identityTokenData = identityToken.data(using: .utf8)!
        let encodedIdentityToken = identityTokenData.base64EncodedString()

        let httpHeaders = [
            "Accept": "application/x-buddyml",
            "Accept-Language": "en-us",
            "Content-Type": "application/x-plist",
            "User-Agent": "Xcode",
            "X-Apple-App-Info": "com.apple.gs.xcode.auth",
            "X-Xcode-Version": "11.2 (11B41)",
            "X-Apple-Identity-Token": encodedIdentityToken,
            "X-Apple-I-MD-M": anisetteData.machineID,
            "X-Apple-I-MD": anisetteData.oneTimePassword,
            "X-Apple-I-MD-LU": anisetteData.localUserID,
            "X-Apple-I-MD-RINFO": "\(anisetteData.routingInfo)",
            "X-Mme-Device-Id": anisetteData.deviceUniqueIdentifier,
            "X-MMe-Client-Info": anisetteData.deviceDescription,
            "X-Apple-I-Client-Time": dateFormatter.string(from: anisetteData.date),
            "X-Apple-Locale": anisetteData.locale.sanitizedIdentifier,
            "X-Apple-I-TimeZone": anisetteData.timeZone.abbreviation() ?? "PST"
        ]

        var request = URLRequest(url: url)
        httpHeaders.forEach { request.addValue($0.value, forHTTPHeaderField: $0.key) }

        if let userAgent = ALTAppleAPI.remoteAnisetteUserAgent {
            // Remote Anisette: isideload's 2FA header set — fresh anisette for this request,
            // the server's User-Agent, Xcode 27, and nothing that contradicts its client_info.
            let fresh = ALTAppleAPI.freshAnisette?() ?? anisetteData
            request.setValue(fresh.machineID, forHTTPHeaderField: "X-Apple-I-MD-M")
            request.setValue(fresh.oneTimePassword, forHTTPHeaderField: "X-Apple-I-MD")
            request.setValue("\(fresh.routingInfo)", forHTTPHeaderField: "X-Apple-I-MD-RINFO")
            request.setValue(fresh.deviceUniqueIdentifier, forHTTPHeaderField: "X-Mme-Device-Id")
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("27.0 (27A5218g)", forHTTPHeaderField: "X-Xcode-Version")
            request.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
            request.setValue("text/x-xml-plist", forHTTPHeaderField: "Accept")
            for key in ["X-Apple-I-MD-LU", "X-Apple-I-Client-Time", "X-Apple-Locale", "X-Apple-I-TimeZone", "Accept-Language"] {
                request.setValue(nil, forHTTPHeaderField: key)
            }
        }

        return request
    }
}

private extension ALTAppleAPI {
    func parsePlistOrJSON(_ data: Data) -> [String: Any]? {
        (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
            ?? (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
    }

    /// For decrypted auth payloads (session keys, tokens): report key names only, never values.
    func keyNames(_ dict: [String: Any]) -> String {
        "keys: " + dict.keys.sorted().joined(separator: ",")
    }

    func formatPayloadJSON(_ payload: Any) -> String {
        if JSONSerialization.isValidJSONObject(payload),
           let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
           let jsonString = String(data: data, encoding: .utf8) {
            return jsonString
        }
        if let data = payload as? Data {
            if let str = String(data: data, encoding: .utf8) {
                return formatPayloadString(str)
            }
            return data.hexEncodedString()
        }
        if let str = payload as? String {
            return formatPayloadString(str)
        }
        return "\(payload)"
    }

    private func formatPayloadString(_ str: String) -> String {
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<") {
            return prettyPrintXML(trimmed)
        }
        return trimmed
    }

    private func prettyPrintXML(_ rawXML: String) -> String {
        let pattern = "(<[^>]+>)|([^<]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return rawXML
        }

        let nsString = rawXML as NSString
        let matches = regex.matches(in: rawXML, options: [], range: NSRange(location: 0, length: nsString.length))

        var result: [String] = []
        var indentLevel = 0

        for match in matches {
            var token = nsString.substring(with: match.range).trimmingCharacters(in: .whitespacesAndNewlines)
            if token.isEmpty { continue }

            // Collapse internal newlines and multiple spaces inside XML tags
            if token.hasPrefix("<") && !token.hasPrefix("<![CDATA[") {
                token = token.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            }

            if token.hasPrefix("</") {
                indentLevel = max(0, indentLevel - 1)
                let indent = String(repeating: "  ", count: indentLevel)
                result.append("\(indent)\(token)")
            } else if token.hasPrefix("<?") || token.hasPrefix("<!") || token.hasSuffix("/>") {
                let indent = String(repeating: "  ", count: indentLevel)
                result.append("\(indent)\(token)")
            } else if token.hasPrefix("<") {
                let indent = String(repeating: "  ", count: indentLevel)
                result.append("\(indent)\(token)")
                indentLevel += 1
            } else {
                let baseIndent = String(repeating: "  ", count: indentLevel)
                let subLines = token.components(separatedBy: .newlines)
                var cssIndent = 0
                for subLine in subLines {
                    let subTrimmed = subLine.trimmingCharacters(in: .whitespaces)
                    if subTrimmed.isEmpty { continue }

                    if subTrimmed.hasPrefix("}") {
                        cssIndent = max(0, cssIndent - 1)
                    }

                    let extraIndent = String(repeating: "  ", count: cssIndent)
                    result.append("\(baseIndent)\(extraIndent)\(subTrimmed)")

                    if subTrimmed.hasSuffix("{") {
                        cssIndent += 1
                    }
                }
            }
        }

        return result.joined(separator: "\n")
    }
}

// MARK: - Data decryption helpers (used only within this file)

private extension Data {

    /* AES-CBC-PKCS7: key and IV derived from the SRP session via HMAC */
    func decryptedCBC(context: GSAContext) -> Data? {
        guard let key = context.makeHMACKey("extra data key:"),
              let iv  = context.makeHMACKey("extra data iv:")
        else { return nil }

        return CoreCryptoBridge.aesCBCDecrypt(key: key, iv: iv, ciphertext: self)
    }

    /* AES-GCM: layout is [3-byte version | 16-byte IV | ciphertext | 16-byte tag] */
    func decryptedGCM(context: GSAContext) -> Data? {
        guard let sessionKey = context.sessionKey else { return nil }

        let versionSize = 3   // version prefix — treated as AAD
        let ivSize      = 16  // nonce
        let tagSize     = 16  // GCM authentication tag

        guard self.count > versionSize + ivSize + tagSize else { return nil }

        let aad        = Data(self[..<versionSize])
        let nonce      = Data(self[versionSize ..< versionSize + ivSize])
        let ciphertext = Data(self[versionSize + ivSize ..< self.count - tagSize])
        let tag        = Data(self[(self.count - tagSize)...])

        return CoreCryptoBridge.aesGCMDecrypt(key: sessionKey, nonce: nonce, aad: aad, ciphertext: ciphertext, tag: tag)
    }
}
