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
let myLastName = "Simon"

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
    let locator: String?
    let isActualFlight: Bool
    
    init(from dict: [String: Any]) {
        self.start = dict["start"] as? String
        
        if let props = dict["extendedProps"] as? [String: Any] {
            self.id = props["uuid"] as? String ?? UUID().uuidString
            self.aircraft = props["aircraft"] as? String
            self.destination = props["destination_short"] as? String
            self.origin = props["origin_short"] as? String
            self.locator = props["locator"] as? String
            
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
            self.locator = nil
            self.crew = nil
            self.isActualFlight = false
        }
    }
    
    func isPast() -> Bool {
        guard let startString = start else { return false }
        let formatter = ISO8601DateFormatter()
        guard let startDate = formatter.date(from: startString) else { return false }
        return startDate < Date()
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

func getFirstName(_ fullName: String) -> String {
    return fullName.components(separatedBy: " ").first ?? fullName
}

func buildFullRoute(for flights: [Flight]) -> String {
    let sorted = flights.sorted { ($0.start ?? "") < ($1.start ?? "") }
    var route: [String] = []
    
    for flight in sorted {
        if let origin = flight.origin {
            if route.isEmpty || route.last != origin {
                route.append(origin)
            }
        }
        if let dest = flight.destination {
            route.append(dest)
        }
    }
    
    return route.joined(separator: " - ")
}

func groupByLocator(_ flights: [Flight]) -> [String: [Flight]] {
    var grouped: [String: [Flight]] = [:]
    for flight in flights {
        let key = flight.locator ?? flight.id
        grouped[key, default: []].append(flight)
    }
    return grouped
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

// Filter out past flights
let upcomingFlights = currentFlights.filter { !$0.isPast() }
print("Found \(upcomingFlights.count) upcoming flights (filtered out past)")

let previousFlights = loadPreviousFlights()

if let previous = previousFlights {
    // Also filter past flights from previous data
    let previousUpcoming = previous.filter { !$0.isPast() }
    
    let previousSet = Set(previousUpcoming)
    let currentSet = Set(upcomingFlights)
    
    // New flights - group by locator
    let newFlights = currentSet.subtracting(previousSet)
    let newFlightsByLocator = groupByLocator(Array(newFlights))
    
    for (_, flights) in newFlightsByLocator {
        let sorted = flights.sorted { ($0.start ?? "") < ($1.start ?? "") }
        guard let firstFlight = sorted.first else { continue }
        
        let time = formatDateTime(firstFlight.start)
        let aircraft = firstFlight.aircraft ?? "Unknown"
        let route = buildFullRoute(for: flights)
        
        sendNotification("🛫 New flight: \(time) on \(aircraft) \(route)")
    }
    
    // Crew changes - group by locator
    let previousByLocator = groupByLocator(previousUpcoming)
    let currentByLocator = groupByLocator(upcomingFlights)
    
    for (locator, currentLegs) in currentByLocator {
        guard let previousLegs = previousByLocator[locator] else { continue }
        
        let prevCrewSet = Set(previousLegs.flatMap { $0.crew?.map { $0.name } ?? [] })
        let currCrewSet = Set(currentLegs.flatMap { $0.crew?.map { $0.name } ?? [] })
        
        if prevCrewSet != currCrewSet && !currCrewSet.isEmpty {
            let sorted = currentLegs.sorted { ($0.start ?? "") < ($1.start ?? "") }
            guard let firstFlight = sorted.first else { continue }
            
            let time = formatDateTime(firstFlight.start)
            let route = buildFullRoute(for: currentLegs)
            
            let pic = firstFlight.crew?.first(where: { $0.role.lowercased().contains("pic") })
            let sic = firstFlight.crew?.first(where: { $0.role.lowercased().contains("sic") })
            
            var crewText = ""
            if let picName = pic?.name {
                crewText += "PIC: \(getFirstName(picName))"
            }
            if let sicName = sic?.name {
                if !crewText.isEmpty { crewText += ", " }
                crewText += "SIC: \(getFirstName(sicName))"
            }
            
            if crewText.isEmpty {
                crewText = firstFlight.crew?.map { getFirstName($0.name) }.joined(separator: ", ") ?? ""
            }
            
            sendNotification("👨‍✈️ Crew assigned: \(crewText) - \(time) \(route)")
        }
    }
    
    print("✓ Check complete")
} else {
    print("✓ First run, saving baseline")
}

saveFlights(upcomingFlights)
