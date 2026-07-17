import Orion
import MediaPlayer
import Foundation

class MPNowPlayingInfoCenterHook: ClassHook<MPNowPlayingInfoCenter> {
    func setNowPlayingInfo(_ nowPlayingInfo: [String : Any]?) {
        orig.setNowPlayingInfo(nowPlayingInfo)
        
        guard UserDefaults.autoDownloadPlayedTracks else { return }
        
        if let info = nowPlayingInfo,
           let title = info[MPMediaItemPropertyTitle] as? String,
           let artist = info[MPMediaItemPropertyArtist] as? String {
            
            // Exclude empty titles/artists and advertisements
            if !title.isEmpty && !artist.isEmpty && title != "Advertisement" {
                DownloadManager.shared.autoDownloadIfNeeded(title: title, artist: artist)
            }
        }
    }
}
