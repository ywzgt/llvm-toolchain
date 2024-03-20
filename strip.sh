#!/bin/bash

STRIP_BINARIES="--strip-all"
STRIP_SHARED="--strip-unneeded"
STRIP_STATIC="--strip-debug"

strip_file() {
	local binary=$1; shift
	local tempfile=$(mktemp "$binary.XXXXXX")
	if strip "$@" "$binary" -o "$tempfile"; then
		cat "$tempfile" > "$binary"
	fi
	rm -f "$tempfile"
}

do_strip() {
	local binary strip_flags
	find "${DEST}" -type f -name '*.dbg' | xargs rm -fv
	find "${DEST}" -type f -perm -u+w -print0 2>/dev/null | while IFS= read -rd '' binary ; do
		case "$(LC_ALL=C readelf -h "$binary" 2>/dev/null)" in
			*Type:*'DYN (Shared object file)'*) # Libraries (.so) or Relocatable binaries
				strip_flags="$STRIP_SHARED";;
			*Type:*'DYN (Position-Independent Executable file)'*) # Relocatable binaries
				strip_flags="$STRIP_SHARED";;
			*Type:*'EXEC (Executable file)'*) # Binaries
				strip_flags="$STRIP_BINARIES";;
			*Type:*'REL (Relocatable file)'*) # Libraries (.a) or objects
				if ar t "$binary" &>/dev/null; then # Libraries (.a)
					strip_flags="$STRIP_STATIC"
				elif [[ $binary = *'.ko' || $binary = *'.o' ]]; then # Kernel module or object file
					strip_flags="$STRIP_SHARED"
				else
					continue
				fi
				;;
			*)
				continue ;;
		esac
		pushd /tmp >/dev/null
		strip_file "$binary" ${strip_flags}
		popd >/dev/null
	done
}

remove_rpath() {
	if ! command -v chrpath > /dev/null; then
		local PV=0.16
		local SRC="chrpath_$PV.orig.tar.gz"
		local URL="https://deb.debian.org/debian/pool/main/c/chrpath"
		if ! wget -q "$URL/$SRC"
		then
			SRC="$(curl -sL $URL|sed -n 's/.*\(chrpath_.*.orig.tar.gz\).*/\1/p'|head -1)"
			wget -nv "$URL/$SRC"; PV=$(echo ${SRC%.orig.*}|sed 's/.*_//')
		fi
		tar xf $SRC; cd chrpath-${PV}
		CC=clang ./configure --prefix=/usr; make -j$(nproc) && make install
	fi

	local binary
	printf "\nDeleting runtime path...\n"
	find "${DEST}" -type f -perm -u+w -print0 2>/dev/null | while IFS= read -rd '' binary
	do
		if chrpath -l "$binary" > /dev/null 2>&1; then
			echo ":: ${binary#$DEST/}"; chrpath -d "$binary"
		fi
	done
}

if [[ -n $1 && -e $1 ]]; then
	DEST="$(realpath $1)"
	do_strip; remove_rpath
else
	echo "No such file or directory: $1"
	exit 1
fi
