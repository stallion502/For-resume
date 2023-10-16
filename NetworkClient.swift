//
//  NetworkClient.swift
//  
//
//  Created by Максим Позднышев on 09.01.2023.
//

import Foundation

public final class NetworkClient: NetworkClientProtocol {
    private let configuration: NetworkClientConfiguration
    private let urlSession: URLSession
    private let loggingDelegate: NetworkClientLoggingDelegate?
    
    private var interceptors: [Interceptor] = []
        
    public init(
        configuration: NetworkClientConfiguration,
        loggingDelegate: NetworkClientLoggingDelegate?
    ) {
        var sessionDelegate: URLSessionDelegate?
        if configuration.allowUntrustedConnection {
            sessionDelegate = UntrustedConnectionSessionDelegate()
        }
        
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        self.urlSession = URLSession(
            configuration: URLSessionConfiguration.default,
            delegate: sessionDelegate,
            delegateQueue: nil
        )
        self.configuration = configuration
        self.loggingDelegate = loggingDelegate
    }
    
    public func applyInterceptors(_ interceptors: [Interceptor]) {
        self.interceptors = interceptors
    }
    
    public func perform(_ request: Request) async throws -> TypedResponse<Data> {
        try await _perform(request)
    }
    
    private func _perform(_ request: Request) async throws -> TypedResponse<Data> {
        guard var urlRequest = createURLRequest(for: request) else {
            throw NetworkClientError.failedСreateRequest
        }
  
        try Task.checkCancellation()

        for interceptor in interceptors {
            try await interceptor.prepare(&urlRequest, useOwnToken: request.useOwnToken, useJWTToken: request.useJWTToken)
        }

        try Task.checkCancellation()
        
        do {
            var (data, urlResponse) = try await urlSession.data(for: urlRequest, delegate: nil)
            let response = prepareResponse(data: data, urlResponse: urlResponse)
            
            loggingDelegate?.log(request: urlRequest, response: urlResponse, data: data)

            for interceptor in interceptors {
                try Task.checkCancellation()
                let retryAction = try await interceptor.shouldRetry(urlRequest, for: &urlResponse)
                switch retryAction {
                case .retry:
                    return try await _perform(request)
                case .doNotRetry:
                    break
                }
            }

            try Task.checkCancellation()
            return response
        }
        catch let error as NSError where error.domain == NSURLErrorDomain &&
                [NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet].contains(error.code)
        {
            loggingDelegate?.log(request: urlRequest, error: error)

            throw NetworkClientError.noInternetConnection
        }
        catch {
            loggingDelegate?.log(request: urlRequest, error: error)

            throw NetworkClientError.requestFailure(error)
        }
    }
    
    private func createURLRequest(for request: Request) -> URLRequest? {
        guard let url = createURL(for: request) else { return nil }
        
        var urlRequest = URLRequest(url: url)
        urlRequest.timeoutInterval = configuration.timeout
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body?.data
        
        configuration.headers.forEach { urlRequest.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.headers?.forEach { urlRequest.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.body?.headers.forEach { urlRequest.setValue($0.value, forHTTPHeaderField: $0.key) }
        
        return urlRequest
    }
    
    private func createURL(for request: Request) -> URL? {
        var requestURL = request.endpoint
        if requestURL.host == nil {
            let serviceURLString = configuration.serviceURL.absoluteString
            let requestURLString = request.endpoint.absoluteString
            
            guard let url = URL(string: serviceURLString + requestURLString) else {
                return nil
            }
            requestURL = url
        }
        guard let query = request.query else {
            return requestURL
        }
        guard var urlComponents = URLComponents(url: requestURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        urlComponents.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        return urlComponents.url
    }
    
    private func prepareResponse(data: Data, urlResponse: URLResponse) -> TypedResponse<Data> {
        let httpURLResponse = urlResponse as? HTTPURLResponse
        let headersList = httpURLResponse?.allHeaderFields.map { ("\($0.key)", "\($0.value)") }
        return TypedResponse(
            statusCode: httpURLResponse?.statusCode,
            mimeType: urlResponse.mimeType,
            headers: Dictionary(uniqueKeysWithValues: headersList ?? []),
            body: data
        )
    }
}
