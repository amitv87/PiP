# Mac OS X Picture in Picture

Always on top window preview similar to the popular windows only OnTopReplica

[![PiP demo](https://img.youtube.com/vi/MDte5sZCRnY/0.jpg)](https://www.youtube.com/watch?v=MDte5sZCRnY)

## Code Info
* Nibless cocoa app
* OpenGL based renderer
* CoreGraphics based capturer (looking for alternative)
* No third party dependency
* Uses private framework for native pip support

## Features
* Clone any visibile window
* Crop the preview
* Auto and manual resize preserving the aspect ratio
* Multiple window preview from same process, ```cmd+n``` to open and ```cmd+w``` to close
* Pinch to zoom
* Native picture in picture support ```cmd+p```
* Minimal modern UI

## To do
* Almost all the missing features when compared to [OnTopReplica](https://github.com/LorenzCK/OnTopReplica)

## Installation

### Manual download

[PiP-1.20.dmg](https://github.com/amitv87/PiP/releases/download/1.20/PiP-1.20.dmg)

### Download and install via Homebrew

```
brew cask install amitv87-pip
```

### Build from source and run

```
# checkout code
git clone https://github.com/amitv87/PiP.git
cd pip

# build using xcode
xcodebuild
open build/Release/PiP.app

# or simply
./run.sh

# right click on the window and select an option from the list
# right click again and select last option to crop the preview
```
