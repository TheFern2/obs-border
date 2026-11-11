OBS_APP     ?= /Applications/OBS.app
OBS_VERSION ?= $(shell defaults read "$(OBS_APP)/Contents/Info.plist" CFBundleShortVersionString)
OBS_SRC     := deps/obs-studio-$(OBS_VERSION)
SIMDE_SRC   := deps/simde
FRAMEWORKS  := $(OBS_APP)/Contents/Frameworks
INSTALL_DIR ?= $(HOME)/Library/Application Support/obs-studio/plugins

NAME   := obs-border
BUNDLE := build/$(NAME).plugin
BIN    := $(BUNDLE)/Contents/MacOS/$(NAME)

CFLAGS := -arch arm64 -mmacosx-version-min=12.0 -O2 -Wall -Wextra -Wno-unused-parameter -fobjc-arc \
          -I$(OBS_SRC)/libobs -I$(OBS_SRC)/frontend/api -I$(SIMDE_SRC) -Ibuild/include
LDFLAGS := -bundle -F"$(FRAMEWORKS)" -framework libobs "$(FRAMEWORKS)/obs-frontend-api.dylib" \
           -framework Cocoa -Wl,-rpath,@executable_path/../Frameworks

.PHONY: all install uninstall clean distclean

all: $(BUNDLE)

# Headers only: OBS.app ships the libraries but not the headers.
$(OBS_SRC)/libobs/obs-module.h:
	git clone -q --depth 1 --branch $(OBS_VERSION) --filter=blob:none --sparse \
		https://github.com/obsproject/obs-studio.git $(OBS_SRC)
	git -C $(OBS_SRC) sparse-checkout set libobs frontend/api

# libobs headers include SIMDe, which OBS treats as an external dependency.
$(SIMDE_SRC)/simde/x86/sse2.h:
	git clone -q --depth 1 --branch v0.8.2 https://github.com/simd-everywhere/simde.git $(SIMDE_SRC)

build/include/obsconfig.h:
	mkdir -p build/include
	printf '#pragma once\n#define OBS_RELEASE_CANDIDATE 0\n#define OBS_BETA 0\n' > $@

$(BIN): src/obs-border.m $(OBS_SRC)/libobs/obs-module.h $(SIMDE_SRC)/simde/x86/sse2.h build/include/obsconfig.h
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	clang $(CFLAGS) $(LDFLAGS) -o $@ src/obs-border.m

$(BUNDLE): $(BIN) bundle/Info.plist $(wildcard data/locale/*.ini)
	cp bundle/Info.plist $(BUNDLE)/Contents/Info.plist
	rm -rf $(BUNDLE)/Contents/Resources && cp -R data $(BUNDLE)/Contents/Resources
	codesign --force --sign - $(BUNDLE)
	touch $(BUNDLE)

install: $(BUNDLE)
	mkdir -p "$(INSTALL_DIR)"
	rm -rf "$(INSTALL_DIR)/$(NAME).plugin"
	cp -R $(BUNDLE) "$(INSTALL_DIR)/"

uninstall:
	rm -rf "$(INSTALL_DIR)/$(NAME).plugin"

clean:
	rm -rf build

distclean: clean
	rm -rf deps
