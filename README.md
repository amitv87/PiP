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
* Crop the preview
* Auto and manual resize preserving the aspect ratio
* Multiple window preview from same process, ```cmd+n``` to open and ```cmd+w``` to close
* Pinch to zoom
* Native picture in picture support ```cmd+p```
* Transparency/opacity control (slider in right click menu)
* Minimal modern UI
* Upto 10 parallel airplay sessions (soft limit)

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
