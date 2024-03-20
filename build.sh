#!/bin/bash

set -e
source envars.sh

ELIBC=gnu
STDLIB=libcxx
VERSION=17.0.6
PKG="$PWD/DEST"
URL="https://github.com/llvm/llvm-project"

SRC=(
	${URL}/releases/download/llvmorg-${VERSION}/llvm-${VERSION}.src.tar.xz
	${URL}/releases/download/llvmorg-${VERSION}/cmake-${VERSION}.src.tar.xz
	${URL}/releases/download/llvmorg-${VERSION}/third-party-${VERSION}.src.tar.xz

	${URL}/releases/download/llvmorg-${VERSION}/clang-${VERSION}.src.tar.xz
	${URL}/releases/download/llvmorg-${VERSION}/compiler-rt-${VERSION}.src.tar.xz
	${URL}/releases/download/llvmorg-${VERSION}/lld-${VERSION}.src.tar.xz
	${URL}/releases/download/llvmorg-${VERSION}/libunwind-${VERSION}.src.tar.xz
)
# /build/llvm-17.0.6.src/tools/lld/MachO/Target.h:23:10: fatal error: mach-o/compact_unwind_encoding.h: No such file or directory
#    23 | #include "mach-o/compact_unwind_encoding.h"

for arg in $@; do
	case "$arg" in
		musl)
			ELIBC=musl
			;;
		nolibcxx|stdc++)
			STDLIB=libstdc++
			;;
		uclibc)
			ELIBC=uclibc
			STDLIB=libstdc++
			;;
	esac
done

if [[ $STDLIB = libcxx ]]; then
	SRC+=(
		${URL}/releases/download/llvmorg-${VERSION}/libcxx-${VERSION}.src.tar.xz
		${URL}/releases/download/llvmorg-${VERSION}/libcxxabi-${VERSION}.src.tar.xz
		${URL}/releases/download/llvmorg-${VERSION}/runtimes-${VERSION}.src.tar.xz
	)
fi

rm -rf libunwind llvm-${VERSION}.src
for i in ${SRC[@]}; do
	wget -nv -c $i
	f=$(basename $i)
	if [[ $f = *.src.tar.xz && ! -d ${f%.tar.xz} ]]; then
		echo "Extracting $f..."
		tar xf $f &
	fi
done

cd llvm-${VERSION}.src
sed '/LLVM_COMMON_CMAKE_UTILS/s@../cmake@LLVM-cmake.src@'          \
    -i CMakeLists.txt
sed '/LLVM_THIRD_PARTY_DIR/s@../third-party@LLVM-third-party.src@' \
    -i cmake/modules/HandleLLVMOptions.cmake

while pidof -q tar; do sleep 0.1; done
mv ../cmake-${VERSION}.src LLVM-cmake.src
mv ../third-party-${VERSION}.src LLVM-third-party.src
mv ../clang-${VERSION}.src tools/clang
mv ../lld-${VERSION}.src tools/lld
mv ../libunwind-${VERSION}.src projects/libunwind
mv ../compiler-rt-${VERSION}.src projects/compiler-rt
sed '/^set(LLVM_COMMON_CMAKE_UTILS/d' -i projects/{compiler-rt,libunwind}/CMakeLists.txt
ln -sr projects/libunwind ..

if [[ $STDLIB = libcxx ]]; then
	mv ../libcxx-${VERSION}.src projects/libcxx
	mv ../libcxxabi-${VERSION}.src projects/libcxxabi
	cp -ri ../runtimes-${VERSION}.src/cmake/* LLVM-cmake.src  # libc++abi testing configuration
	mv ../runtimes-${VERSION}.src LLVM-runtimes.src
	sed -e '/^set(LLVM_COMMON_CMAKE_UTILS/s@../cmake@../LLVM-cmake.src@' \
		-e '/LLVM_THIRD_PARTY_DIR/s@../third-party@../LLVM-third-party.src@' \
		-e '/..\/llvm\(\/\|)\)/s/\/llvm//' \
		-e '/${CMAKE_CURRENT_SOURCE_DIR}\/..\/${proj}/s/${proj}/projects\/&/' \
		-i LLVM-runtimes.src/CMakeLists.txt
	sed '/CMAKE_CURRENT_SOURCE_DIR/s@../runtimes@LLVM-runtimes.src@' \
		-i runtimes/CMakeLists.txt
	sed '/^set(LLVM_COMMON_CMAKE_UTILS/d' -i projects/libcxx{,abi}/CMakeLists.txt
	sed 's@../runtimes@LLVM-runtimes.src@' -i \
		projects/compiler-rt/cmake/Modules/AddCompilerRT.cmake \
		projects/compiler-rt/lib/sanitizer_common/symbolizer/scripts/build_symbolizer.sh
	sed -i '/LIBCXXABI_USE_LLVM_UNWINDER AND/s/ NOT//' projects/libcxxabi/CMakeLists.txt
	_args=(-DLIBCXX{,ABI}_INSTALL_LIBRARY_DIR=lib)
else
	for M in {HandleFlags,WarningFlags}.cmake; do
		if [ ! -e projects/libunwind/cmake/Modules/$M ]; then
			wget -nv -cP projects/libunwind/cmake/Modules \
				${URL}/raw/llvmorg-${VERSION}/runtimes/cmake/Modules/$M
		fi
	done
fi

grep -rl '#!.*python' | xargs sed -i '1s/python$/python3/'

NOSANITIZERS_ARGS=(
	-DCOMPILER_RT_BUILD_{SANITIZERS,LIBFUZZER}=OFF
	-DCOMPILER_RT_BUILD_{MEMPROF,ORC,PROFILE,XRAY}=OFF
)

src_config() {
	local _flags=(
	   -DCLANG_DEFAULT_RTLIB=compiler-rt
	   -DCLANG_DEFAULT_UNWINDLIB=libunwind
	   -DCLANG_DEFAULT_OBJCOPY=llvm-objcopy
	)

	[[ $ELIBC = uclibc ]] || _flags+=(-DLLVM_ENABLE_LLD=ON -DCLANG_DEFAULT_LINKER=lld)

	if [[ $STDLIB = libcxx ]]; then
		_flags+=(
		  -DLIBCXX{,ABI}_USE_COMPILER_RT=ON
		  -DLIBCXX_HAS_ATOMIC_LIB=OFF
		  -DSANITIZER_CXX_ABI=libcxxabi
		  -DCLANG_DEFAULT_CXX_STDLIB=libc++
		)
	else
		_flags+=(
		   -DCLANG_DEFAULT_CXX_STDLIB=libstdc++
		   -DCLANG_DEFAULT_OPENMP_RUNTIME=libgomp
		)
	fi

	if command -v clang{,++} > /dev/null; then
		[[ $STDLIB != libcxx ]] || CXXFLAGS="${CXXFLAGS/_GLIBCXX_ASSERTIONS/_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_EXTENSIVE}"
		CC=clang CXX=clang++ "$@" \
		-DLIBUNWIND_USE_COMPILER_RT=ON \
		-DCOMPILER_RT_USE_BUILTINS_LIBRARY=ON \
		"${_flags[@]}"
	else
		CC=gcc CXX=g++ "$@" \
		-DLLVM_USE_LINKER=gold
	fi
}

if [[ $ELIBC = musl ]]; then
	_args+=(-DCOMPILER_RT_BUILD_GWP_ASAN=OFF)
	[[ $STDLIB != libcxx ]] || _args+=(-DLIBCXX_HAS_MUSL_LIBC=ON)
	[[ $(gcc -dumpmachine) != i?86-*-musl ]] || _args+=(${NOSANITIZERS_ARGS[@]})
elif [[ $ELIBC = uclibc ]]; then
	patch -Np1 -d tools/clang < ../clang-uClibc-dynamic-linker-path.patch
	_args+=(${NOSANITIZERS_ARGS[@]})
fi

if [[ $(gcc -dumpmachine) = i?86-* ]]; then
	_args+=(-DCOMPILER_RT_INSTALL_PATH="/usr/lib/clang/${VERSION%%.*}")
fi

mkdir -v build
cd build

src_config \
cmake -DCMAKE_INSTALL_PREFIX=/usr           \
      -DLLVM_ENABLE_FFI=ON                  \
      -DCMAKE_BUILD_TYPE=Release            \
      -DLLVM_BUILD_LLVM_DYLIB=ON            \
      -DLLVM_LINK_LLVM_DYLIB=ON             \
      -DLLVM_ENABLE_RTTI=ON                 \
      -DLLVM_TARGETS_TO_BUILD="host;AMDGPU" \
      -DLLVM_BINUTILS_INCDIR=/usr/include   \
      -DLLVM_INCLUDE_BENCHMARKS=OFF         \
      -DCLANG_DEFAULT_PIE_ON_LINUX=ON       \
      -DLLVM_BUILD_TESTS=OFF \
      -DLLVM_INCLUDE_TESTS=OFF \
      -DLLVM_HOST_TRIPLE=$(gcc -dumpmachine) \
      -DCLANG_CONFIG_FILE_SYSTEM_DIR=/usr/lib/clang \
      -DLIBUNWIND_INSTALL_LIBRARY_DIR:PATH=lib \
      -Wno-dev -G Ninja "${_args[@]}" ..

echo 'int main(){}' > main.c
if gcc -m32 main.c 2> /dev/null; then
	sed -i '/-m32 /s/-march=x86-64\(\|-v[2-4]\)/-march=i686/g' build.ninja
fi
rm -f a.out

ninja
ninja install
rm -rf $PKG
DESTDIR=$PKG ninja install &> /dev/null

# https://packages.gentoo.org/packages/sys-devel/clang-common
cat > $PKG/usr/lib/clang/clang.cfg <<-EOF
	# It is used to control the default runtimes using by clang.

	--rtlib=compiler-rt
	--unwindlib=libunwind
	--stdlib=libc++
	-fuse-ld=lld
	-fstack-protector-strong
EOF

if [[ $STDLIB != libcxx ]]; then
	sed -i '/--stdlib=libc++$/d' $PKG/usr/lib/clang/clang.cfg
fi

if [[ $ELIBC = uclibc ]]; then
	sed -i '/-fuse-ld=lld/d' $PKG/usr/lib/clang/clang.cfg
fi

ln -s clang.cfg "$PKG/usr/lib/clang/clang++.cfg"
cp -d $PKG/usr/lib/clang/*.cfg "/usr/lib/clang/"

echo "$VERSION" > $PKG/../VERSION
clang -v main.c
readelf -ln a.out | grep '/lib'
./a.out

for d in {$PKG,}/; do
	cxxdir="${d}usr/include/$(gcc -dumpmachine)/c++/v1"
	[ -f "$cxxdir/__config_site" ] || continue
	mv $cxxdir/{*,../../../c++/v1}
	rmdir -p $cxxdir --ignore-fail-on-non-empty
done
