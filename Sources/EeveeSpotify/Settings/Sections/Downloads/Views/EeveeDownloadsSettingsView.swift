import SwiftUI

struct EeveeDownloadsSettingsView: View {
    @StateObject private var downloadManager = DownloadManager.shared
    @State private var currentTrack: (title: String, artist: String)? = nil
    @State private var autoDownloadPlayedTracks = UserDefaults.autoDownloadPlayedTracks
    
    let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()
    
    var body: some View {
        List {
            Section(
                header: Text("Options"),
                footer: Text("Automatically search and download any song you play to your Local Files.")
            ) {
                Toggle(
                    "auto_download_played_songs".localized,
                    isOn: $autoDownloadPlayedTracks
                )
                .onChange(of: autoDownloadPlayedTracks) { newValue in
                    UserDefaults.autoDownloadPlayedTracks = newValue
                }
            }
            
            Section(header: Text("currently_playing".localized)) {
                if let track = currentTrack {
                    let query = "\(track.artist) - \(track.title)"
                    
                    HStack {
                        VStack(alignment: .leading) {
                            Text(track.title)
                                .font(.headline)
                            Text(track.artist)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        if let progress = downloadManager.activeDownloads[query] {
                            HStack(spacing: 8) {
                                Text("\(Int(progress * 100))%")
                                    .font(.footnote)
                                    .foregroundColor(.gray)
                                ProgressView(value: progress)
                                    .progressViewStyle(CircularProgressViewStyle())
                            }
                        } else if downloadManager.downloadedSongs.contains("\(track.artist.replacingOccurrences(of: "/", with: "_")) - \(track.title.replacingOccurrences(of: "/", with: "_")).m4a") ||
                                    downloadManager.downloadedSongs.contains("\(track.artist.replacingOccurrences(of: "/", with: "_")) - \(track.title.replacingOccurrences(of: "/", with: "_")).mp3") {
                            Text("Downloaded ✅")
                                .font(.footnote)
                                .foregroundColor(.green)
                        } else {
                            Button("Download") {
                                downloadManager.downloadTrack(title: track.title, artist: track.artist)
                            }
                            .buttonStyle(BorderlessButtonStyle())
                            .foregroundColor(EeveeSettingsView.spotifyAccentColor)
                        }
                    }
                } else {
                    Text("No song currently playing")
                        .foregroundColor(.secondary)
                }
            }
            
            Section(
                header: Text("\("downloaded_songs".localized) (\(downloadManager.downloadedSongs.count))"),
                footer: Text("To listen to downloaded files, ensure 'Local audio files' is toggled on in Spotify's Settings > Apps and devices, then look for the 'Local Files' playlist in your Library.")
            ) {
                if downloadManager.downloadedSongs.isEmpty {
                    Text("No downloaded songs yet")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(downloadManager.downloadedSongs, id: \.self) { filename in
                        HStack {
                            Image(systemName: "music.note")
                                .foregroundColor(.green)
                            Text(filename.replacingOccurrences(of: ".m4a", with: "").replacingOccurrences(of: ".mp3", with: ""))
                                .font(.body)
                        }
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            let filename = downloadManager.downloadedSongs[index]
                            downloadManager.deleteSong(filename: filename)
                        }
                    }
                }
            }
            
            NonIPadSpacerView()
        }
        .listStyle(GroupedListStyle())
        .navigationTitle("downloads".localized)
        .onAppear {
            currentTrack = getCurrentTrack()
            downloadManager.refreshDownloadedSongs()
        }
        .onReceive(timer) { _ in
            currentTrack = getCurrentTrack()
        }
    }
    
    private func getCurrentTrack() -> (title: String, artist: String)? {
        if let player = statefulPlayer, let track = player.currentTrack() {
            return (track.trackTitle(), track.artistName())
        }
        if let track = nowPlayingScrollViewController?.loadedTrack {
            return (track.trackTitle(), track.artistName())
        }
        return nil
    }
}
