#!/usr/bin/env swift

import Foundation

let urlToCheck = "https://portal.jetinsight.com/schedule/aircraft?view_name=rollingMonth&first_day=2026-02-04&time_zone=America/New_York" // CHANGE THIS
let ntfyTopic = "notify.sh/CrewLineup" // CHANGE THIS
let hashFile = "page-hash.txt"

// Get credentials from environment variables
let username = ProcessInfo.processInfo.environment["PAGE_USERNAME"] ?? "gsimon@mandn.aero"
let password = ProcessInfo.processInfo.environment["PAGE_PASSWORD"] ?? "tecmim-0koxho-jebbUt"

func fetchPage() -> String? {
    guard let url = URL(string: urlToCheck) else { return nil }
    
    var request = URLRequest(url: url)
    request.timeoutInterval = 30
    
    // Add Basic Auth
    if !username.isEmpty && !password.isEmpty {
        let credentials = "\(username):\(password)"
        if let credentialsData = credentials.data(using: .utf8) {
            let base64Credentials = credentialsData.base64EncodedString()
            request.setValue("Basic \(base64Credentials)", forHTTPHeaderField: "Authorization")
        }
    }
    
    let semaphore = DispatchSemaphore(value: 0)
    var result: String?
    
    URLSession.shared.dataTask(with: request) { data, response, error in
        defer { semaphore.signal() }
        
        if let error = error {
            print("Error: \(error.localizedDescription)")
            return
        }
        
        if let httpResponse = response as? HTTPURLResponse {
            print("Status code: \(httpResponse.statusCode)")
        }
        
        if let data = data {
            result = String(data: data, encoding: .utf8)
        }
    }.resume()
    
    semaphore.wait()
    return result
}

func getHash(_ content: String) -> String {
    return String(content.utf8.reduce(0) { $0 &+ Int($1) })
}

func getPreviousHash() -> String? {
    return try? String(contentsOfFile: hashFile, encoding: .utf8)
}

func saveHash(_ hash: String) {
    try? hash.write(toFile: hashFile, atomically: true, encoding: .utf8)
}

func sendNotification(message: String) {
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

guard let content = fetchPage() else {
    print("Failed to fetch page")
    exit(1)
}

let currentHash = getHash(content)
let previousHash = getPreviousHash()

if previousHash != currentHash {
    if previousHash != nil {
        sendNotification("Page changed! \(urlToCheck)")
        print("Change detected, notification sent")
    } else {
        print("First run, saving hash")
    }
    saveHash(currentHash)
} else {
    print("No changes detected")
}
