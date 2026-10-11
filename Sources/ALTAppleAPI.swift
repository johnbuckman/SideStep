//
//  ALTAppleAPI.swift
//  AltSign
//
//  Direct Swift port of ALTAppleAPI.m
//

import Foundation
import SwiftBridge

// MARK: ALTAppleAPISession

public final class ALTAppleAPISession: NSObject {

    public var dsid: String
    public var authToken: String
    public var anisetteData: ALTAnisetteData

    public init(
        dsid: String,
        authToken: String,
        anisetteData: ALTAnisetteData
    ) {
        self.dsid = dsid
        self.authToken = authToken
        self.anisetteData = anisetteData
        super.init()
    }
}

// MARK: - ALTAppleAPI

public final class ALTAppleAPI: NSObject {

    // MARK: Constants

    let ALTAuthenticationProtocolVersion = "A1234"
    let ALTProtocolVersion = "QH65B2"
    let ALTAppIDKey = "ba2ec180e6ca6e6c6a542255453b24d6e6e5b2be0cc48bc1b0d8ad64cfe0228f"
    let ALTClientID = "XABBG36SBA"

    // MARK: Singleton

    public static let sharedAPI = ALTAppleAPI()

    /// When true, accounts that would push the 2FA code to trusted *devices*
    /// (`trustedDeviceSecondaryAuth`) instead receive it by SMS to the trusted
    /// phone number. Needed for dedicated Apple IDs with no signed-in device.
    public static var preferSMSTwoFactorCode = false

    /// Supplies fresh Anisette data (new one-time password and client time) for the
    /// 2FA requests and the sign-in retry after a verified code. Nil: reuse the original.
    public static var freshAnisette: (() -> ALTAnisetteData?)?

    /// The remote Anisette server's User-Agent when its (virtual-machine) Anisette is in
    /// use; switches GSA/2FA requests to isideload's header set. Nil for local Anisette.
    public static var remoteAnisetteUserAgent: String?



    // MARK: Private State

    let session: URLSession
    let dateFormatter: ISO8601DateFormatter
    public let baseURL: URL
    public let servicesBaseURL: URL

    private override init() {
        NSError.registerErrorProviders()
        session = URLSession(configuration: .ephemeral)
        dateFormatter = ISO8601DateFormatter()
        baseURL = URL(
            string: "https://developerservices2.apple.com/services/\(ALTProtocolVersion)/"
        )!
        servicesBaseURL = URL(
            string: "https://developerservices2.apple.com/services/v1/"
        )!
        super.init()
    }
}

// MARK: - Response Processing

extension ALTAppleAPI {

    func processResponse(
        _ responseDictionary: [String: Any],
        parseHandler: (() -> Any?)?,
        resultCodeHandler: ((Int) -> Error?)?,
        error: inout Error?
    ) -> Any? {

        if let parseHandler, let value = parseHandler() {
            return value
        }

        guard let result = responseDictionary["resultCode"] else {
            if let errors = responseDictionary["errors"] as? [[String: Any]],
               let firstError = errors.first,
               let detail = firstError["detail"] as? String {
                error = NSError(
                    domain: ALTAppleAPIErrorDomain,
                    code: ALTAppleAPIError.unknown.rawValue,
                    userInfo: [
                        NSLocalizedDescriptionKey: detail
                    ]
                )
                debugLog("[AltSign] processResponse parsed Apple developer API error: \(detail)")
            } else {
                let jsonPayload = prettyJSONString(from: responseDictionary)
                error = ALTServerError.missingKey(key: "resultCode", jsonPayload: jsonPayload)
                debugLog("[AltSign] processResponse error: missing resultCode in payload:\n\(jsonPayload)")
            }
            return nil
        }

        let resultCode =
            (result as? NSNumber)?.intValue ??
            Int("\(result)") ?? -1

        if resultCode == 0 { return nil }

        var tempError = resultCodeHandler?(resultCode)

        if tempError == nil {

            let desc = (responseDictionary["userString"] ?? responseDictionary["resultString"]) as? String
            let localizedDescription: String
            if let desc, !desc.isEmpty {
                localizedDescription = "\(desc) (\(resultCode))"
            } else {
                localizedDescription = "Apple Developer API error (\(resultCode))"
            }

            tempError = NSError(
                domain: ALTUnderlyingAppleAPIErrorDomain,
                code: resultCode,
                userInfo: [
                    NSLocalizedDescriptionKey: localizedDescription
                ]
            )
        }

        error = tempError
        debugLog("[AltSign] processResponse error: \(tempError?.localizedDescription ?? "unknown error") (code: \(resultCode))")
        return nil
    }
}

// MARK: - Requests (plist endpoints)

extension ALTAppleAPI {

    func sendRequest(
        url requestURL: URL,
        additionalParameters: [String: String]?,
        session apiSession: ALTAppleAPISession,
        team: ALTTeam?,
        completionHandler: @escaping ([String: Any]?, Error?) -> Void
    ) {

        var parameters: [String: String] = [
            "clientId": ALTClientID,
            "protocolVersion": ALTProtocolVersion,
            "requestId": UUID().uuidString.uppercased()
        ]

        if let team {
            parameters["teamId"] = team.identifier
        }

        additionalParameters?.forEach { parameters[$0] = $1 }

        let bodyData: Data
        do {
            bodyData = try PropertyListSerialization.data(
                fromPropertyList: parameters,
                format: .xml,
                options: 0
            )
        } catch {
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

        verboseLog("[AltSign] sendRequest to: \(url.absoluteString)")
        verboseLog("[AltSign] sendRequest parameters: \(parameters)")

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
            "X-Apple-Locale": a.locale.identifier,
            "X-Apple-I-Locale": a.locale.identifier,
            "X-Apple-I-TimeZone": a.timeZone.abbreviation(for: a.date) ?? ""        ]

        headers.forEach {
            request.setValue($1, forHTTPHeaderField: $0)
        }

        session.dataTask(with: request) { data, _, error in
            if let error {
                verboseLog("[AltSign] sendRequest failed with error: \(error)")
            }
            guard let data, !data.isEmpty else {
                let err = error ?? ALTServerError.badServerResponse(reason: "Server returned empty response (Content-Length: 0) — session may have timed out", jsonPayload: "0 bytes")
                verboseLog("[AltSign] sendRequest server returned 0 bytes / empty response")
                completionHandler(nil, err)
                return
            }

            let parsedObj: Any? = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil))
                ?? (try? JSONSerialization.jsonObject(with: data, options: []))

            if let plist = parsedObj as? [String: Any] {
                verboseLog("[AltSign] sendRequest response: \(prettyJSONString(from: plist))")
                completionHandler(plist, nil)
            } else if let parsedObj {
                verboseLog("[AltSign] sendRequest response non-dictionary payload: \(prettyJSONString(from: parsedObj))")
                completionHandler(["result": parsedObj, "resultCode": 0], nil)
            } else {
                let rawStr = String(data: data, encoding: .utf8) ?? data.hexEncodedString()
                verboseLog("[AltSign] sendRequest failed to parse response plist/json. Raw: \(rawStr)")
                completionHandler(nil, ALTServerError.invalidResponseFormat(rawPayload: rawStr))
            }
        }.resume()
    }
}

// MARK: - Services Requests (JSON endpoints)

extension ALTAppleAPI {

    func sendServicesRequest(
        _ originalRequest: URLRequest,
        additionalParameters: [String: String]?,
        session apiSession: ALTAppleAPISession,
        team: ALTTeam,
        includeAnisette: Bool = true,
        completionHandler: @escaping ([String: Any]?, Error?) -> Void
    ) {

        var request = originalRequest

        var items = [
            URLQueryItem(name: "teamId", value: team.identifier)
        ]

        additionalParameters?.forEach {
            items.append(.init(name: $0, value: $1))
        }

        var comps = URLComponents()
        comps.queryItems = items
        let query = comps.query ?? ""

        verboseLog("[AltSign] sendServicesRequest to: \(request.url?.absoluteString ?? "unknown URL")")
        verboseLog("[AltSign] sendServicesRequest parameters: \(additionalParameters ?? [:])")

        let bodyData: Data
        do {
            bodyData = try JSONSerialization.data(
                withJSONObject: ["urlEncodedQueryParams": query]
            )
        } catch {
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

        let methodOverride = request.httpMethod
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue(
            methodOverride,
            forHTTPHeaderField: "X-HTTP-Method-Override"
        )

        var headers: [String: String] = [
            "Content-Type": "application/vnd.api+json",
            "User-Agent": "Xcode",
            "Accept": "application/vnd.api+json",
            "Accept-Language": "en-us",
            "X-Apple-App-Info": "com.apple.gs.xcode.auth",
            "X-Xcode-Version": "11.2 (11B41)",
            "X-Apple-I-Identity-Id": apiSession.dsid,
            "X-Apple-GS-Token": apiSession.authToken
        ]

        if includeAnisette {
            let a = apiSession.anisetteData
            headers["X-Apple-I-MD-M"] = a.machineID
            headers["X-Apple-I-MD"] = a.oneTimePassword
            headers["X-Apple-I-MD-LU"] = a.localUserID
            headers["X-Apple-I-MD-RINFO"] = "\(a.routingInfo)"
            headers["X-Mme-Device-Id"] = a.deviceUniqueIdentifier
            headers["X-MMe-Client-Info"] = a.deviceDescription
            headers["X-Apple-I-Client-Time"] = dateFormatter.string(from: a.date)
            headers["X-Apple-Locale"] = a.locale.identifier
            headers["X-Apple-I-TimeZone"] = a.timeZone.abbreviation(for: a.date) ?? ""
        }

        headers.forEach {
            request.setValue($1, forHTTPHeaderField: $0)
        }

        session.dataTask(with: request) { data, response, error in
            if let error {
                verboseLog("[AltSign] sendServicesRequest failed with error: \(error)")
            }
            
            let httpResponse = response as? HTTPURLResponse
            let isDelete = methodOverride == "DELETE" || request.httpMethod == "DELETE"
            let isNoContent = httpResponse?.statusCode == 204
            
            guard let data, !data.isEmpty else {
                if (isDelete || isNoContent) && error == nil {
                    verboseLog("[AltSign] sendServicesRequest: successful empty response for DELETE or 204")
                    completionHandler([:], nil)
                } else {
                    let err = error ?? ALTServerError.badServerResponse(reason: "Server returned empty response (Content-Length: 0) — session may have timed out", jsonPayload: "0 bytes")
                    verboseLog("[AltSign] sendServicesRequest server returned 0 bytes / empty response")
                    completionHandler(nil, err)
                }
                return
            }

            do {
                let json = try JSONSerialization.jsonObject(with: data)
                if let dict = json as? [String: Any] {
                    verboseLog("[AltSign] sendServicesRequest response: \(prettyJSONString(from: dict))")
                    completionHandler(dict, nil)
                } else {
                    verboseLog("[AltSign] sendServicesRequest response non-dictionary JSON: \(prettyJSONString(from: json))")
                    completionHandler(["result": json, "resultCode": 0], nil)
                }
            } catch {
                let rawStr = String(data: data, encoding: .utf8) ?? data.hexEncodedString()
                verboseLog("[AltSign] sendServicesRequest failed to parse response JSON. Raw: \(rawStr)")
                completionHandler(nil, ALTServerError.invalidResponseFormat(rawPayload: rawStr))
            }
        }.resume()
    }
}

// MARK: - JSON Formatting Helpers

fileprivate func prettyJSONString(from object: Any) -> String {
    let sanitized = sanitizeForJSON(object)
    if JSONSerialization.isValidJSONObject(sanitized) {
        do {
            let data = try JSONSerialization.data(withJSONObject: sanitized, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            if let string = String(data: data, encoding: .utf8) {
                return string
            }
        } catch {}
    }
    return "\(object)"
}

fileprivate func sanitizeForJSON(_ object: Any) -> Any {
    if let dict = object as? [String: Any] {
        return dict.mapValues { sanitizeForJSON($0) }
    } else if let array = object as? [Any] {
        return array.map { sanitizeForJSON($0) }
    } else if let date = object as? Date {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: date)
    } else if let data = object as? Data {
        return data.base64EncodedString()
    } else if let number = object as? NSNumber {
        return number
    } else if let string = object as? String {
        return string
    } else {
        return "\(object)"
    }
}
