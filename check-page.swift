#!/usr/bin/env swift

import Foundation

let baseURL = "https://portal.jetinsight.com/schedule/aircraft.json"
let aircraftUUIDs = [
    "e646bec1-3dc7-4d2b-9e31-d39e617dd9c0",
    "f15b98b7-9d5b-4dcb-bfd5-7faf0bf7a911",
    "445712bc-4a8d-42c9-8b69-26036ab16cf4"
]
let ntfyTopic = "CrewLineup"
let dataFile = "flights-data.json"
let myLastName = "Navon" // CHANGE THIS to your last name

let sessionCookie = ProcessInfo.processInfo.environment["SESSION_COOKIE"] ?? ""

struct CrewMember: Codable, Hashable {
    let name: String
    let role: String
}

struct Flight: Codable, Hashable {
    let id: String
    let start: String?
    let crew: [CrewMember]?
    let aircraft: String?
    let destination: String?
    let origin: String?
    let isActualFlight: Bool
    
    init(from dict: [String: Any]) {
        self.start = dict["start"] as? String
        
        if let props = dict["extendedProps"] as? [String: Any] {
            self.id = props["uuid"] as? String ?? UUID().uuidString
            self.aircraft = props["aircraft"] as? String
            self.destination = props["destination_short"] as? String
            self.origin = props["origin_short"] as? String
            
            if let crewArray = props["crew"] as? [[String: Any]] {
                self.crew = crewArray.compactMap { crewDict in
                    guard let nameRaw = crewDict["name"] as? String,
                          let role = crewDict["role"] as? String else { return nil }
                    let cleanName = nameRaw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    return CrewMember(name: cleanName.trimmingCharacters(in: .whitespaces), role: role)
                }
            } else {
                self.crew = nil
            }
            
            let eventGroup = props["event_group"] as? String ?? ""
            self.isActualFlight = eventGroup == "customer_flight"
        } else {
            self.id = UUID().uuidString
            self.aircraft = nil
            self.destination = nil
            self.origin = nil
            self.crew = nil
            self.isActualFlight = false
        }
    }
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

func sendNotification(_ message: String) {
    print("📲 Sending to topic: '\(ntfyTopic)'")
    print("📲 Message: \(message)")
    
    guard let url = URL(string: "https://ntfy.sh/\(ntfyTopic)") else {
        print("ERROR: Invalid ntfy URL")
        return
    }
    
    print("📲 URL: \(url.absoluteString)")
    
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = message.data(using: .utf8)
    
    let semaphore = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: request) { data, response, error in
        if let error = error {
            print("📲 Notification error: \(error.localizedDescription)")
        }
        if let httpResponse = response as? HTTPURLResponse {
            print("📲 Notification response: \(httpResponse.statusCode)")
        }
        semaphore.signal()
    }.resume()
    semaphore.wait()
}

func fetchFlights(attempt: Int = 1) -> [Flight]? {
    let urlString = buildURL()
    print("Fetching flights (attempt \(attempt))...")
    
    guard let url = URL(string: urlString) else { return nil }
    
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 60
    config.timeoutIntervalForResource = 120
    let session = URLSession(configuration: config)
    
    var request = URLRequest(url: url)
    request.setValue("_app_session=\(sessionCookie)", forHTTPHeaderField: "Cookie")
    
    let semaphore = DispatchSemaphore(value: 0)
    var result: [Flight]?
    var shouldRetry = false
    var sessionExpired = false
    
    session.dataTask(with: request) { data, response, error in
        defer { semaphore.signal() }
        
        if let error = error {
            print("ERROR: \(error.localizedDescription)")
            if attempt < 3 {
                shouldRetry = true
            }
            return
        }
        
        if let httpResponse = response as? HTTPURLResponse {
            print("HTTP \(httpResponse.statusCode)")
            
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                print("ERROR: Authentication failed")
                sessionExpired = true
                return
            }
            
            guard httpResponse.statusCode == 200 else {
                if httpResponse.statusCode >= 500 && attempt < 3 {
                    shouldRetry = true
                }
                return
            }
        }
        
        guard let data = data else { return }
        
        if let responseString = String(data: data, encoding: .utf8) {
            if responseString.contains("<!DOCTYPE html>") {
                print("ERROR: Got HTML instead of JSON - session expired")
                sessionExpired = true
                return
            }
        }
        
        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                let allFlights = json.map { Flight(from: $0) }
                result = allFlights.filter { $0.isActualFlight }
                print("Found \(result?.count ?? 0) actual flights")
            }
        } catch {
            print("JSON parse error: \(error)")
        }
    }.resume()
    
    semaphore.wait()
    
    if sessionExpired {
        sendNotification("⚠️ Session expired! Update SESSION_COOKIE in GitHub secrets")
        return nil
    }
    
    if shouldRetry {
        print("Retrying in 5 seconds...")
        sleep(5)
        return fetchFlights(attempt: attempt + 1)
    }
    
    return result
}

func formatDateTime(_ isoString: String?) -> String {
    guard let isoString = isoString else { return "Unknown time" }
    
    let formatter = ISO8601DateFormatter()
    guard let date = formatter.date(from: isoString) else { return isoString }
    
    let calendar = Calendar.current
    let now = Date()
    
    let displayFormatter = DateFormatter()
    displayFormatter.timeZone = TimeZone(identifier: "America/New_York")
    
    if calendar.isDateInToday(date) {
        displayFormatter.dateFormat = "'today at' HH:mm"
    } else {
        displayFormatter.dateFormat = "MMM d 'at' HH:mm"
    }
    
    return displayFormatter.string(from: date)
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

print("=== Flight check ===")

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
        let time = formatDateTime(flight.start)
        let aircraft = flight.aircraft ?? "Unknown"
        let route = "\(flight.origin ?? "?") - \(flight.destination ?? "?")"
        
        sendNotification("🛫 New flight: \(time) on \(aircraft) \(route)")
    }
    
    var previousByID: [String: Flight] = [:]
    for flight in previous {
        previousByID[flight.id] = flight
    }
    
    for current in currentFlights {
        if let prev = previousByID[current.id] {
            let prevCrewNames = Set(prev.crew?.map { $0.name } ?? [])
            let currentCrewNames = Set(current.crew?.map { $0.name } ?? [])
            
            let myFullName = current.crew?.first(where: { $0.name.contains(myLastName) })?.name
            
            if prevCrewNames != currentCrewNames && myFullName != nil {
                let time = formatDateTime(current.start)
                let route = "\(current.origin ?? "?") - \(current.destination ?? "?")"
                let otherPilots = current.crew?.filter { !$0.name.contains(myLastName) }.map { $0.name } ?? []
                
                if otherPilots.isEmpty {
                    sendNotification("👨‍✈️ You're assigned! \(time) \(route) (solo)")
                } else {
                    let crewList = otherPilots.joined(separator: ", ")
                    sendNotification("👨‍✈️ You're assigned! \(time) \(route) with \(crewList)")
                }
            }
        }
    }
    
    print("✓ Check complete")
} else {
    print("✓ First run, saving baseline")
}

saveFlights(currentFlights)
