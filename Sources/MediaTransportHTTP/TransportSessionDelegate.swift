import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif

struct TransportDataResponse {
    let data: Data
    let response: HTTPURLResponse
}

enum PasswordChallengeDecision {
    case performDefaultHandling
    case useCredential(URLCredential)
    case reject(TransportError)
}

final class TransportSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct TaskState {
        var data = Data()
        var response: HTTPURLResponse?
        var policyError: TransportError?
        var redirectCount = 0
        var returnsErrorResponseOnCancellation = false
        let maxResponseBytes: Int
        let completion: @Sendable (Result<TransportDataResponse, TransportError>) -> Void
    }

    private let credential: WebDAVCredential
    private let trustPolicy: TrustPolicy
    private let origin: TransportOrigin
    private let maxRedirects: Int
    private let lock = NSLock()
    private var tasks: [Int: TaskState] = [:]

    init(
        credential: WebDAVCredential,
        trustPolicy: TrustPolicy,
        origin: TransportOrigin,
        maxRedirects: Int = 5
    ) {
        self.credential = credential
        self.trustPolicy = trustPolicy
        self.origin = origin
        self.maxRedirects = maxRedirects
    }

    func register(
        task: URLSessionDataTask,
        maxResponseBytes: Int,
        completion: @escaping @Sendable (Result<TransportDataResponse, TransportError>) -> Void
    ) {
        lock.lock()
        tasks[task.taskIdentifier] = TaskState(
            maxResponseBytes: max(0, maxResponseBytes),
            completion: completion
        )
        lock.unlock()
    }

    private func recordError(_ error: TransportError, for taskIdentifier: Int) {
        lock.lock()
        if tasks[taskIdentifier]?.policyError == nil {
            tasks[taskIdentifier]?.policyError = error
        }
        lock.unlock()
    }

    private func recordErrorForAllTasks(_ error: TransportError) {
        lock.lock()
        for taskIdentifier in Array(tasks.keys) where tasks[taskIdentifier]?.policyError == nil {
            tasks[taskIdentifier]?.policyError = error
        }
        lock.unlock()
    }

    private func challengeMatchesOrigin(_ space: URLProtectionSpace) -> Bool {
        guard let scheme = space.protocol?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }
        let port = space.port > 0 ? space.port : TransportOrigin.defaultPort(forScheme: scheme)
        return TransportOrigin(scheme: scheme, host: space.host.lowercased(), port: port) == origin
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        #if canImport(Security)
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard challengeMatchesOrigin(space) else {
            let error = TransportError.invalidOrigin(reason: "TLS challenge did not match the session origin")
            recordErrorForAllTasks(error)
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        handleServerTrust(space: space, recordError: recordErrorForAllTasks, completionHandler: completionHandler)
        #else
        completionHandler(.performDefaultHandling, nil)
        #endif
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace

        #if canImport(Security)
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            guard challengeMatchesOrigin(space) else {
                recordError(.invalidOrigin(reason: "TLS challenge did not match the session origin"), for: task.taskIdentifier)
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            handleServerTrust(
                space: space,
                recordError: { [weak self] error in
                    self?.recordError(error, for: task.taskIdentifier)
                },
                completionHandler: completionHandler
            )
            return
        }
        #endif

        if space.authenticationMethod == NSURLAuthenticationMethodHTTPBasic
            || space.authenticationMethod == NSURLAuthenticationMethodHTTPDigest {
            handlePasswordChallenge(
                space: space,
                previousFailureCount: challenge.previousFailureCount,
                taskIdentifier: task.taskIdentifier,
                completionHandler: completionHandler
            )
            return
        }

        completionHandler(.performDefaultHandling, nil)
    }

    #if canImport(Security)
    private func handleServerTrust(
        space: URLProtectionSpace,
        recordError: (TransportError) -> Void,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let trust = space.serverTrust else {
            recordError(.trustEvaluationFailed(reason: "challenge carried no server trust object"))
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        switch trustPolicy {
        case .system:
            if let error = SystemTrustEvaluator.evaluateSystemTrust(trust, host: space.host) {
                recordError(error)
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        case .pinnedLeaf:
            guard let leafDER = SystemTrustEvaluator.leafCertificateDER(from: trust) else {
                recordError(.trustEvaluationFailed(reason: "could not extract leaf certificate"))
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            if let mismatch = LeafCertificateTrust.evaluatePinnedLeaf(leafDER, against: trustPolicy) {
                recordError(mismatch)
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }
    #endif

    private func handlePasswordChallenge(
        space: URLProtectionSpace,
        previousFailureCount: Int,
        taskIdentifier: Int,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        switch passwordChallengeDecision(space: space, previousFailureCount: previousFailureCount) {
        case .performDefaultHandling:
            completionHandler(.performDefaultHandling, nil)
        case .useCredential(let credential):
            completionHandler(.useCredential, credential)
        case .reject(let error):
            recordError(error, for: taskIdentifier)
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func passwordChallengeDecision(
        space: URLProtectionSpace,
        previousFailureCount: Int
    ) -> PasswordChallengeDecision {
        // Same-origin is mandatory (never answer a credential to a different
        // host, e.g. after a redirect). HTTPS is NOT required: Plozz permits
        // credentials to a LAN media share over plain http (the onboarding UI
        // warns); see CredentialPreflight.
        guard challengeMatchesOrigin(space) else {
            return .reject(.invalidOrigin(reason: "authentication challenge did not match the session origin"))
        }
        guard case .password(let username, let password, let policy) = credential else {
            return .performDefaultHandling
        }

        let scheme: PasswordChallengeScheme = space.authenticationMethod == NSURLAuthenticationMethodHTTPDigest
            ? .digest
            : .basic
        guard policy.permits(scheme) else {
            return .reject(.authenticationSchemeNotPermitted(scheme: scheme.rawValue))
        }
        guard previousFailureCount == 0 else {
            return .reject(.authenticationFailed(reason: "credential rejected for \(scheme.rawValue) challenge"))
        }
        return .useCredential(
            URLCredential(user: username, password: password, persistence: .none)
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        tasks[task.taskIdentifier]?.redirectCount += 1
        let redirectCount = tasks[task.taskIdentifier]?.redirectCount
        lock.unlock()

        guard let redirectCount else {
            completionHandler(nil)
            task.cancel()
            return
        }
        guard redirectCount <= maxRedirects else {
            recordError(.tooManyRedirects(limit: maxRedirects), for: task.taskIdentifier)
            completionHandler(nil)
            task.cancel()
            return
        }
        guard let originalRequest = task.currentRequest ?? task.originalRequest else {
            recordError(.invalidOrigin(reason: "redirect callback had no prior request"), for: task.taskIdentifier)
            completionHandler(nil)
            task.cancel()
            return
        }

        switch RedirectPolicy.evaluate(original: originalRequest, newRequest: request) {
        case .follow(let sanitized):
            completionHandler(sanitized)
        case .reject(let error):
            recordError(error, for: task.taskIdentifier)
            completionHandler(nil)
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            recordError(.transport(code: URLError.badServerResponse.rawValue), for: dataTask.taskIdentifier)
            completionHandler(.cancel)
            return
        }

        lock.lock()
        let maximum = tasks[dataTask.taskIdentifier]?.maxResponseBytes
        if tasks[dataTask.taskIdentifier] != nil {
            tasks[dataTask.taskIdentifier]?.response = response
            if response.statusCode >= 400 {
                tasks[dataTask.taskIdentifier]?.returnsErrorResponseOnCancellation = true
            }
        }
        lock.unlock()

        guard let maximum else {
            completionHandler(.cancel)
            return
        }
        if response.statusCode >= 400 {
            completionHandler(.cancel)
            return
        }
        if response.expectedContentLength > Int64(maximum) {
            recordError(.responseTooLarge(limitBytes: maximum), for: dataTask.taskIdentifier)
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var shouldCancel = false

        lock.lock()
        if var state = tasks[dataTask.taskIdentifier],
           state.policyError == nil,
           !state.returnsErrorResponseOnCancellation {
            if data.count > state.maxResponseBytes - state.data.count {
                state.policyError = .responseTooLarge(limitBytes: state.maxResponseBytes)
                shouldCancel = true
            } else {
                state.data.append(data)
            }
            tasks[dataTask.taskIdentifier] = state
        }
        lock.unlock()

        if shouldCancel {
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let state = tasks.removeValue(forKey: task.taskIdentifier)
        lock.unlock()

        guard let state else { return }

        if let policyError = state.policyError {
            state.completion(.failure(policyError))
        } else if state.returnsErrorResponseOnCancellation, let response = state.response {
            state.completion(.success(TransportDataResponse(data: Data(), response: response)))
        } else if let urlError = error as? URLError {
            if urlError.code == .cancelled {
                state.completion(.failure(.cancelled))
            } else {
                state.completion(.failure(.transport(code: urlError.code.rawValue)))
            }
        } else if error != nil {
            state.completion(.failure(.transport(code: URLError.unknown.rawValue)))
        } else if let response = state.response {
            state.completion(.success(TransportDataResponse(data: state.data, response: response)))
        } else {
            state.completion(.failure(.transport(code: URLError.badServerResponse.rawValue)))
        }
    }
}
