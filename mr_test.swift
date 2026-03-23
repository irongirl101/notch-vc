import Foundation
import CoreGraphics
import Cocoa

typealias MRGetNowPlayingInfoFn = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
typealias MRGetIsPlayingFn = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void

let url = NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")
guard let b = CFBundleCreate(kCFAllocatorDefault, url) else {
    print("Failed to load MediaRemote")
    exit(1)
}

func load<T>(_ name: String, as type: T.Type) -> T? {
    guard let ptr = CFBundleGetFunctionPointerForName(b, name as CFString) else { return nil }
    return unsafeBitCast(ptr, to: type)
}

let mrGetIsPlaying = load("MRMediaRemoteGetNowPlayingApplicationIsPlaying", as: MRGetIsPlayingFn.self)
let mrGetNowPlayingInfo = load("MRMediaRemoteGetNowPlayingInfo", as: MRGetNowPlayingInfoFn.self)

let group = DispatchGroup()
group.enter()

mrGetIsPlaying?(DispatchQueue.main) { playing in
    print("Is Playing: \(playing)")
    group.leave()
}
group.wait()

group.enter()
mrGetNowPlayingInfo?(DispatchQueue.main) { dict in
    print("Now Playing Info Keys: \(dict.keys)")
    print("Title: \(String(describing: dict["kMRMediaRemoteNowPlayingInfoTitle"]))")
    print("Artist: \(String(describing: dict["kMRMediaRemoteNowPlayingInfoArtist"]))")
    print("Album: \(String(describing: dict["kMRMediaRemoteNowPlayingInfoAlbum"]))")
    group.leave()
}
group.wait()
