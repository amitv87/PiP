# macOS Picture in Picture

Always on top window preview similar to the popular windows only OnTopReplica

Now with AirPlay receiver support (if on macOS 12+, turn-off built-in AirPlay receiver from system preferences)

[![PiP demo](https://img.youtube.com/vi/MDte5sZCRnY/0.jpg)](https://www.youtube.com/watch?v=MDte5sZCRnY)

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
* Crop the preview
* Auto and manual resize preserving the aspect ratio
* Multiple window preview from same process, ```cmd+n``` to open and ```cmd+w``` to close
* Pinch to zoom
* Native picture in picture support ```cmd+p```
* Transparency/opacity control (slider in right click menu)
* Minimal modern UI
* Upto 10 parallel airplay sessions (soft limit)

## To do
* Almost all the missing features when compared to [OnTopReplica](https://github.com/LorenzCK/OnTopReplica)

## Installation

### Manual download

[PiP-2.60.dmg](https://github.com/amitv87/PiP/releases/download/v2.60/PiP-2.60.dmg)

### Download and install via Homebrew

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
