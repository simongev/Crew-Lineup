#!/usr/bin/env swift

import Foundation

let urlToCheck = "https://portal.jetinsight.com/schedule/aircraft?view_name=rollingMonth&first_day=2026-02-04&time_zone=America/New_York" // CHANGE THIS
let ntfyTopic = "notify.sh/CrewLineup" // CHANGE THIS
let hashFile = "page-hash.txt"

func fetchPage() -> String? {
    guard let url = URL(string: urlToCheck) else { return nil }
    return try? String(contentsOf: url, encoding: .utf8)
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