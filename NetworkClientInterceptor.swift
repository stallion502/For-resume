//
//  NetworkClientInterceptor.swift
//  
//
//  Created by Максим Позднышев on 09.01.2023.
//

import Foundation
import Networking

actor NetworkClientInterceptor: Interceptor {
    private let webService: AuthorizationWebService
    private let tokenService: TokenService
    private let authorizationType: AuthorizationType
    private let stand: Stand
    
    init(
        webService: AuthorizationWebService,
        authorizationType: AuthorizationType,
        tokenService: TokenService,
        stand: Stand
    ) {
        self.webService = webService
        self.authorizationType = authorizationType
        self.tokenService = tokenService
        self.stand = stand
    }
    
    func prepare(_ request: inout URLRequest, useOwnToken: Bool, useJWTToken: Bool) async throws {
        guard let token = try? tokenService.fetch(), useJWTToken else { return }
        let auth = ExtraToken(token: token, stand: stand, ownToken: useOwnToken)
        request.setValue(auth.value, forHTTPHeaderField: auth.key)
    }
    
    func shouldRetry(_ request: URLRequest, for response: inout URLResponse) async throws -> RetryAction {
        let httpResponse = response as? HTTPURLResponse
        if httpResponse?.statusCode == ResponseStatusCode.unauthorized, authorizationType != .dev {
            let refreshToken = try tokenService.fetch().refreshToken
            let tokenRequest = EPAAuthTokensRequest(
                token: EPAAuthTokensRequest.Token.refreshToken(refreshToken),
                stand: stand
            )
            do {
                let token = try await webService.refreshToken(request: tokenRequest)
                try tokenService.store(token)
                return .retry
            } catch {
                NotificationCenter.default.post(name: GlobalNotifications.userDidLogout, object: nil)
            }
        }
        
        return .doNotRetry
    }
}
 
