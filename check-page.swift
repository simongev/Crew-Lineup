#!/usr/bin/env swift

import Foundation

let loginURL = "https://portal.jetinsight.com/users/sign_in"
let baseURL = "https://portal.jetinsight.com/schedule/aircraft.json"
let aircraftUUIDs = [
    "e646bec1-3dc7-4d2b-9e31-d39e617dd9c0",
    "f15b98b7-9d5b-4dcb-bfd5-7faf0bf7a911",
    "445712bc-4a8d-42c9-8b69-26036ab16cf4"
]
let ntfyTopic = "notify.sh/CrewLineup" // CHANGE THIS
let dataFile = "flights-data.json"

let username = ProcessInfo.processInfo.environment["PAGE_USERNAME"] ?? ""
let password = ProcessInfo.processInfo.environment["PAGE_PASSWORD"] ?? ""

struct Flight: Codable, Hashable {
    let id: String
    let title: String?
    let start: String?
    let end: String?
    let crew: [String]?
    
    init(from dict: [String: Any]) {
        self.id = dict["id"] as? String ?? UUID().uuidString
        self.title = dict["title"] as? String
        self.start = dict["start"] as? String
        self.end = dict["end"] as? String
        
        if let crewArray = dict["crew"] as? [[String: Any]] {
            self.crew = crewArray.compactMap { $0["name"] as? String }
        } else {
            self.crew = nil
        }
    }
}

class SessionManager {
    static let shared = SessionManager()
    var cookies: [HTTPCookie] = []
    
    private init() {}
}

func login() -> Bool {
    print("Attempting login...")
    
    // First, get the login page to extract CSRF token
    guard let url = URL(string: loginURL) else { return false }
    
    let config = URLSessionConfiguration.default
    config.httpCookieStorage = HTTPCookieStorage.shared
    config.httpCookieAcceptPolicy = .always
    let session = URLSession(configuration: config)
    
    let semaphore = DispatchSemaphore(value: 0)
    var csrfToken: String?
    
    session.dataTask(with: url) { data, response, error in
        defer { semaphore.signal() }
        
        if let data = data, let html = String(data: data, encoding: .utf8) {
            // Extract CSRF token from HTML
            if let range = html.range(of: "name=\"authenticity_token\" value=\"([^\"]+)\"", options: .regularExpression) {
                let match = String(html[range])
                if let tokenRange = match.range(of: "value=\"([^\"]+)\"", options: .regularExpression) {
                    csrfToken = String(match[tokenRange]).replacingOccurrences(of: "value=\"", with: "").replacingOccurrences(of: "\"", with: "")
                }
            }
        }
    }.resume()
    
    semaphore.wait()
    
    guard let token = csrfToken else {
        print("Failed to get CSRF token")
        return false
    }
    
    print("Got CSRF token")
    
    // Now submit login
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    
    let bodyString = "authenticity_token=\(token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)&user[email]=\(username.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)&user[password]=\(password.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)&commit=Sign+in"
    request.httpBody = bodyString.data(using: .utf8)
    
    var loginSuccess = false
    let loginSemaphore = DispatchSemaphore(value: 0)
    
    session.dataTask(with: request) { data, response, error in
        defer { loginSemaphore.signal() }
        
        if let httpResponse = response as? HTTPURLResponse {
            print("Login status: \(httpResponse.statusCode)")
            loginSuccess = httpResponse.statusCode == 302 || httpResponse.statusCode == 200
        }
    }.resume()
    
    loginSemaphore.wait()
    
    return loginSuccess
}

func buildURL() -> String {
    let now = Date()
    let weekFromNow = Calendar.current.date(byAdding: .day, value: 7, to: now)!
    
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    
    let startDate = formatter.string(from: now).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
    let endDate = formatter.string(from: weekFromNow).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
    
    let uuidParams = aircraftUUIDs.map { "uuid%5B%5D=\($0)" }.joined(separator: "&")
    
    return "\(baseURL)?start=\(startDate)&end=\(endDate)&time_zone=America%2FNew_York&view=rollingMonth&\(uuidParams)&parallel_load=true"
}

func fetchFlights() -> [Flight]? {
    let urlString = buildURL()
    print("Fetching: \(urlString)")
    
    guard let url = URL(string: urlString) else { return nil }
    
    let config = URLSessionConfiguration.default
    config.httpCookieStorage = HTTPCookieStorage.shared
    let session = URLSession(configuration: config)
    
    var request = URLRequest(url: url)
    request.timeoutInterval = 30
    
    let semaphore = DispatchSemaphore(value: 0)
    var result: [Flight]?
    
    session.dataTask(with: request) { data, response, error in
        defer { semaphore.signal() }
        
        if let error = error {
            print("ERROR: \(error.localizedDescription)")
            return
        }
        
        if let httpResponse = response as? HTTPURLResponse {
            print("HTTP Status: \(httpResponse.statusCode)")
            print("Content-Type: \(httpResponse.allHeaderFields["Content-Type"] ?? "unknown")")
        }
        
        guard let data = data else { return }
        
        if let responseString = String(data: data, encoding: .utf8) {
            print("Response length: \(responseString.count) characters")
            if responseString.contains("<!DOCTYPE html>") {
                print("ERROR: Got HTML instead of JSON - authentication failed")
                return
            }
        }
        
        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                result = json.map { Flight(from: $0) }
                print("Found \(result?.count ?? 0) flights")
            }
        } catch {
            print("JSON parse error: \(error)")
        }
    }.resume()
    
    semaphore.wait()
    return result
}

func loadPreviousFlights() -> [Flight]? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: dataFile)),
          let flights = try? JSONDecoder().decode([Flight].self, from: data) else {
        return nil
    }
    return flights
}

func saveFlights(_ flights: [Flight]) {
    if let data = try? JSONEncoder().encode(flights) {
        try? data.write(to: URL(fileURLWithPath: dataFile))
    }
}

func sendNotification(_ message: String) {
    print("Sending notification: \(message)")
    guard let url = URL(string: "https://ntfy.sh/\(ntfyTopic)") else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = message.data(using: .utf8)
    
    let semaphore = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: request) { _, _, _ in
        semaphore.signal()
    }.resume()
    semaphore.wait()
}

print("=== Starting flight check ===")

guard login() else {
    print("FATAL: Login failed")
    exit(1)
}

print("Login successful")

guard let currentFlights = fetchFlights() else {
    print("FATAL: Failed to fetch flights")
    exit(1)
}

let previousFlights = loadPreviousFlights()

if let previous = previousFlights {
    let previousSet = Set(previous)
    let currentSet = Set(currentFlights)
    
    let newFlights = currentSet.subtracting(previousSet)
    for flight in newFlights {
        let title = flight.title ?? "Unknown"
        let start = flight.start ?? "Unknown time"
        sendNotification("🛫 New flight: \(title) at \(start)")
    }
    
    let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
    for current in currentFlights {
        if let prev = previousByID[current.id] {
            let prevCrew = Set(prev.crew ?? [])
            let currentCrew = Set(current.crew ?? [])
            
            if prevCrew != currentCrew && !currentCrew.isEmpty {
                let crewList = currentCrew.sorted().joined(separator: ", ")
                let title = current.title ?? "Flight"
                sendNotification("👥 Crew assigned to \(title): \(crewList)")
            }
        }
    }
    
    print("✓ Comparison complete")
} else {
    print("✓ First run, saving initial data")
}

saveFlights(currentFlights)
