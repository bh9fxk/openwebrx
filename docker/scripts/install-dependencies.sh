#!/bin/bash
set -euxo pipefail
# measured 2026-10-28: -j8 on 4-vCPU runners brought no gain (amd64 8.7->9.1 min,
# arm64 7.5->7.2, arm/v7 78.1->84.2). Keep 1:1 with the core count.
export MAKEFLAGS="-j4"

function cmakebuild() {
  cd $1
  if [[ ! -z "${2:-}" ]]; then
    git checkout $2
  fi
  if [[ -f ".gitmodules" ]]; then
    git submodule update --init
  fi
  mkdir build
  cd build
  cmake ${CMAKE_ARGS:-} ..
  make
  make install
  cd ../..
  rm -rf $1
}

cd /tmp

STATIC_PACKAGES="libfftw3-single3 libfftw3-double3 python3 python3-setuptools python3-paho-mqtt netcat-openbsd libsndfile1 liblapack3 \
                 libusb-1.0-0 libqt5core5a libreadline8 libgfortran5 libgomp1 libasound2 libudev1 ca-certificates libpulse0 libfaad2 \
                 libopus0 libboost-program-options1.74.0 libboost-log1.74.0 libcurl4 libncurses6 libliquid1 libconfig++9v5"
BUILD_PACKAGES="wget git libsndfile1-dev libfftw3-dev cmake make gcc g++ liblapack-dev texinfo gfortran libusb-1.0-0-dev qtbase5-dev \
                qtmultimedia5-dev qttools5-dev libqt5serialport5-dev qttools5-dev-tools asciidoctor asciidoc libasound2-dev libudev-dev \
                libhamlib-dev patch xsltproc qt5-qmake libfaad-dev libopus-dev libboost-dev libboost-program-options-dev libboost-log-dev \
                libboost-regex-dev libpulse-dev libcurl4-openssl-dev libncurses-dev xz-utils libliquid-dev libconfig++-dev autoconf automake \
                meson ninja-build nlohmann-json3-dev libglib2.0-dev libqt5websockets5-dev"  # 2026.10.28 meson/ninja/nlohmann-json3-dev: redsea 1.3.0 起改用 meson 构建; libglib2.0-dev: dumphfdl/dumpvdl2 需要
apt-get update
apt-get -y install auto-apt-proxy
apt-get -y install --no-install-recommends $STATIC_PACKAGES $BUILD_PACKAGES

case `uname -m` in
    arm*)
        PLATFORM=armhf
        ;;
    aarch64*)
        PLATFORM=aarch64
        ;;
    x86_64*)
        PLATFORM=x86_64
        ;;
esac

# 2026.10.28: v3.1.5.0 -> v3.2.3.2. Still supports the legacy
# /etc/services.d layout and S6_CMD_ARG0 used by openwebrx. Note that 3.2.0.0
# removed the default service startup timeout.
S6_OVERLAY_VERSION=v3.2.3.2
wget https://github.com/just-containers/s6-overlay/releases/download/${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz
tar -Jxpf /tmp/s6-overlay-noarch.tar.xz -C /
rm s6-overlay-noarch.tar.xz

wget https://github.com/just-containers/s6-overlay/releases/download/${S6_OVERLAY_VERSION}/s6-overlay-${PLATFORM}.tar.xz
tar -Jxpf /tmp/s6-overlay-${PLATFORM}.tar.xz -C /
rm s6-overlay-${PLATFORM}.tar.xz

# PINNED at 2.2.0 - do not upgrade to 2.3.x (verified 2026-10-29):
#   1) 2.3.0 removed Fortran and shared memory, which also removed the `js8`
#      headless decoder target. openwebrx spawns exactly that binary
#      (owrx/js8.py -> ["js8", "--js8", "-b", <submode>, "-d", <depth>]) and
#      the js8call-hamlib.patch below keeps only `install (TARGETS js8 ...)`,
#      so a 2.3.x build would have nothing left to install.
#   2) 2.3.0 is Qt6-only and "64-bit only": it needs qt6-*-dev plus
#      Boost >= 1.77 (bookworm ships 1.74) and would drop the armv7 image.
#   3) 2.3.0 removed the variable decode depth, i.e. the -d flag above.
JS8CALL_VERSION=2.2.0
# 2.2.0 corresponds to the "v2.2.0-ga" tag in the upstream git repository
JS8CALL_TAG=v${JS8CALL_VERSION}-ga
JS8CALL_DIR=js8call
# NOTE: the upstream download host files.js8call.com now serves an expired TLS
# certificate (2026-09), which makes wget bail out with exit code 5. Pull the
# release sources from the official git repository instead. A shallow clone is
# enough: the project has no submodules and its version comes from Versions.cmake,
# not from `git describe`.
git clone --depth 1 -b ${JS8CALL_TAG} https://github.com/js8call/js8call.git ${JS8CALL_DIR}
# patch allows us to build against the packaged hamlib
patch -Np1 -d ${JS8CALL_DIR} < /js8call-hamlib.patch
rm /js8call-hamlib.patch
cmakebuild ${JS8CALL_DIR}

# 3.0 moved the canonical sources to GitHub. SourceForge still hosts the older
# releases, but renamed the archive to <name>-src.tar.gz and ships it wrapped in
# a "superbuild" CMakeLists that builds hamlib via ExternalProject. Taking the
# GitHub tag archive gives us the real wsjtx source tree instead, so the
# wsjtx-hamlib.patch (which stripped that bundled hamlib ExternalProject) is no
# longer needed: the plain build calls find_package (Hamlib) and links the
# packaged libhamlib-dev.
#
# wsjtx.patch has been regenerated against 3.0.2: it keeps the headless targets
# openwebrx needs (jt9, wsprd, wsjtx_app_version) and drops the Qt5 GUI
# application, udp_daemon, message_aggregator, qmap/map65, tests, manpages and
# the debian/desktop packaging. Note that 3.0 adds Qt5 WebSockets to the
# required components - see libqt5websockets5-dev in BUILD_PACKAGES.
WSJT_VERSION=3.0.2
WSJT_DIR=wsjtx-${WSJT_VERSION}
WSJT_TGZ=${WSJT_DIR}.tar.gz
wget -O ${WSJT_TGZ} https://github.com/WSJTX/wsjtx/archive/refs/tags/v${WSJT_VERSION}.tar.gz
tar xfz ${WSJT_TGZ}
patch -Np1 -d ${WSJT_DIR} < /wsjtx.patch
cmakebuild ${WSJT_DIR}
rm ${WSJT_TGZ}

git clone https://github.com/alexander-sholohov/msk144decoder.git
# latest from main as of 2024-06-07; upstream ships no release tags  # 2026.10.28
# this commit fixes parallel builds, but MAKEFLAGS="" is kept so the build stays
# single-threaded and reproducible on all three architectures.
MAKEFLAGS="" cmakebuild msk144decoder 761d0b3a61cde664d4c25b1c6ff1d9c0e395af23

# 2025.12.1
cd /tmp
git clone --depth 1 -b 1.8.1 https://github.com/wb2osz/direwolf.git
cd direwolf
# hamlib is present (necessary for the wsjt-x and js8call builds) and would be used, but there's no real need.
# this patch prevents direwolf from linking to it, and it can be stripped at the end of the script.
patch -Np1 < /direwolf-hamlib.patch
mkdir build
cd build
cmake ..
make
make install
cd ../..
rm -rf direwolf
# strip lots of generic documentation that will never be read inside a docker container
rm /usr/local/share/doc/direwolf/*.pdf
# examples are pointless, too
rm -rf /usr/local/share/doc/direwolf/examples/

# 2025.12.1
cd /tmp
git clone https://github.com/drowe67/codec2.git
cd codec2
git checkout 1.2.0
mkdir build
cd build
cmake ..
make
make install
install -m 0755 src/freedv_rx /usr/local/bin
cd ../..
rm -rf codec2

wget https://downloads.sourceforge.net/project/drm/dream/2.1.1/dream-2.1.1-svn808.tar.gz
tar xvfz dream-2.1.1-svn808.tar.gz
pushd dream
patch -Np0 < /dream.patch
qmake CONFIG+=console
make
make install
popd
rm -rf dream
rm dream-2.1.1-svn808.tar.gz

# 2025.12.1
cd /tmp
git clone https://github.com/mobilinkd/m17-cxx-demod.git
cmakebuild m17-cxx-demod v2.3

# 2025.12.1 -> v11.1 (2026.10.28)
cd /tmp
# v11.1 adds a "starch" submodule, but the generated DSP sources under dsp/generated/
# are committed to the repo and the Makefile never references starch/, so a plain
# shallow clone is sufficient (no --recurse-submodules needed).
# --iformat / --raw / --ifile are all still supported, which openwebrx relies on.
git clone --depth 1 -b v11.1 https://github.com/flightaware/dump1090
cd dump1090
make
install -m 0755 dump1090 /usr/local/bin
cd ..
rm -rf dump1090

git clone https://github.com/merbanan/rtl_433.git
# 25.12 release (2025-12), up from a 2023-09-06 master snapshot  # 2026.10.28
# ENABLE_RTLSDR=OFF keeps the rtl-sdr dependency out. The options openwebrx uses
# (-r cf32:-, -F json, -M time:unix, -C si) are unchanged in 25.12.
CMAKE_ARGS="-DENABLE_RTLSDR=OFF" cmakebuild rtl_433 25.12

git clone https://github.com/szpajder/libacars.git
# v2.2.1; libacars is a prerequisite of dumphfdl and dumpvdl2  # 2026.10.28
cmakebuild libacars v2.2.1

git clone https://github.com/szpajder/dumphfdl
# v1.7.0; needs libacars >= 2.1.0 (built above) and glib2 >= 2.46  # 2026.10.28
# --iq-file / --sample-format / --sample-rate / --output are unchanged.
cmakebuild dumphfdl v1.7.0

git clone https://github.com/szpajder/dumpvdl2.git
# v2.7.0; needs libacars >= 2.1.0 (built above) and glib2  # 2026.10.28
# v2.7.0 only adds options (bias, max-ppm), none removed, so the openwebrx
# command line (--iq-file / --oversample / --sample-format / --output) still works.
cmakebuild dumpvdl2 v2.7.0

cd /tmp
git clone https://github.com/windytan/redsea.git
pushd redsea
# v1.3.1 (released 2026-07-06)  # 2026.10.28
# upstream switched the build system from autotools to meson in 1.3.0,
# so autogen.sh / configure no longer exist. It also needs nlohmann_json >= 3.9.0
# (bookworm ships 3.11.2, installed in BUILD_PACKAGES above).
# --samplerate, --rbds and the default "mpx" input are unchanged, so openwebrx
# keeps working with the same command line.
git checkout v1.3.1
meson setup build
ninja -C build
ninja -C build install
popd
rm -rf redsea

git clone https://github.com/Opendigitalradio/dablin.git
CMAKE_ARGS="-DDISABLE_SDL=1" cmakebuild dablin 1.16.1 # 2025.11.30

git clone https://github.com/hessu/aprs-symbols /usr/share/aprs-symbols
pushd /usr/share/aprs-symbols
git checkout f2286a9cd43eb6ba4501250b4c39fff111e3796c
# remove unused files (including git meta information)
rm -rf .git aprs-symbols.ai aprs-sym-export.js
popd

apt-get -qq update # 2025.11.30
apt-get -y purge --autoremove --allow-remove-essential $BUILD_PACKAGES # --allow-remove-essential
apt-get -y autoremove # 2025.11.30
apt-get -y autoclean
rm -rf /var/lib/apt/lists/*
rm -rf /tmp/*
