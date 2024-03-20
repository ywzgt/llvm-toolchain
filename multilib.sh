#!/bin/bash

set -e
source envars.sh

VERSION=17.0.6
PKG="$PWD/DEST"
SRC=(
	cmake
	compiler-rt
	libcxx
	libcxxabi
	libunwind
	llvm
	runtimes
	third-party
)

pre_src() {
	rm -rf bld_multi; mkdir bld_multi
	for f in ${SRC[@]}; do
		tar xf $f-${VERSION}.src.tar.xz -C bld_multi
		ln -srv bld_multi/$f{-$VERSION.src,}
	done

	cd bld_multi
	install -Dm755 /dev/stdin ./i386-pc-linux-gnu-gcc <<-"EOF"
	#!/bin/sh
		exec gcc -m32 $@
	EOF

	install -Dm755 /dev/stdin ./i386-pc-linux-gnu-g++ <<-"EOF"
	#!/bin/sh
		exec g++ -m32 $@
	EOF

	ln -s /bin/clang i386-pc-linux-gnu-clang
	ln -s /bin/clang++ i386-pc-linux-gnu-clang++
	CFLAGS="${CFLAGS/x86-64-v?/i686}"
	CXXFLAGS="${CXXFLAGS/x86-64-v?/i686}"
	CXXFLAGS="${CXXFLAGS/_GLIBCXX_ASSERTIONS/_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_EXTENSIVE}"
}

rt_args=(
	-DCOMPILER_RT_BUILD_LIBFUZZER=OFF
	-DCOMPILER_RT_BUILD_MEMPROF=OFF
	-DCOMPILER_RT_BUILD_ORC=OFF
	-DCOMPILER_RT_BUILD_PROFILE=OFF
	-DCOMPILER_RT_BUILD_SANITIZERS=OFF
	-DCOMPILER_RT_BUILD_XRAY=OFF
)

stage1() {
	CC=i386-pc-linux-gnu-gcc CXX=i386-pc-linux-gnu-g++ \
	cmake -S runtimes -B build \
	-DCMAKE_INSTALL_PREFIX=/usr \
	-DCMAKE_BUILD_TYPE=Release -GNinja \
	-DLLVM_ENABLE_RUNTIMES="libunwind;libcxx;libcxxabi"
	DESTDIR=$PWD/pkg ninja install -C build; cp -a pkg/usr/lib/* /usr/lib32/

	rm -rf build pkg
	CC=i386-pc-linux-gnu-gcc CXX=i386-pc-linux-gnu-g++ \
	cmake -S runtimes -B build \
	-DCMAKE_INSTALL_PREFIX=/usr \
	-DCMAKE_BUILD_TYPE=Release -GNinja \
	-DCAN_TARGET_i386=ON -DCAN_TARGET_x86_64=OFF \
	-DLLVM_ENABLE_RUNTIMES=compiler-rt "${rt_args[@]}"
	DESTDIR=$PWD/pkg ninja install -C build
	for i in pkg/usr/lib/linux/*-i386.*; do
		f=${i##*/}
		install -Dvm644 $i "${rt_install_dir}/${f/-i386}"
	done
}

stage2() {
	[ $# -eq 0 ] || printf "$* \n"

	rm -rf build pkg "$PKG/usr/lib32"
	CC=i386-pc-linux-gnu-clang CXX=i386-pc-linux-gnu-clang++ \
	cmake -S runtimes -B build \
	-DCMAKE_INSTALL_PREFIX=/usr \
	-DCMAKE_BUILD_TYPE=Release -GNinja \
	-DLLVM_ENABLE_RUNTIMES="libunwind;libcxx;libcxxabi" \
	-DLIBCXX_HAS_ATOMIC_LIB=OFF \
	-DLIB{UNWIND,CXX{,ABI}}_USE_COMPILER_RT=ON
	DESTDIR=$PWD/pkg ninja install -C build
	mkdir -p "$PKG/usr/lib32"
	cp -a pkg/usr/lib/* /usr/lib32/
	cp -a pkg/usr/lib/* "$PKG/usr/lib32/"

	if [[ -f ${rt_install_dir}/libclang_rt.asan.so && $# -gt 0 ]]; then
		echo "::The 32-bit compiler-rt built-in library and sanitizers already exists! "
		echo "::SKIP build compiler-rt."
		return
	else
		rm -rf "${PKG}${rt_install_dir}"
	fi

	rm -rf build pkg
	CC=clang CXX=clang++ \
	CFLAGS="${CFLAGS} -m32" \
	CXXFLAGS="${CXXFLAGS} -m32" \
	cmake -S runtimes -B build \
	-DCMAKE_INSTALL_PREFIX=/usr \
	-DCMAKE_BUILD_TYPE=Release -GNinja \
	-DCAN_TARGET_i386=ON -DCAN_TARGET_x86_64=OFF \
	-DLLVM_ENABLE_RUNTIMES=compiler-rt \
	-DCOMPILER_RT_INCLUDE_TESTS=OFF \
	-DCOMPILER_RT_USE_BUILTINS_LIBRARY=ON \
	-DLLVM_DEFAULT_TARGET_TRIPLE=$(gcc -dumpmachine) \
	-DSANITIZER_CXX_ABI=libcxxabi
	DESTDIR=$PWD/pkg ninja install -C build
	for i in pkg/usr/lib/linux/*-i386.*; do
		f=${i##*/}
		[ $# -eq 0 ] || install -Dvm644 $i "${rt_install_dir}/${f/-i386}"
	done
	if [ $# -gt 0 ]; then
		chmod 755 ${rt_install_dir}/*.so
		mkdir -p ${PKG}${rt_install_dir%/i386-*}
		cp -a ${rt_install_dir} "${PKG}${rt_install_dir%/i386-*}"
	fi
}

echo 'int main(){}' > main.c
if ! gcc -m32 main.c 2> /dev/null; then
	echo "::Error: Compiler does not support -m32"
	exit 1
else
	rm -f main.c a.out
fi

pre_src
rt_install_dir="/usr/lib/clang/${VERSION%%.*}/lib/i386-pc-linux-gnu"

if [[ $1 != pre ]]; then
	stage2 "::PASS1\n"
	stage2 "::PASS2\n"
else
	stage1; stage2
fi
