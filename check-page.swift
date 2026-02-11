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

func runCommand(_ command: String) -> (output: String, exitCode: Int32) {
    let task = Process()
    task.launchPath = "/bin/bash"
    task.arguments = ["-c", command]
    
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe
    task.launch()
    task.waitUntilExit()
    
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    
    return (output, task.terminationStatus)
}

func sendNotification(_ message: String) {
    print("📲 NOTIFICATION: \(message)")
    
    let escapedMessage = message.replacingOccurrences(of: "'", with: "'\\''")
    let command = "curl -s -d '\(escapedMessage)' https://ntfy.sh/\(ntfyTopic)"
    
    let result = runCommand(command)
    if result.exitCode == 0 {
        print("   ✓ Sent successfully")
    } else {
        print("   ✗ Error: \(result.output)")
    }
}

func fetchFlights(attempt: Int = 1) -> [Flight]? {
    let urlString = buildURL()
    print("Fetching flights (attempt \(attempt))...")
    
    let command = "curl -s -H 'Cookie: _app_session=\(sessionCookie)' '\(urlString)'"
    let result = runCommand(command)
    
    if result.exitCode != 0 {
        print("ERROR: curl failed")
        if attempt < 3 {
            sleep(5)
            return fetchFlights(attempt: attempt + 1)
        }
        return nil
    }
    
    if result.output.contains("<!DOCTYPE html>") {
        print("ERROR: Session expired")
        sendNotification("⚠️ Session expired! Update SESSION_COOKIE")
        return nil
    }
    
    guard let data = result.output.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        print("ERROR: JSON parse failed")
        if attempt < 3 {
            sleep(5)
            return fetchFlights(attempt: attempt + 1)
        }
        return nil
    }
    
    let flights = json.map { Flight(from: $0) }.filter { $0.isActualFlight }
    print("Found \(flights.count) actual flights")
    return flights
}

func formatDateTime(_ isoString: String?) -> String {
    guard let isoString = isoString,
          let date = ISO8601DateFormatter().date(from: isoString) else {
        return "Unknown time"
    }
    
    let formatter = DateFormatter()
    formatter.timeZone = TimeZone(identifier: "America/New_York")
    formatter.dateFormat = Calendar.current.isDateInToday(date) ? "'today at' HH:mm" : "MMM d 'at' HH:mm"
    
    return formatter.string(from: date)
}

func getFirstName(_ fullName: String) -> String {
    fullName.components(separatedBy: " ").first ?? fullName
}

func buildFullRoute(for flights: [Flight]) -> String {
    let sorted = flights.sorted { ($0.start ?? "") < ($1.start ?? "") }
    var route: [String] = []
    
    for flight in sorted {
        if let origin = flight.origin, route.last != origin {
            route.append(origin)
        }
        if let dest = flight.destination {
            route.append(dest)
        }
    }
    
    return route.joined(separator: " - ")
}

func groupByLocator(_ flights: [Flight]) -> [String: [Flight]] {
    Dictionary(grouping: flights) { $0.locator ?? $0.id }
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
    print("FATAL: Failed to fetch")
    exit(1)
}

let upcomingFlights = currentFlights.filter { !$0.isPast() }
print("Upcoming: \(upcomingFlights.count)")

print("\n📋 Current locators:")
for (locator, legs) in groupByLocator(upcomingFlights) {
    let route = buildFullRoute(for: legs)
    print("   \(locator): \(legs.count) leg(s) - \(route)")
}

guard let previous = loadPreviousFlights() else {
    print("\n✓ First run - saving baseline")
    saveFlights(upcomingFlights)
    exit(0)
}

let previousUpcoming = previous.filter { !$0.isPast() }
let previousSet = Set(previousUpcoming)
let currentSet = Set(upcomingFlights)

print("\n🆕 Checking for new flights...")
let newFlights = currentSet.subtracting(previousSet)
let newFlightsByLocator = groupByLocator(Array(newFlights))

print("   Found \(newFlightsByLocator.count) new locator(s)")

for (locator, flights) in newFlightsByLocator {
    print("   Processing locator: \(locator)")
    
    guard let firstFlight = flights.sorted(by: { ($0.start ?? "") < ($1.start ?? "") }).first else { 
        print("      ✗ No first flight found")
        continue 
    }
    
    let time = formatDateTime(firstFlight.start)
    let aircraft = firstFlight.aircraft ?? "Unknown"
    let route = buildFullRoute(for: flights)
    
    print("      Route: \(route)")
    print("      Legs: \(flights.count)")
    
    sendNotification("🛫 New flight: \(time) on \(aircraft) \(route)")
}

print("\n👥 Checking for crew changes...")
let previousByLocator = groupByLocator(previousUpcoming)
let currentByLocator = groupByLocator(upcomingFlights)

var crewChanges = 0

for (locator, currentLegs) in currentByLocator {
    guard let previousLegs = previousByLocator[locator] else { continue }
    
    let prevCrew = Set(previousLegs.flatMap { $0.crew?.map { $0.name } ?? [] })
    let currCrew = Set(currentLegs.flatMap { $0.crew?.map { $0.name } ?? [] })
    
    if prevCrew != currCrew && !currCrew.isEmpty {
        crewChanges += 1
        print("   Locator: \(locator)")
        print("      Previous crew: \(prevCrew.joined(separator: ", "))")
        print("      Current crew: \(currCrew.joined(separator: ", "))")
        
        guard let firstFlight = currentLegs.sorted(by: { ($0.start ?? "") < ($1.start ?? "") }).first else { continue }
        
        let time = formatDateTime(firstFlight.start)
        let route = buildFullRoute(for: currentLegs)
        
        let pic = firstFlight.crew?.first(where: { $0.role.lowercased().contains("pic") })
        let sic = firstFlight.crew?.first(where: { $0.role.lowercased().contains("sic") })
        
        var crewText = [pic, sic].compactMap { member in
            guard let member = member else { return nil }
            let role = member.role.uppercased().contains("PIC") ? "PIC" : "SIC"
            return "\(role): \(getFirstName(member.name))"
        }.joined(separator: ", ")
        
        if crewText.isEmpty {
            crewText = firstFlight.crew?.map { getFirstName($0.name) }.joined(separator: ", ") ?? ""
        }
        
        sendNotification("👨‍✈️ Crew: \(crewText) - \(time) \(route)")
    }
}

print("   Found \(crewChanges) crew change(s)")

saveFlights(upcomingFlights)
print("\n✓ Done")
