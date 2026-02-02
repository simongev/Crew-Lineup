#!/usr/bin/env swift

import Foundation

let urlToCheck = "https://portal.jetinsight.com/schedule/aircraft?view_name=rollingMonth&first_day=2026-02-04&time_zone=America/New_York" // CHANGE THIS
let ntfyTopic = "notify.sh/CrewLineup" // CHANGE THIS
let hashFile = "page-hash.txt"

let username = ProcessInfo.processInfo.environment["PAGE_USERNAME"] ?? ""
let password = ProcessInfo.processInfo.environment["PAGE_PASSWORD"] ?? ""

func fetchPage() -> String? {
    print("Attempting to fetch: \(urlToCheck)")
    print("Username configured: \(!username.isEmpty)")
    
    guard let url = URL(string: urlToCheck) else {
        print("ERROR: Invalid URL")
        return nil
    }
    
    var request = URLRequest(url: url)
    request.timeoutInterval = 30
    
    if !username.isEmpty && !password.isEmpty {
        let credentials = "\(username):\(password)"
        if let credentialsData = credentials.data(using: .utf8) {
            let base64Credentials = credentialsData.base64EncodedString()
            request.setValue("Basic \(base64Credentials)", forHTTPHeaderField: "Authorization")
            print("Basic Auth header added")
        }
    }
    
    let semaphore = DispatchSemaphore(value: 0)
    var result: String?
    
    URLSession.shared.dataTask(with: request) { data, response, error in
        defer { semaphore.signal() }
        
        if let error = error {
            print("ERROR: \(error.localizedDescription)")
            return
        }
        
        if let httpResponse = response as? HTTPURLResponse {
            print("HTTP Status: \(httpResponse.statusCode)")
            
            if httpResponse.statusCode == 401 {
                print("ERROR: Authentication failed (401)")
            } else if httpResponse.statusCode >= 400 {
                print("ERROR: HTTP error \(httpResponse.statusCode)")
            }
        }
        
        if let data = data, let content = String(data: data, encoding: .utf8) {
            print("Content length: \(content.count) characters")
            print("First 200 chars: \(String(content.prefix(200)))")
            result = content
        } else {
            print("ERROR: No data or failed to decode")
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

func sendNotification(_ message: String) {
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

print("=== Starting page check ===")

guard let content = fetchPage() else {
    print("FATAL: Failed to fetch page")
    exit(1)
}

print("=== Page fetched successfully ===")

let currentHash = getHash(content)
let previousHash = getPreviousHash()

print("Current hash: \(currentHash)")
print("Previous hash: \(previousHash ?? "none")")

if previousHash != currentHash {
    if previousHash != nil {
        sendNotification("Page changed! \(urlToCheck)")
        print("✓ Change detected, notification sent")
    } else {
        print("✓ First run, saving hash")
    }
    saveHash(currentHash)
} else {
    print("✓ No changes detected")
}
