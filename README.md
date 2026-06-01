# macOS Picture in Picture

<a href="https://github.com/amitv87/PiP/releases/latest"><img src="https://img.shields.io/github/downloads/amitv87/PiP/total" alt="Total Downloads"></a>
<a href="https://github.com/amitv87/PiP/releases/latest"><img src="https://img.shields.io/github/v/tag/amitv87/PiP" alt="App Version"></a>
<a href=""><img src="https://img.shields.io/github/repo-size/amitv87/PiP" alt="Repo Size"></a>
<a href="https://github.com/amitv87/PiP/stargazers"><img src="https://img.shields.io/github/stars/amitv87/PiP" alt="Repo Stars"></a>

Always on top window preview with AirPlay receiver support (if on macOS 12+, turn-off built-in AirPlay receiver from system preferences)

## Code Info
* Nibless cocoa app
* OpenGL/Metal renderer with HiDPI support
* CoreGraphics based capturer (looking for alternative)
* No third party dependency
* Uses private framework for native pip support
* AirPlay backend from https://github.com/FDH2/UxPlay and https://github.com/KqSMea8/AirplayServer

## Features
* Clone any visibile window
* Clone multiple active display
* Camera preview with audio monitoring
* HLS live streaming of any preview (window, display, or camera)
* Airplay sender (unstable)
* Crop the preview
* Auto and manual resize preserving the aspect ratio
* Multiple window preview from same process, ```cmd+n``` to open and ```cmd+w``` to close
* Pinch to zoom
* Native picture in picture support ```cmd+p```
* Transparency/opacity control (slider in right click menu)
* Minimal modern UI
* Upto 10 parallel airplay sessions (soft limit)

## Live Streaming

PiP can stream any preview window over your local network using HLS (HTTP Live Streaming). Any device with a web browser on the same network can watch the live feed.

### How to use
1. Right-click any active preview window and select **Broadcast > Broadcast This Window**
2. The stream URL (e.g. `http://192.168.1.42:8080`) appears at the bottom of the Broadcast menu
3. Open that URL on any device's browser to watch the live stream
4. Use **Copy URL** to copy the direct HLS stream URL (`/stream.m3u8`) or **Open in Browser** to open the web viewer

### Quality presets
| Preset | Resolution | Bitrate | FPS |
|--------|-----------|---------|-----|
| Low    | 720p      | 1.5 Mbps | 24 |
| Medium | 1080p     | 3 Mbps   | 30 |
| High   | Native    | 6 Mbps   | 30 |

Change quality on the fly via **Broadcast > Quality**.

### Architecture
The streaming pipeline is fully self-contained with no third-party dependencies:

```
Frame Capture → H.264 Video Encoder → MPEG-TS Muxer → HLS Writer → HTTP Server
                                             ↑
                                       Audio Capture
```

* **Frame Capture** – grabs RGBA frames from the preview's OpenGL/Metal renderer
* **Video Encoder** – hardware-accelerated H.264 encoding via VideoToolbox
* **TS Muxer** – multiplexes video (and optional audio) into MPEG-TS segments
* **HLS Writer** – manages a ring buffer of `.ts` segments and generates the `.m3u8` playlist
* **HTTP Server** – lightweight embedded server that serves the playlist, segments, and a built-in web viewer with hls.js

## Installation

### Manual download
<a href="http://github.com/amitv87/PiP/releases/latest"><img src="https://img.shields.io/github/v/tag/amitv87/PiP?sort=date" alt="Latest Release"></a> <a href="http://github.com/amitv87/PiP/releases/latest"><img src="https://img.shields.io/github/downloads/amitv87/pip/latest/total" alt="Latest Release"></a>

### Download and install via Homebrew
<a href="https://formulae.brew.sh/cask/amitv87-pip"><img src="https://img.shields.io/homebrew/cask/installs/dm/amitv87-pip" alt="Homebrew"></a>
```
brew install --cask amitv87-pip
```

### Build from source and run
```
# checkout code
git clone https://github.com/amitv87/PiP.git
cd pip

# build using xcode
xcodebuild -alltargets
open build/Release/PiP.app

# or simply
./run.sh
```
