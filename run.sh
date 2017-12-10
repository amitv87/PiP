mkdir -p build
APP=build/PiP
clang pip/*.m -o $APP -fobjc-arc -fobjc-link-runtime -framework Cocoa -framework CoreGraphics -framework QuartzCore -framework OpenGL -O3 && ./$APP
