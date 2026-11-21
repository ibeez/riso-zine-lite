CC = clang
CFLAGS = -O2 -fobjc-arc
FRAMEWORKS = -framework Foundation -framework Vision -framework CoreImage -framework CoreGraphics -framework CoreVideo -framework ImageIO -framework UniformTypeIdentifiers

all: tools/cutout

tools/cutout: tools/cutout.m
	$(CC) $(CFLAGS) $(FRAMEWORKS) $< -o $@

clean:
	rm -f tools/cutout
