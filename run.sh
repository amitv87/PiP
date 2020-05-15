mkdir -p build
APP=build/PiP
clang pip/*.m -o $APP -fobjc-arc -fobjc-link-runtime \
  -framework Cocoa -framework QuartzCore -framework OpenGL -framework Metal -framework MetalKit \
  /System/Library/PrivateFrameworks/PIP.framework/PIP -O3 -g0 -Wno-deprecated-declarations && ./$APP
