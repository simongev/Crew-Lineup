#!/usr/bin/env swift

import Foundation

let baseURL = "https://portal.jetinsight.com/schedule/aircraft.json"
let ntfyTopic = "CrewLineup"
let dataFile = "flights-data.json"
let homeBase = "TEB"  // Filter for TEB-based aircraft

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
    let pnr: String?
    let eventTypeName: String?
    let homeBase: String?
    
    init(from dict: [String: Any]) {
        self.start = dict["start"] as? String
        
        if let props = dict["extendedProps"] as? [String: Any] {
            self.id = props["uuid"] as? String ?? UUID().uuidString
            self.aircraft = props["aircraft"] as? String
            self.destination = props["destination_short"] as? String
            self.origin = props["origin_short"] as? String
            self.pnr = props["pnr"] as? String
            self.eventTypeName = props["event_type_name"] as? String
            self.homeBase = props["base"] as? String
            
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
        } else {
            self.id = UUID().uuidString
            self.aircraft = nil
            self.destination = nil
            self.origin = nil
            self.pnr = nil
            self.eventTypeName = nil
            self.homeBase = nil
            self.crew = nil
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
    
    // Try without UUID filter - fetch all aircraft
    return "\(baseURL)?start=\(startDate)&end=\(endDate)&time_zone=America%2FNew_York&view=rollingMonth&parallel_load=true"
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
    print("Fetching all flights...")
    
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
    
    let allFlights = json.map { Flight(from: $0) }
    print("Found \(allFlights.count) total events from all aircraft")
    
    return allFlights
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

func groupByTrip(_ flights: [Flight]) -> [String: [Flight]] {
    Dictionary(grouping: flights) { $0.pnr ?? $0.id }
}

func getEventIcon(_ eventType: String?) -> String {
    guard let type = eventType?.lowercased() else { return "📅" }
    
    if type.contains("maintenance") {
        return "🔧"
    } else if type.contains("flight") || type.contains("customer") {
        return "🛫"
    } else {
        return "📅"
    }
}

func simplifyEventType(_ eventType: String?) -> String {
    guard let type = eventType else { return "Event" }
    
    let lowerType = type.lowercased()
    if lowerType.contains("flight") || lowerType.contains("customer") {
        return "Flight"
    }
    
    return type
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
print("Filtering for aircraft based at: \(homeBase)")

guard let allFlights = fetchFlights() else {
    print("FATAL: Failed to fetch")
    exit(1)
}

// Filter for TEB-based aircraft only
let currentFlights = allFlights.filter { flight in
    // Try to determine if this aircraft is TEB-based
    // Option 1: Check if there's a "base" field
    if let base = flight.homeBase {
        return base == homeBase
    }
    
    // Option 2: Check if origin is TEB (most flights from TEB aircraft start there)
    if let origin = flight.origin {
        return origin == homeBase
    }
    
    // If we can't determine, include it for now
    return false
}

print("Filtered to \(currentFlights.count) events for \(homeBase)-based aircraft")

// Show which aircraft we found
let uniqueAircraft = Set(currentFlights.compactMap { $0.aircraft })
print("Aircraft found: \(uniqueAircraft.sorted().joined(separator: ", "))")

let upcomingFlights = currentFlights.filter { !$0.isPast() }
print("Upcoming: \(upcomingFlights.count)")

print("\n📋 Detected trips/events:")
for (tripKey, legs) in groupByTrip(upcomingFlights) {
    let route = buildFullRoute(for: legs)
    let aircraft = legs.first?.aircraft ?? "?"
    let eventType = legs.first?.eventTypeName ?? "Unknown"
    print("   \(tripKey.prefix(30)): \(legs.count) leg(s) - \(route) on \(aircraft) [\(eventType)]")
}

guard let previous = loadPreviousFlights() else {
    print("\n✓ First run - saving baseline")
    saveFlights(upcomingFlights)
    exit(0)
}

let previousUpcoming = previous.filter { !$0.isPast() }
let previousSet = Set(previousUpcoming)
let currentSet = Set(upcomingFlights)

print("\n🆕 Checking for new events...")
let newFlights = currentSet.subtracting(previousSet)
let newFlightsByTrip = groupByTrip(Array(newFlights))

print("   Found \(newFlightsByTrip.count) new trip(s)/event(s)")

for (tripKey, flights) in newFlightsByTrip {
    print("   Processing: \(tripKey.prefix(30))")
    
    guard let firstFlight = flights.sorted(by: { ($0.start ?? "") < ($1.start ?? "") }).first else { 
        continue 
    }
    
    let time = formatDateTime(firstFlight.start)
    let aircraft = firstFlight.aircraft ?? "Unknown"
    let route = buildFullRoute(for: flights)
    let eventType = simplifyEventType(firstFlight.eventTypeName)
    let icon = getEventIcon(firstFlight.eventTypeName)
    
    print("      Route: \(route)")
    print("      Legs: \(flights.count)")
    print("      Type: \(eventType)")
    
    if route.isEmpty {
        sendNotification("\(icon) \(eventType): \(time) on \(aircraft)")
    } else {
        sendNotification("\(icon) \(eventType): \(time) on \(aircraft) \(route)")
    }
}

print("\n👥 Checking for crew changes...")
let previousByTrip = groupByTrip(previousUpcoming)
let currentByTrip = groupByTrip(upcomingFlights)

var crewChanges = 0

for (tripKey, currentLegs) in currentByTrip {
    guard let previousLegs = previousByTrip[tripKey] else { continue }
    
    let prevCrew = Set(previousLegs.flatMap { $0.crew?.map { $0.name } ?? [] })
    let currCrew = Set(currentLegs.flatMap { $0.crew?.map { $0.name } ?? [] })
    
    if prevCrew != currCrew && !currCrew.isEmpty {
        crewChanges += 1
        print("   Trip: \(tripKey.prefix(30))")
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
