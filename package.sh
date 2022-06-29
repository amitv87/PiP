set -ex

SRC_ROOT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd $SRC_ROOT_DIR

xcodebuild -alltargets archive

APP_DIR="build/Release/PiP.app"
PLIST="$APP_DIR/Contents/Info.plist"

NAME=$(/usr/libexec/PlistBuddy -c "Print :CFBundleName" $PLIST)
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" $PLIST)

dmgbuild -s settings.py -D app=$APP_DIR $NAME build/$NAME-$VERSION.dmg
