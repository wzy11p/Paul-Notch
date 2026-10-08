import Foundation

@main
struct QQNowPlayingValidation {
    static func main() {
        let playing = QQNowPlaying.parse(trackLabel: "歌曲名：测试歌曲 - 歌手名：测试歌手", buttonLabels: ["上一首", "暂停播放", "下一首"])
        precondition(playing.title == "测试歌曲" && playing.artist == "测试歌手" && playing.isPlaying == true)
        precondition(playing.actionSymbol == "pause.fill" && playing.actionLabel == "暂停")
        let paused = QQNowPlaying.parse(trackLabel: "歌曲名：测试歌曲 - 歌手名：测试歌手", buttonLabels: ["播放"])
        precondition(paused.isPlaying == false && paused.title == playing.title)
        precondition(paused.actionSymbol == "play.fill" && paused.actionLabel == "播放")
        let switchTrack = QQNowPlaying.parse(trackLabel: "歌曲名：A - B 🎧 - 歌手名：甲 / 乙", buttonLabels: ["暂停"])
        precondition(switchTrack.title == "A - B 🎧" && switchTrack.artist == "甲 / 乙")
        let idle = QQNowPlaying.parse(trackLabel: "QQ音乐 - 听我想听", buttonLabels: ["播放"])
        precondition(idle.title == nil && idle.artist == nil && idle.isPlaying == false)
        let missing = QQNowPlaying.parse(trackLabel: nil, buttonLabels: [])
        precondition(missing.title == nil && missing.isPlaying == nil)
        precondition(missing.actionSymbol == "playpause.fill" && missing.actionLabel == "播放/暂停")
        let conflict = QQNowPlaying.parse(trackLabel: nil, buttonLabels: ["播放", "暂停播放"])
        precondition(conflict.isPlaying == nil)
        let unfamiliar = QQNowPlaying.parse(trackLabel: "播放列表 这里不是当前歌曲", buttonLabels: ["全部播放"])
        precondition(unfamiliar.title == nil && unfamiliar.isPlaying == nil)
        let noArtist = QQNowPlaying.parse(trackLabel: "歌曲名：只有歌名", buttonLabels: ["Play"])
        precondition(noArtist.title == "只有歌名" && noArtist.artist == nil)
        let empty = QQNowPlaying.parse(trackLabel: "歌曲名：  - 歌手名： ", buttonLabels: ["继续播放"])
        precondition(empty.title == nil && empty.artist == nil)
        let ascii = QQNowPlaying.parse(trackLabel: "歌曲名: 中文 - 歌手名: Artist", buttonLabels: ["Pause"])
        precondition(ascii.title == "中文" && ascii.artist == "Artist" && ascii.isPlaying == true)
        print("PASS: 10 QQ now-playing parsing cases; no player access or permission changes")
    }
}
