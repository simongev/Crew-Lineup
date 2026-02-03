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

let config = URLSessionConfiguration.default
config.httpCookieAcceptPolicy = .always
config.httpShouldSetCookies = true
config.httpCookieStorage = HTTPCookieStorage.shared
let session = URLSession(configuration: config)

func login() -> Bool {
    print("Attempting login...")
    print("Username length: \(username.count)")
    print("Password length: \(password.count)")
    
    guard let url = URL(string: loginURL) else { return false }
    
    let semaphore = DispatchSemaphore(value: 0)
    var csrfToken: String?
    var htmlContent: String?
    
    var getRequest = URLRequest(url: url)
    getRequest.httpMethod = "GET"
    
    session.dataTask(with: getRequest) { data, response, error in
        defer { semaphore.signal() }
        
        if let data = data, let html = String(data: data, encoding: .utf8) {
            htmlContent = html
            
            // Look for CSRF token
            if let range = html.range(of: "name=\"authenticity_token\"[^>]*value=\"([^\"]+)\"", options: .regularExpression) {
                let match = String(html[range])
                if let valueRange = match.range(of: "value=\"([^\"]+)\"", options: .regularExpression) {
                    let valueMatch = String(match[valueRange])
                    csrfToken = valueMatch.replacingOccurrences(of: "value=\"", with: "").replacingOccurrences(of: "\"", from: "")
                }
            }
            
            // Look for form fields
            print("\n--- Form Analysis ---")
            let emailPatterns = [
                "name=\"user\\[email\\]\"",
                "name=\"email\"",
                "id=\"user_email\"",
                "type=\"email\""
            ]
            
            for pattern in emailPatterns {
                if html.range(of: pattern, options: .regularExpression) != nil {
                    print("Found email field pattern: \(pattern)")
                }
            }
            
            let passwordPatterns = [
                "name=\"user\\[password\\]\"",
                "name=\"password\"",
                "id=\"user_password\"",
                "type=\"password\""
            ]
            
            for pattern in passwordPatterns {
                if html.range(of: pattern, options: .regularExpression) != nil {
                    print("Found password field pattern: \(pattern)")
                }
            }
            print("---\n")
        }
    }.resume()
    
    semaphore.wait()
    
    guard let token = csrfToken else {
        print("Failed to extract CSRF token")
        if let html = htmlContent {
            print("HTML snippet: \(String(html.prefix(1000)))")
        }
        return false
    }
    
    print("CSRF token: \(token.prefix(20))...")
    
    // Submit login
    var postRequest = URLRequest(url: url)
    postRequest.httpMethod = "POST"
    postRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    postRequest.setValue(loginURL, forHTTPHeaderField: "Referer")
    postRequest.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
    
    let params = [
        "authenticity_token": token,
        "user[email]": username,
        "user[password]": password,
        "commit": "Sign in"
    ]
    
    let bodyString = params.map { "\($0.key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)" }.joined(separator: "&")
    
    print("POST body (without password): authenticity_token=..&user[email]=\(username)&user[password]=***&commit=Sign+in")
    
    postRequest.httpBody = bodyString.data(using: .utf8)
    
    var loginSuccess = false
    let loginSemaphore = DispatchSemaphore(value: 0)
    
    session.dataTask(with: postRequest) { data, response, error in
        defer { loginSemaphore.signal() }
        
        if let httpResponse = response as? HTTPURLResponse {
            print("Login POST status: \(httpResponse.statusCode)")
            
            if httpResponse.statusCode == 302 || httpResponse.statusCode == 303 {
                if let location = httpResponse.allHeaderFields["Location"] as? String {
                    print("Redirected to: \(location)")
                }
                loginSuccess = true
            } else if httpResponse.statusCode == 200 {
                if let data = data, let html = String(data: data, encoding: .utf8) {
                    if html.contains("Invalid Email or password") {
                        print("ERROR: Invalid credentials message found")
                    } else if html.contains("user[email]") || html.contains("sign_in") {
                        print("ERROR: Still showing login form")
                    } else {
                        loginSuccess = true
                        print("Login appears successful (no login form)")
                    }
                }
            }
        }
        
        if let cookies = HTTPCookieStorage.shared.cookies {
            print("Cookies after login: \(cookies.count)")
            for cookie in cookies {
                print("  - \(cookie.name)")
            }
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
            let contentType = httpResponse.allHeaderFields["Content-Type"] as? String ?? "unknown"
            print("Content-Type: \(contentType)")
        }
        
        guard let data = data else { return }
        
        if let responseString = String(data: data, encoding: .utf8) {
            print("Response length: \(responseString.count) characters")
            
            if responseString.contains("<!DOCTYPE html>") {
                print("ERROR: Got HTML instead of JSON")
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
    print("FATAL: Login failed - check credentials in GitHub Secrets")
    exit(1)
}

print("✓ Login successful")

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
