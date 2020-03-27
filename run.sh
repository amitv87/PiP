mkdir -p build
APP=build/PiP
clang pip/*.m -o $APP -fobjc-arc -fobjc-link-runtime -framework Cocoa -framework QuartzCore -framework OpenGL /System/Library/PrivateFrameworks/PIP.framework/PIP -O3 -g0 && ./$APP
