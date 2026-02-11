#!/usr/bin/env swift

import Foundation

let schedulePageURL = "https://portal.jetinsight.com/schedule"
let apiBaseURL = "https://portal.jetinsight.com/schedule/aircraft.json"
let homeBase = "TEB"
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
    let pnr: String?
    let eventTypeName: String?
    
    init(from dict: [String: Any]) {
        self.start = dict["start"] as? String
        
        if let props = dict["extendedProps"] as? [String: Any] {
            self.id = props["uuid"] as? String ?? UUID().uuidString
            self.aircraft = props["aircraft"] as? String
            self.destination = props["destination_short"] as? String
            self.origin = props["origin_short"] as? String
            self.pnr = props["pnr"] as? String
            self.eventTypeName = props["event_type_name"] as? String
            
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
            self.crew = nil
        }
    }
    
    func isPast() -> Bool {
        guard let startString = start else { return false }
        let formatter = ISO8601DateFormatter()
        guard let startDate = formatter.date(from: startString) else { return false }
        return startDate < Date()
    }
    
    func shouldNotify() -> Bool {
        guard let eventType = eventTypeName?.lowercased() else { return true }
        return !eventType.contains("repositioning")
    }
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

func fetchTEBAircraftUUIDs() -> [String]? {
    print("Fetching TEB aircraft from compliance endpoint...")
    
    // Try the compliance endpoint first
    let complianceURL = "https://portal.jetinsight.com/compliance/aircraft_readiness"
    let command = "curl -s --max-time 30 -H 'Cookie: _app_session=\(sessionCookie)' '\(complianceURL)'"
    let result = runCommand(command)
    
    if result.exitCode != 0 {
        print("ERROR: Failed to fetch compliance data")
        return nil
    }
    
    guard let data = result.output.data(using: .utf8),
          let json = try? JSON
