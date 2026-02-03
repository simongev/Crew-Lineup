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
let myName = "Gev Simon" // CHANGE THIS to your name as it appears in crew list

let sessionCookie = ProcessInfo.processInfo.environment["SESSION_COOKIE"] ?? ""

struct Flight: Codable, Hashable {
    let id: String
    let title: String?
    let start: String?
    let end: String?
    let crew: [String]?
    let aircraft: String?
    let destination: String?
    let departure: String?
    
    init(from dict: [String: Any]) {
        self.id = dict["id"] as? String ?? UUID().uuidString
        self.title = dict["title"] as? String
        self.start = dict["start"] as? String
        self.end = dict["end"] as? String
        
        // Extract crew names
        if let crewArray = dict["crew"] as? [[String: Any]] {
            self.crew = crewArray.compactMap { $0["name"] as? String }
        } else {
            self.crew = nil
        }
        
        // Try to extract aircraft/destination info
        self.aircraft = dict["aircraft"] as? String ?? dict["tail_number"] as? String
        self.destination = dict["destination"] as? String ?? dict["arrival_airport"] as? String
        self.departure = dict["departure"] as? String ?? dict["departure_airport"] as? String
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
    print("Fetching: \(urlString)")
    
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
            print("HTTP Status: \(httpResponse.statusCode)")
        }
        
        guard let data = data else { return }
        
        if let responseString = String(data: data, encoding: .utf8) {
            print("Response length: \(responseString.count) chars")
            
            if responseString.contains("<!DOCTYPE html>") {
                print("ERROR: Got HTML - session expired, update SESSION_COOKIE")
                return
            }
        }
        
        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                // Print first flight for debugging
                if let first = json.first {
                    print("\n=== SAMPLE FLIGHT JSON ===")
                    print("Keys available: \(first.keys.sorted())")
                    for (key, value) in first.sorted(by: { $0.key < $1.key }) {
                        print("\(key): \(value)")
                    }
                    print("=== END SAMPLE ===\n")
                }
                
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
    print("Sending: \(message)")
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
        let aircraft = flight.aircraft ?? "Unknown aircraft"
        let destination = flight.destination ?? flight.title ?? "Unknown destination"
        
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
                let destination = current.destination ?? current.title ?? "Unknown destination"
                let otherCrew = currentCrew.filter { $0 != myName }.sorted()
                
                if otherCrew.isEmpty {
                    sendNotification("👥 You're assigned! \(time) to \(destination) (flying solo)")
                } else {
                    let crewList = otherCrew.joined(separator: ", ")
                    sendNotification("👥 You're assigned! \(time) to \(destination) with \(crewList)")
                }
            }
        }
    }
    
    print("✓ Checked")
} else {
    print("✓ First run")
}

saveFlights(currentFlights)
