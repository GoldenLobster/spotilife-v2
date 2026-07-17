import Foundation
import Combine

struct PipedSearchResponse: Codable {
    let items: [PipedSearchItem]?
}

struct PipedSearchItem: Codable {
    let url: String?
    let type: String?
    let title: String?
}

struct PipedStreamResponse: Codable {
    let audioStreams: [PipedAudioStream]?
}

struct PipedAudioStream: Codable {
    let url: String?
    let format: String?
    let mimeType: String?
    let bitrate: Int?
}

class DownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = DownloadManager()
    
    @Published var activeDownloads: [String: Double] = [:] // trackTitle -> progress (0.0 to 1.0)
    @Published var downloadedSongs: [String] = [] // filenames
    
    private var taskMap: [Int: (query: String, title: String, artist: String)] = [:]
    
    private let pipedInstances = [
        "https://pipedapi.kavin.rocks",
        "https://api.piped.yt",
        "https://piped-api.lunar.icu",
        "https://pipedapi.really.rocks"
    ]
    
    private lazy var downloadSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        return URLSession(configuration: configuration, delegate: self, delegateQueue: OperationQueue.main)
    }()
    
    private override init() {
        super.init()
        refreshDownloadedSongs()
    }
    
    func downloadTrack(title: String, artist: String) {
        let query = "\(artist) - \(title)"
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return }
        
        DispatchQueue.main.async {
            self.activeDownloads[query] = 0.0
        }
        
        writeDebugLog("[DOWNLOAD] Searching for \(query)...")
        
        performPipedRequest(path: "/search?q=\(encodedQuery)&filter=videos") { data, error in
            guard let data = data, error == nil else {
                writeDebugLog("[DOWNLOAD] Search failed for \(query)")
                self.removeActiveDownload(query)
                return
            }
            
            do {
                let response = try JSONDecoder().decode(PipedSearchResponse.self, from: data)
                guard let firstVideo = response.items?.first(where: { $0.type == "video" }),
                      let videoUrl = firstVideo.url,
                      let videoId = videoUrl.split(separator: "=").last else {
                    writeDebugLog("[DOWNLOAD] No video found for \(query)")
                    self.removeActiveDownload(query)
                    return
                }
                
                let videoIdStr = String(videoId)
                writeDebugLog("[DOWNLOAD] Found video ID \(videoIdStr) for \(query). Fetching streams...")
                self.fetchStreams(videoId: videoIdStr, title: title, artist: artist, query: query)
                
            } catch {
                writeDebugLog("[DOWNLOAD] Decoding search response failed: \(error.localizedDescription)")
                self.removeActiveDownload(query)
            }
        }
    }
    
    private func fetchStreams(videoId: String, title: String, artist: String, query: String) {
        performPipedRequest(path: "/streams/\(videoId)") { data, error in
            guard let data = data, error == nil else {
                writeDebugLog("[DOWNLOAD] Stream fetch failed for \(query)")
                self.removeActiveDownload(query)
                return
            }
            
            do {
                let response = try JSONDecoder().decode(PipedStreamResponse.self, from: data)
                guard let audioStreams = response.audioStreams, !audioStreams.isEmpty else {
                    writeDebugLog("[DOWNLOAD] No audio streams available for \(query)")
                    self.removeActiveDownload(query)
                    return
                }
                
                let chosenStream = audioStreams.first(where: { 
                    $0.format?.lowercased() == "m4a" || 
                    $0.mimeType?.lowercased().contains("mp4") == true ||
                    $0.mimeType?.lowercased().contains("m4a") == true
                }) ?? audioStreams.first!
                
                guard let streamUrlString = chosenStream.url, let streamUrl = URL(string: streamUrlString) else {
                    writeDebugLog("[DOWNLOAD] Invalid stream URL for \(query)")
                    self.removeActiveDownload(query)
                    return
                }
                
                writeDebugLog("[DOWNLOAD] Downloading audio for \(query) from \(streamUrlString)...")
                self.downloadAudioFile(from: streamUrl, title: title, artist: artist, query: query)
                
            } catch {
                writeDebugLog("[DOWNLOAD] Decoding streams failed: \(error.localizedDescription)")
                self.removeActiveDownload(query)
            }
        }
    }
    
    private func downloadAudioFile(from url: URL, title: String, artist: String, query: String) {
        let task = downloadSession.downloadTask(with: url)
        taskMap[task.taskIdentifier] = (query, title, artist)
        task.resume()
    }
    
    private func performPipedRequest(path: String, completion: @escaping (Data?, Error?) -> Void) {
        performPipedRequest(path: path, instanceIndex: 0, completion: completion)
    }
    
    private func performPipedRequest(path: String, instanceIndex: Int, completion: @escaping (Data?, Error?) -> Void) {
        guard instanceIndex < pipedInstances.count else {
            completion(nil, NSError(domain: "DownloadManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "All Piped instances failed"]))
            return
        }
        
        let instanceUrl = pipedInstances[instanceIndex]
        guard let url = URL(string: "\(instanceUrl)\(path)") else {
            self.performPipedRequest(path: path, instanceIndex: instanceIndex + 1, completion: completion)
            return
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 10.0
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                writeDebugLog("[DOWNLOAD] Instance \(instanceUrl) failed: \(error.localizedDescription)")
                self.performPipedRequest(path: path, instanceIndex: instanceIndex + 1, completion: completion)
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200, let data = data else {
                writeDebugLog("[DOWNLOAD] Instance \(instanceUrl) returned invalid response")
                self.performPipedRequest(path: path, instanceIndex: instanceIndex + 1, completion: completion)
                return
            }
            
            completion(data, nil)
        }
        task.resume()
    }
    
    func autoDownloadIfNeeded(title: String, artist: String) {
        let query = "\(artist) - \(title)"
        if activeDownloads[query] != nil { return }
        
        let safeTitle = title.replacingOccurrences(of: "/", with: "_")
        let safeArtist = artist.replacingOccurrences(of: "/", with: "_")
        let filename = "\(safeArtist) - \(safeTitle).m4a"
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fileURL = documentsURL.appendingPathComponent(filename)
        
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return
        }
        
        writeDebugLog("[DOWNLOAD] Auto-downloading track: \(query)")
        downloadTrack(title: title, artist: artist)
    }
    
    func refreshDownloadedSongs() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        do {
            let files = try FileManager.default.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil)
            let audioFiles = files.filter { 
                $0.pathExtension.lowercased() == "m4a" || 
                $0.pathExtension.lowercased() == "mp3" 
            }.map { $0.lastPathComponent }
            
            DispatchQueue.main.async {
                self.downloadedSongs = audioFiles.sorted()
            }
        } catch {
            writeDebugLog("[DOWNLOAD] Failed to scan documents directory: \(error.localizedDescription)")
        }
    }
    
    private func removeActiveDownload(_ query: String) {
        DispatchQueue.main.async {
            self.activeDownloads.removeValue(forKey: query)
        }
    }
    
    func deleteSong(filename: String) {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fileURL = documentsURL.appendingPathComponent(filename)
        do {
            try FileManager.default.removeItem(at: fileURL)
            writeDebugLog("[DOWNLOAD] Deleted song: \(filename)")
            refreshDownloadedSongs()
        } catch {
            writeDebugLog("[DOWNLOAD] Failed to delete song \(filename): \(error.localizedDescription)")
        }
    }
    
    // MARK: - URLSessionDownloadDelegate
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        
        if let info = taskMap[downloadTask.taskIdentifier] {
            DispatchQueue.main.async {
                self.activeDownloads[info.query] = progress
            }
        }
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let info = taskMap[downloadTask.taskIdentifier] else { return }
        
        defer {
            taskMap.removeValue(forKey: downloadTask.taskIdentifier)
            removeActiveDownload(info.query)
            refreshDownloadedSongs()
        }
        
        let safeTitle = info.title.replacingOccurrences(of: "/", with: "_")
        let safeArtist = info.artist.replacingOccurrences(of: "/", with: "_")
        let filename = "\(safeArtist) - \(safeTitle).m4a"
        
        do {
            let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let destinationURL = documentsURL.appendingPathComponent(filename)
            
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            
            try FileManager.default.moveItem(at: location, to: destinationURL)
            writeDebugLog("[DOWNLOAD] Successfully downloaded and saved \(filename)")
            
        } catch {
            writeDebugLog("[DOWNLOAD] Failed to save downloaded file \(filename): \(error.localizedDescription)")
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            writeDebugLog("[DOWNLOAD] Task failed: \(error.localizedDescription)")
            if let info = taskMap[task.taskIdentifier] {
                removeActiveDownload(info.query)
            }
            taskMap.removeValue(forKey: task.taskIdentifier)
        }
    }
}
