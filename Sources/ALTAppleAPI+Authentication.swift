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
        // Authenticating only works with lowercase email address, even if Apple ID contains capital letters.
        let sanitizedAppleID = unsanitizedAppleID.lowercased()

        debugLog("[AltSign] Starting authenticate for Apple ID: \(sanitizedAppleID)")

        do {
            let clientDictionary = [
                // Reduced to the fields (as strings) that clients which currently sign in send (AltSign PR #61).
                "bootstrap": "true",
                "icscrec": "true",
                "pbe": "false",
                "prkgen": "true",
                "svct": "iCloud",
                "loc": "en_US",
                "X-Apple-I-MD": anisetteData.oneTimePassword,
                "X-Apple-I-MD-M": anisetteData.machineID,
                "X-Mme-Device-Id": anisetteData.deviceUniqueIdentifier
            ] as [String: Any]

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

                    // GrandSlam hsc 434: anisette out of sync. Resynchronize once with Apple's
                    // X-Apple-I-MD-DATA and start over (AltSign PR #61 / AltStore 22f766d).
                    if let st = responseDictionary["Status"] as? [String: Any], st["hsc"] as? Int == 434 {
                        let raw = st["X-Apple-I-MD-DATA"] ?? responseDictionary["X-Apple-I-MD-DATA"]
                        let sim = (raw as? String) ?? (raw as? Data)?.base64EncodedString()
                        print("[SideStep auth] hsc 434 — anisette out of sync, sim present: \(sim?.isEmpty == false)")
                        guard let resync = ALTAppleAPI.anisetteResyncHandler, let sim, !sim.isEmpty,
                              ALTAppleAPI.beginResynchronizing() else { throw ALTAppleAPIError.invalidAnisetteData }
                        resync(sim) { data, error in
                            guard let data else {
                                ALTAppleAPI.isResynchronizing = false
                                return completionHandler(nil, nil, error ?? ALTAppleAPIError.invalidAnisetteData)
                            }
                            self.authenticate(appleID: unsanitizedAppleID, password: password, anisetteData: data,
                                              verificationHandler: verificationHandler) { account, session, error in
                                // Observed on macOS 27 / ani.jkcoxson.com: after a resync, init succeeds but
                                // "complete" gets HTTP 503; a fresh (non-resync) attempt a few seconds later
                                // succeeds. So retry once that way.
                                guard let e = error as NSError?, e.domain == ALTAppleAPI.gsaHTTPErrorDomain, e.code == 503 else {
                                    ALTAppleAPI.isResynchronizing = false
                                    return completionHandler(account, session, error)
                                }
                                self.reauthenticateAfterStep("resync", appleID: unsanitizedAppleID, password: password,
                                                             fallback: data, verificationHandler: verificationHandler, attempt: 1) { account, session, error in
                                    ALTAppleAPI.isResynchronizing = false
                                    completionHandler(account, session, error)
                                }
                            }
                        }
                        return
                    }

                    guard let c = responseDictionary["c"] as? String,
                          let salt = responseDictionary["s"] as? Data,
                          let iterations = responseDictionary["i"] as? Int,
                          let serverPublicKey = responseDictionary["B"] as? Data
                    else {
                        verboseLog("[AltSign] Failed to parse authentication init response dictionary: \(responseDictionary)")
                        throw URLError(.badServerResponse)
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
                                throw URLError(.badServerResponse)
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

                            guard let decryptedDictionary = try PropertyListSerialization.propertyList(from: decryptedData, format: nil) as? [String: Any],
                                  let dsid = decryptedDictionary["adsid"] as? String,
                                  let idmsToken = decryptedDictionary["GsIdmsToken"] as? String
                            else {
                                verboseLog("[AltSign] Decrypted plist format is invalid or missing adsid/GsIdmsToken: \(decryptedData)")
                                throw URLError(.badServerResponse)
                            }

                            verboseLog("[AltSign] Parse complete. dsid: \(dsid), token: \(idmsToken)")
                            context.dsid = dsid

                            var authType = statusDictionary["au"] as? String
                            // Since 2026-10-12 a sign-in with (Android) server anisette answers
                            // hsc 409 = "two-factor required" WITHOUT an "au" mode: Apple has
                            // already pushed the code to the account's trusted devices, so only
                            // the validate step is needed (SMS is refused for Android anisette).
                            // Same handling as xtool/xcross.
                            let codeAlreadyPushed = authType == nil && (statusDictionary["hsc"] as? Int) == 409
                            if codeAlreadyPushed { authType = "trustedDeviceSecondaryAuth" }
                            verboseLog("[AltSign] Authentication status type: \(authType ?? "nil")\(codeAlreadyPushed ? " (hsc 409, code already pushed)" : "")")

                            switch authType {
                            case "trustedDeviceSecondaryAuth":
                                guard let verificationHandler = verificationHandler else { throw ALTAppleAPIError.requiresTwoFactorAuthentication }

                                if ALTAppleAPI.preferSMSTwoFactorCode {
                                    // Account has no signed-in Apple device: deliver the code by SMS instead.
                                    self.requestSMSTwoFactorCode(dsid: dsid, idmsToken: idmsToken, anisetteData: anisetteData, verificationHandler: verificationHandler) { result in
                                        switch result {
                                        case let .failure(error): completionHandler(nil, nil, error)
                                        case .success:
                                            self.reauthenticateAfterStep("2FA", appleID: unsanitizedAppleID, password: password, fallback: anisetteData, verificationHandler: verificationHandler, completionHandler: completionHandler)
                                        }
                                    }
                                } else {
                                    self.requestTrustedDeviceTwoFactorCode(dsid: dsid, idmsToken: idmsToken, anisetteData: anisetteData, codeAlreadySent: codeAlreadyPushed, verificationHandler: verificationHandler) { result in
                                        switch result {
                                        case let .failure(error): completionHandler(nil, nil, error)
                                        case .success:
                                            self.reauthenticateAfterStep("2FA", appleID: unsanitizedAppleID, password: password, fallback: anisetteData, verificationHandler: verificationHandler, completionHandler: completionHandler)
                                        }
                                    }
                                }

                            case "secondaryAuth":
                                guard let verificationHandler = verificationHandler else { throw ALTAppleAPIError.requiresTwoFactorAuthentication }

                                self.requestSMSTwoFactorCode(dsid: dsid, idmsToken: idmsToken, anisetteData: anisetteData, verificationHandler: verificationHandler) { result in
                                    switch result {
                                    case let .failure(error): completionHandler(nil, nil, error)
                                    case .success:
                                        self.reauthenticateAfterStep("2FA", appleID: unsanitizedAppleID, password: password, fallback: anisetteData, verificationHandler: verificationHandler, completionHandler: completionHandler)
                                    }
                                }

                            default:
                                guard let sessionKey = decryptedDictionary["sk"] as? Data,
                                      let c = decryptedDictionary["c"] as? Data
                                else { throw URLError(.badServerResponse) }

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

                guard let encryptedToken = responseDictionary["et"] as? Data else { throw URLError(.badServerResponse) }
                guard let token = encryptedToken.decryptedGCM(context: context) else { throw ALTAppleAPIError.authenticationHandshakeFailed }

                guard let tokensDictionary = try PropertyListSerialization.propertyList(from: token, format: nil) as? [String: Any] else {
                    throw URLError(.badServerResponse)
                }

                guard let appTokens = tokensDictionary["t"] as? [String: Any],
                      let tokens = appTokens[app] as? [String: Any],
                      let authToken = tokens["token"] as? String
                else { throw URLError(.badServerResponse) }

                completionHandler(.success(authToken))
            } catch {
                completionHandler(.failure(error))
            }
        }
    }

    func requestTrustedDeviceTwoFactorCode(dsid: String,
                                           idmsToken: String,
                                           anisetteData: ALTAnisetteData,
                                           codeAlreadySent: Bool = false,
                                           verificationHandler: @escaping (@escaping (String?) -> Void) -> Void,
                                           completionHandler: @escaping (Result<Void, Error>) -> Void) {
        verboseLog("[AltSign] requestTrustedDeviceTwoFactorCode starting for dsid: \(dsid)\(codeAlreadySent ? " (code already pushed — validate only)" : "")")
        let requestURL = URL(string: "https://gsa.apple.com/auth/verify/trusteddevice")!
        let verifyURL = URL(string: "https://gsa.apple.com/grandslam/GsService2/validate")!

        let request = makeTwoFactorCodeRequest(url: requestURL, dsid: dsid, idmsToken: idmsToken, anisetteData: anisetteData)

        let afterRequest: (Data?, URLResponse?, Error?) -> Void = { data, _, error in
            if let error {
                verboseLog("[AltSign] requestTrustedDeviceTwoFactorCode request code task failed: \(error)")
            } else {
                verboseLog("[AltSign] requestTrustedDeviceTwoFactorCode request code task succeeded")
                print("[SideStep auth] 2FA code requested (trusted device)")
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
                        let verifyCodeTask = ALTAppleAPI.gsaDataTask(with: request) { (data, response, error) in
                            do
                            {
                                if let error {
                                    verboseLog("[AltSign] requestTrustedDeviceTwoFactorCode verification failed with error: \(error)")
                                }
                                guard let data = data else { throw error ?? ALTAppleAPIError.unknown }

                                guard let responseDictionary = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                                    verboseLog("[AltSign] requestTrustedDeviceTwoFactorCode verify response plist is invalid")
                                    throw URLError(.badServerResponse)
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

        if codeAlreadySent { afterRequest(nil, nil, nil) }
        else { session.dataTask(with: request, completionHandler: afterRequest).resume() }
    }

    func requestSMSTwoFactorCode(dsid: String,
                                 idmsToken: String,
                                 anisetteData: ALTAnisetteData,
                                 verificationHandler: @escaping (@escaping (String?) -> Void) -> Void,
                                 completionHandler: @escaping (Result<Void, Error>) -> Void) {
        verboseLog("[AltSign] requestSMSTwoFactorCode starting for dsid: \(dsid)")
        let requestURL = URL(string: "https://gsa.apple.com/auth/verify/phone/put?mode=sms")!
        let verifyURL = URL(string: "https://gsa.apple.com/auth/verify/phone/securitycode?referrer=/auth/verify/phone/put")!

        var request = makeTwoFactorCodeRequest(url: requestURL, dsid: dsid, idmsToken: idmsToken, anisetteData: anisetteData)
        request.httpMethod = "POST"

        do {
            let bodyXML = [
                "serverInfo": [
                    "phoneNumber.id": "1"
                ]
            ] as [String: Any]

            let bodyData = try PropertyListSerialization.data(fromPropertyList: bodyXML, format: .xml, options: 0)
            request.httpBody = bodyData
        } catch {
            verboseLog("[AltSign] requestSMSTwoFactorCode serialization failed: \(error)")
            completionHandler(.failure(error))
            return
        }

        let requestCodeTask = ALTAppleAPI.gsaDataTask(with: request) { _, response, error in
            if let error {
                verboseLog("[AltSign] requestSMSTwoFactorCode request code task failed: \(error)")
            } else {
                verboseLog("[AltSign] requestSMSTwoFactorCode request code task succeeded")
            }
            do {
                guard error == nil else { throw error! }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                verboseLog("[AltSign] requestSMSTwoFactorCode HTTP \(status)")
                // Since 2026-10-12 Apple refuses SMS two-factor (HTTP 403) for sign-ins made
                // with Android anisette (= any anisette server); only a trusted-device push works.
                if status == 403 {
                    throw NSError(domain: ALTUnderlyingAppleAPIErrorDomain, code: 403, userInfo: [NSLocalizedDescriptionKey:
                        "Apple refused to text a verification code (HTTP 403). Apple doesn’t allow texted codes when the sign-in data comes from an anisette server — sign this Apple ID in on an iPhone, iPad or Mac so the code can be sent there instead."])
                }

                func responseHandler(verificationCode: String?) {
                    verboseLog("[AltSign] requestSMSTwoFactorCode received code from user. Has code: \(verificationCode != nil)")
                    do {
                        guard let verificationCode = verificationCode else { throw ALTAppleAPIError.requiresTwoFactorAuthentication }

                        var request = self.makeTwoFactorCodeRequest(url: verifyURL, dsid: dsid, idmsToken: idmsToken, anisetteData: anisetteData)
                        request.httpMethod = "POST"

                        let bodyXML = [
                            "securityCode.code": verificationCode,
                            "serverInfo": [
                                "mode": "sms",
                                "phoneNumber.id": "1"
                            ]
                        ] as [String: Any]

                        let bodyData = try PropertyListSerialization.data(fromPropertyList: bodyXML, format: .xml, options: 0)
                        request.httpBody = bodyData

                        verboseLog("[AltSign] requestSMSTwoFactorCode verifying code...")
                        let verifyCodeTask = ALTAppleAPI.gsaDataTask(with: request) { _, response, error in
                            do {
                                if let error {
                                    verboseLog("[AltSign] requestSMSTwoFactorCode verification failed: \(error)")
                                }
                                guard error == nil else { throw error! }

                                guard let httpResponse = response as? HTTPURLResponse,
                                      httpResponse.statusCode == 200,
                                      httpResponse.allHeaderFields.keys.contains("X-Apple-PE-Token") // PE token is included in headers if we sent correct verification code.
                                else {
                                    verboseLog("[AltSign] requestSMSTwoFactorCode verification failed (invalid status code or missing PE token)")
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
    func sendAuthenticationRequest(parameters requestParameters: [String: Any], anisetteData: ALTAnisetteData, completionHandler: @escaping (Result<[String: Any], Error>) -> Void) {
        do {
            let requestURL = URL(string: "https://gsa.apple.com/grandslam/GsService2")!

            let parameters = [
                "Header": ["Version": "1.0.1"],
                "Request": requestParameters
            ]

            verboseLog("[AltSign] sendAuthenticationRequest payload: \(parameters)")
            print("[SideStep auth] GsService2 o=\(requestParameters["o"] ?? "?")\(ALTAppleAPI.isResynchronizing ? " (after resync)" : "")")

            let httpHeaders = [
                "Content-Type": "text/x-xml-plist",
                "X-MMe-Client-Info": anisetteData.deviceDescription,
                "Accept": "text/x-xml-plist",
                "X-Xcode-Version": ALTAppleAPI.gsaXcodeVersion,
                "X-Apple-App-Info": "com.apple.gs.xcode.auth",
                "Connection": "close",
                "User-Agent": ALTAppleAPI.gsaUserAgent
            ]

            let bodyData = try PropertyListSerialization.data(fromPropertyList: parameters, format: .xml, options: 0)

            var request = URLRequest(url: requestURL)
            request.httpMethod = "POST"
            request.httpBody = bodyData
            httpHeaders.forEach { request.addValue($0.value, forHTTPHeaderField: $0.key) }

            let dataTask = ALTAppleAPI.gsaDataTask(with: request) { (data, response, error) in
                do
                {
                    if let error {
                        verboseLog("[AltSign] sendAuthenticationRequest failed with error: \(error)")
                    }
                    guard let data = data else { throw error ?? ALTAppleAPIError.unknown }

                    // Apple answers non-200 with an HTML page; report the status instead of a plist parse error (3840).
                    let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? -1
                    print("[SideStep auth] GsService2 o=\(requestParameters["o"] ?? "?") → HTTP \(httpStatus)")
                    if httpStatus != 200 {
                        print("[SideStep auth] GsService2 answered HTTP \(httpStatus) (\(data.count) bytes)")
                        throw NSError(domain: ALTAppleAPI.gsaHTTPErrorDomain, code: httpStatus,
                                      userInfo: [NSLocalizedDescriptionKey: "Apple’s sign-in server answered HTTP \(httpStatus). Please try again in a moment."])
                    }

                    guard let responseDictionary = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                          let dictionary = responseDictionary["Response"] as? [String: Any],
                          let status = dictionary["Status"] as? [String: Any]
                    else {
                        verboseLog("[AltSign] sendAuthenticationRequest response is invalid or could not be parsed: \(String(data: data, encoding: .utf8) ?? "unable to decode")")
                        throw URLError(.badServerResponse)
                    }

                    verboseLog("[AltSign] sendAuthenticationRequest response Status: \(status)")
                    verboseLog("[AltSign] sendAuthenticationRequest response Data: \(dictionary)")

                    // hsc 434 = anisette out of sync: handed back to authenticate(), which resyncs once.
                    if status["hsc"] as? Int == 434 { return completionHandler(.success(dictionary)) }

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

    func makeTwoFactorCodeRequest(url: URL,
                                  dsid: String,
                                  idmsToken: String,
                                  anisetteData: ALTAnisetteData) -> URLRequest {
        let identityToken = dsid + ":" + idmsToken

        let identityTokenData = identityToken.data(using: .utf8)!
        let encodedIdentityToken = identityTokenData.base64EncodedString()

        let httpHeaders = [
            "Accept": "text/x-xml-plist",
            "Accept-Language": "en-us",
            "Content-Type": "text/x-xml-plist",
            "Connection": "close",
            "User-Agent": ALTAppleAPI.gsaUserAgent,
            "X-Apple-App-Info": "com.apple.gs.xcode.auth",
            "X-Xcode-Version": ALTAppleAPI.gsaXcodeVersion,
            "X-Apple-Identity-Token": encodedIdentityToken,
            "X-Apple-I-MD-M": anisetteData.machineID,
            "X-Apple-I-MD": anisetteData.oneTimePassword,
            "X-Apple-I-MD-LU": anisetteData.localUserID,
            "X-Apple-I-MD-RINFO": "\(anisetteData.routingInfo)",
            "X-Mme-Device-Id": anisetteData.deviceUniqueIdentifier,
            "X-MMe-Client-Info": anisetteData.deviceDescription,
            "X-Apple-I-Client-Time": dateFormatter.string(from: anisetteData.date),
            "X-Apple-Locale": anisetteData.locale.identifier,
            "X-Apple-I-TimeZone": anisetteData.timeZone.abbreviation() ?? "PST"
        ]

        var request = URLRequest(url: url)
        httpHeaders.forEach { request.addValue($0.value, forHTTPHeaderField: $0.key) }

        return request
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


// Apple's GSA edge answers HTTP 503 to the 3rd+ request on a reused keep-alive connection
// (AltStore issue #1782, AltSign PR #52). Give every gsa.apple.com request its own session.
extension ALTAppleAPI {
    /// User-Agent for GrandSlam (gsa.apple.com) requests. Must match the client that generated the
    /// anisette (anisette-v3 servers report it in /v3/client_info); set by SideloaderKit's Anisette.
    public static var authenticationUserAgent: String? {
        get { gsaStateLock.withLock { _authenticationUserAgent } }
        set { gsaStateLock.withLock { _authenticationUserAgent = newValue } }
    }
    static var gsaUserAgent: String { authenticationUserAgent ?? "akd/1.0 CFNetwork/808.1.4" }
    /// X-Xcode-Version for GrandSlam requests: a released Xcode build (26.6), not a beta string.
    static let gsaXcodeVersion = "26.6 (17F113)"

    // This shared sign-in state is set by SideloaderKit and read from URLSession callback
    // threads; one lock guards all of it so concurrent sign-ins can't race on it.
    private static let gsaStateLock = NSLock()
    private static var _authenticationUserAgent: String?
    private static var _anisetteResyncHandler: ((String, @escaping (ALTAnisetteData?, Error?) -> Void) -> Void)?
    private static var _anisetteRefreshHandler: ((@escaping (ALTAnisetteData?, Error?) -> Void) -> Void)?
    private static var _isResynchronizing = false

    /// Called once when GrandSlam answers hsc 434 (anisette out of sync) with X-Apple-I-MD-DATA;
    /// must return resynchronized anisette. Set by SideloaderKit's Anisette (server path).
    public static var anisetteResyncHandler: ((String, @escaping (ALTAnisetteData?, Error?) -> Void) -> Void)? {
        get { gsaStateLock.withLock { _anisetteResyncHandler } }
        set { gsaStateLock.withLock { _anisetteResyncHandler = newValue } }
    }
    /// Atomically claims the single resync slot; false if a resync is already in progress.
    static func beginResynchronizing() -> Bool {
        gsaStateLock.withLock { if _isResynchronizing { return false }; _isResynchronizing = true; return true }
    }
    static var isResynchronizing: Bool {
        get { gsaStateLock.withLock { _isResynchronizing } }
        set { gsaStateLock.withLock { _isResynchronizing = newValue } }
    }

    /// Returns fresh anisette from the current provider (each GrandSlam step after the first
    /// sign-in should use fresh anisette, as AltSign's anisetteDataRefreshHandler does).
    public static var anisetteRefreshHandler: ((@escaping (ALTAnisetteData?, Error?) -> Void) -> Void)? {
        get { gsaStateLock.withLock { _anisetteRefreshHandler } }
        set { gsaStateLock.withLock { _anisetteRefreshHandler = newValue } }
    }
    static let gsaHTTPErrorDomain = "SideStep.GrandSlamHTTP"

    /// The sign-in that follows a resync or a 2FA validation. Apple's GSA edge sometimes answers
    /// it with HTTP 503 (mc-k, macOS 27 / ani.jkcoxson.com: "a second attempt works"), so on 503
    /// retry with fresh anisette, up to twice, after 3 s and then 6 s. Other errors pass through.
    func reauthenticateAfterStep(_ step: String, appleID: String, password: String, fallback: ALTAnisetteData,
                                 verificationHandler: ((@escaping (String?) -> Void) -> Void)?, attempt: Int = 1,
                                 completionHandler: @escaping (ALTAccount?, ALTAppleAPISession?, Error?) -> Void) {
        ALTAppleAPI.withFreshAnisette(fallback: fallback) { fresh in
            self.authenticate(appleID: appleID, password: password, anisetteData: fresh,
                              verificationHandler: verificationHandler) { account, session, error in
                guard let e = error as NSError?, e.domain == ALTAppleAPI.gsaHTTPErrorDomain, e.code == 503, attempt <= 2 else {
                    return completionHandler(account, session, error)
                }
                let delay = 3.0 * Double(attempt)
                print("[SideStep auth] HTTP 503 after \(step) — retrying with fresh anisette in \(Int(delay)) s (\(attempt)/2)")
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                    self.reauthenticateAfterStep(step, appleID: appleID, password: password, fallback: fresh,
                                                 verificationHandler: verificationHandler, attempt: attempt + 1,
                                                 completionHandler: completionHandler)
                }
            }
        }
    }

    static func withFreshAnisette(fallback: ALTAnisetteData, _ body: @escaping (ALTAnisetteData) -> Void) {
        guard let refresh = anisetteRefreshHandler else { return body(fallback) }
        refresh { data, error in
            if let error { print("[SideStep auth] anisette refresh failed (\(error.localizedDescription)) — using previous data") }
            body(data ?? fallback)
        }
    }

    static func gsaDataTask(with request: URLRequest,
                            completionHandler: @escaping (Data?, URLResponse?, Error?) -> Void) -> URLSessionDataTask {
        let oneShot = URLSession(configuration: .ephemeral)
        return oneShot.dataTask(with: request) { data, response, error in
            completionHandler(data, response, error)
            oneShot.finishTasksAndInvalidate()
        }
    }
}
