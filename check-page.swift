#!/usr/bin/env swift

import Foundation

let baseURL = "https://portal.jetinsight.com/schedule/aircraft.json"
let aircraftUUIDs = [
    "e646bec1-3dc7-4d2b-9e31-d39e617dd9c0",
    "f15b98b7-9d5b-4dcb-bfd5-7faf0bf7a911",
    "445712bc-4a8d-42c9-8b69-26036ab16cf4"
]
let ntfyTopic = "notify.sh/CrewLineup" // CHANGE THIS
let dataFile = "flights-data.json"
let myName = "Simon" // CHANGE THIS to your last name as it appears in crew_last_names

let sessionCookie = ProcessInfo.processInfo.environment["SESSION_COOKIE"] ?? ""

struct Flight: Codable, Hashable {
    let id: String
    let start: String?
    let crew: [String]?
    let aircraft: String?
    let destination: String?
    let origin: String?
    let isActualFlight: Bool
    
    init(from dict: [String: Any]) {
        self.id = dict["resourceId"] as? String ?? UUID().uuidString
        self.start = dict["start"] as? String
        
        if let props = dict["extendedProps"] as? [String: Any] {
            self.aircraft = props["aircraft"] as? String
            self.destination = props["destination_short"] as? String
            self.origin = props["origin_short"] as? String
            
            // Extract crew last names (cleaner than full names with HTML)
            if let crewLastNames = props["crew_last_names"] as? [String] {
                self.crew = crewLastNames
            } else {
                self.crew = nil
            }
            
            // Only track actual flights, not maintenance/calendar items
            let eventGroup = props["event_group"] as? String ?? ""
            self.isActualFlight = eventGroup == "customer_flight"
        } else {
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

func fetchFlights() -> [Flight]? {
    let urlString = buildURL()
    print("Fetching flights...")
    
    guard let url = URL(string: urlString) else { return nil }
    
    var request = URLRequest(url: url)
    request.timeoutInterval = 30
    request.setValue("_app_session=\(sessionCookie)", forHTTPHeaderField: "Cookie")
    
    let semaphore = DispatchSemaphore(value: 0)
    var result: [Flight]?
    
    URLSession.shared.dataTask(with: request) { data, response, error in
        defer { semaphore.signal() }
        
        if let error = error {
            print("ERROR: \(error.localizedDescription)")
            return
        }
        
        if let httpResponse = response as? HTTPURLResponse {
            guard httpResponse.statusCode == 200 else {
                print("ERROR: HTTP \(httpResponse.statusCode)")
                return
            }
        }
        
        guard let data = data else { return }
        
        if let responseString = String(data: data, encoding: .utf8) {
            if responseString.contains("<!DOCTYPE html>") {
                print("ERROR: Session expired, update SESSION_COOKIE secret")
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
    return result
}

func formatDateTime(_ isoString: String?) -> String {
    guard let isoString = isoString else { return "Unknown time" }
    
    let formatter = ISO8601DateFormatter()
    if let date = formatter.date(from: isoString) {
        let displayFormatter = DateFormatter()
        displayFormatter.dateFormat = "MMM d 'at' h:mm a"
        displayFormatter.timeZone = TimeZone(identifier: "America/New_York")
        return displayFormatter.string(from: date)
    }
    return isoString
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
    print("📲 \(message)")
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

print("=== Flight check ===")

guard let currentFlights = fetchFlights() else {
    print("FATAL: Failed to fetch flights")
    exit(1)
}

let previousFlights = loadPreviousFlights()

if let previous = previousFlights {
    let previousSet = Set(previous)
    let currentSet = Set(currentFlights)
    
    // Check for new flights
    let newFlights = currentSet.subtracting(previousSet)
    for flight in newFlights {
        let time = formatDateTime(flight.start)
        let aircraft = flight.aircraft ?? "Unknown"
        let destination = flight.destination ?? "Unknown"
        
        sendNotification("🛫 New flight: \(time) on \(aircraft) to \(destination)")
    }
    
    // Check for crew assignments
    let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
    for current in currentFlights {
        if let prev = previousByID[current.id] {
            let prevCrew = Set(prev.crew ?? [])
            let currentCrew = Set(current.crew ?? [])
            
            // Check if crew changed AND I'm now assigned
            if prevCrew != currentCrew && currentCrew.contains(myName) {
                let time = formatDateTime(current.start)
                let destination = current.destination ?? "Unknown"
                let otherCrew = currentCrew.filter { $0 != myName }.sorted()
                
                if otherCrew.isEmpty {
                    sendNotification("👨‍✈️ You're assigned! \(time) to \(destination) (solo)")
                } else {
                    let crewList = otherCrew.joined(separator: ", ")
                    sendNotification("👨‍✈️ You're assigned! \(time) to \(destination) with \(crewList)")
                }
            }
        }
    }
    
    print("✓ Check complete")
} else {
    print("✓ First run, saving baseline")
}

saveFlights(currentFlights)
