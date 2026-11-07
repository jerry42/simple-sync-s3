import Foundation

/// Requête HTTP synchrone, injectable pour les tests. Appelée hors du thread principal
/// (synchro, ou connexion SSO lancée sur une file en arrière-plan).
protocol HTTPTransport {
    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse)
}

struct URLSessionTransport: HTTPTransport {
    var session: URLSession = .shared

    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        final class Box: @unchecked Sendable {
            var result: Result<(Data, HTTPURLResponse), Error> = .failure(URLError(.unknown))
        }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        // Le gestionnaire de fin tourne sur la file de délégué d'URLSession : pas de blocage croisé.
        session.dataTask(with: request) { data, response, error in
            if let error {
                box.result = .failure(error)
            } else if let http = response as? HTTPURLResponse {
                box.result = .success((data ?? Data(), http))
            } else {
                box.result = .failure(URLError(.badServerResponse))
            }
            done.signal()
        }.resume()
        done.wait()
        return try box.result.get()
    }
}
