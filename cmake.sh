# curl -s https://linuxfromscratch.org/blfs/view/systemd/general/cmake.html

set -e
source envars.sh

if command -v cmake > /dev/null; then
	echo "::CMake is installed, exit"
	exit
fi

SRC_FILE=$(curl -sL https://cmake.org/files/LatestRelease/cmake-latest-files-v1.json|sed -n 's/.*name":\s\+"\(.*\)"/\1/p'|sed '/linux\|macos\|windows\|SHA\|\.zip/d')

wget -nv -c "https://cmake.org/files/LatestRelease/$SRC_FILE"
tar xf $SRC_FILE
cd ${SRC_FILE%.tar.*}

sed -i '/"lib64"/s/64//' Modules/GNUInstallDirs.cmake

./bootstrap --prefix=/usr \
	--system-libs \
	--mandir=/share/man \
	--no-system-jsoncpp \
	--no-system-cppdap \
	--no-system-librhash \
	--no-system-{libuv,nghttp2} \
	--datadir=/share/cmake \
	--parallel=$(nproc) \
	--generator=Ninja
ninja
ninja install
