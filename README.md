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

## Important Notice for macOS Sequoia Users

With the release of macOS Sequoia, Apple has introduced stricter security measures that affect how unsigned apps are handled. If you encounter issues running PiP on macOS Sequoia, follow these steps to allow the app to run:

1. **Attempt to Open the App**: Double-click the PiP app. You may receive a warning that the app cannot be verified.
2. **Open Privacy & Security Settings**: Go to the Settings app, click on Privacy & Security.
3. **Scroll to Security Section**: Scroll down to the Security section at the very bottom.
4. **Allow the App**: You will see a note that reads "PiP was blocked to protect your Mac." Click the "Open Anyway" button.
5. **Authenticate**: You may need to authenticate with an admin account to confirm your choice.

For more details on these changes, you can refer to the [macOS Sequoia review](https://sixcolors.com/post/2024/09/macos-sequoia-review/#:~:text=Open%2520the%2520Settings%2520app%252C%2520click%2520on%2520Privacy%2520&%2520Security%252C%2520scroll%2520all%2520the%2520way%2520down%2520to%2520the%2520Security%2520section%2520at%2520the%2520very%2520bottom%252C%2520and%2520you%E2%80%99ll%2520see%2520a%2520note%2520that%2520reads%2520%E2%80%9C%5BApp%5D%2520was%2520blocked%2520to%2520protect%2520your%2520Mac.%E2%80%9D%2520There%E2%80%99s%2520an%2520Open%2520Anyway%2520button%2520here%2520you%2520can%2520click).

These steps are necessary due to Apple's increased focus on security, which requires additional user actions to run apps that are not notarized by Apple.
