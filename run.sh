mkdir -p build
APP=build/PiP
clang -DNO_AIRPLAY -Iairplay -Wl,-dead_strip pip/*.m -o $APP -fobjc-arc -fobjc-link-runtime -O3 -g0 -Wno-deprecated-declarations -F /System/Library/PrivateFrameworks \
  -framework Cocoa -framework VideoToolbox -framework AudioToolbox -framework CoreMedia -framework CoreVideo -framework QuartzCore -framework OpenGL -framework Metal -framework MetalKit -framework PIP -framework SkyLight && ./$APP
