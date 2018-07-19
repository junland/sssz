#!/bin/sh

set -e

printmsg() {
	local msg=$(echo $1 | tr -s / /)
	printf "\e[1m\e[32m==>\e[0m $msg\n"
	sleep 1
}

printmsgerror() {
	local msg=$(echo $1 | tr -s / /)
	printf "\e[1m\e[31m==!\e[0m $msg\n"
	sleep 1
}

tarxf() {
	cd $SOURCES
	[ -f $2$3 ] || curl -L -O $1$2$3 -C -
	rm -rf ${4:-$2}
	tar -xf $2$3
	cd ${4:-$2}
}

tarxfalt() {
	cd $SOURCES
	[ -f $2$3 ] || curl -L -O $1$2$3 -C -
	rm -rf ${4:-$2}
	tar -xf $2$3
}

clean_libtool() {
	find $ROOTFS -type f | xargs file 2>/dev/null | grep "libtool library file" | cut -f 1 -d : | xargs rm -rf 2>/dev/null || true
}

check_for_root() {
	:
}

setup_architecture() {
	case $BARCH in
		x86_64)
			printmsg "Using configuration for x86_64"
			export XHOST="$(echo ${MACHTYPE} | sed -e 's/-[^-]*/-cross/')"
			export XTARGET="x86_64-linux-musl"
			export XKARCH="x86_64"
			export GCCOPTS=
			;;
		aarch64)
			printmsg "Using configuration for aarch64"
			export XHOST="$(echo ${MACHTYPE} | sed -e 's/-[^-]*/-cross/')"
			export XTARGET="aarch64-linux-musl"
			export XKARCH="arm64"
			export GCCOPTS="--with-arch=armv8-a --with-abi=lp64"
			;;
		arm)
			printmsg "Using configuration for armhf"
			export XHOST="$(echo ${MACHTYPE} | sed -e 's/-[^-]*/-cross/')"
			export XTARGET="armv7l-linux-musleabihf"
			export XKARCH="arm"
			export GCCOPTS="--with-arch=armv7-a --with-fpu=vfpv3 --with-float=hard"
			;;
		*)
			printmsgerror "BARCH variable isn't set!"
			exit 1
	esac
}

setup_environment() {
	printmsg "Setting up build environment"
	export CWD="$(pwd)"
	export KEEP="$CWD/KEEP"
	export BUILD="$CWD/build"
	export SOURCES="$BUILD/sources"
	export ROOTFS="$BUILD/rootfs"
	export TOOLS="$BUILD/tools"
	export IMAGE="$BUILD/image"

	rm -rf $BUILD
	mkdir -p $BUILD $SOURCES $ROOTFS $TOOLS $IMAGE

	export LC_ALL="POSIX"
	export PATH="$TOOLS/bin:$PATH"
	export HOSTCC="gcc"
	export HOSTCXX="g++"
	export MKOPTS="-j$(expr $(nproc) + 1)"

	export CFLAGS="-Os -g0 -pipe --static"
	export CXXFLAGS="$CFLAGS"
	export LDFLAGS="-s -static"
}

prepare_filesystem() {
	printmsg "Preparing rootfs skeleton"
}

build_toolchain() {
	printmsg "Building cross-toolchain for $BARCH"
	source $KEEP/toolchain_vers

	printmsg "Downloading patch for Linux"
	cd $SOURCES
	curl -L -O https://github.com/anthraxx/linux-hardened/releases/download/$LINUXPATCHVER/linux-hardened-$LINUXPATCHVER.patch -C -

	printmsg "Building host file"
	tarxf ftp://ftp.astron.com/pub/file/ file-$FILEVER .tar.gz
	./configure \
		--prefix=$TOOLS \
		--disable-shared
	make $MKOPTS
	make install

	printmsg "Building host pkgconf"
	tarxf http://distfiles.dereferenced.org/pkgconf/ pkgconf-$PKGCONFVER .tar.xz
	LDFLAGS="-s -static" \
	./configure \
		--prefix=$TOOLS \
		--host=$XTARGET \
		--with-sysroot=$ROOTFS \
		--with-pkg-config-dir="$ROOTFS/usr/lib/pkgconfig:$ROOTFS/usr/share/pkgconfig"
	make $MKOPTS
	make install
	ln -s pkgconf $TOOLS/bin/pkg-config
	ln -s pkgconf $TOOLS/bin/$CROSS_COMPILEpkg-config

	printmsg "Building host binutils"
	tarxf http://ftpmirror.gnu.org/gnu/binutils/ binutils-$BINUTILSVER .tar.xz
	mkdir build
	cd build
	../configure \
		--prefix=$TOOLS \
		--target=$XTARGET \
		--with-sysroot=$ROOTFS \
		--enable-deterministic-archives \
		--disable-multilib \
		--disable-nls \
		--disable-shared \
		--disable-werror
	make configure-host $MKOPTS
	make $MKOPTS
	make install

	printmsg "Building host GCC (stage 1)"
	tarxfalt http://ftpmirror.gnu.org/gnu/gmp/ gmp-$GMPVER .tar.xz
	tarxfalt http://www.mpfr.org/mpfr-$MPFRVER/ mpfr-$MPFRVER .tar.xz
	tarxfalt http://ftpmirror.gnu.org/gnu/mpc/ mpc-$MPCVER .tar.gz
	tarxfalt http://isl.gforge.inria.fr/ isl-$ISLVER .tar.xz
	tarxf http://ftpmirror.gnu.org/gnu/gcc/gcc-$GCCVER/ gcc-$GCCVER .tar.xz
	patch -Np1 -i $KEEP/gcc/10_all_default-fortify-source.patch
	patch -Np1 -i $KEEP/gcc/11_all_default-warn-format-security.patch
	patch -Np1 -i $KEEP/gcc/12_all_default-warn-trampolines.patch
	patch -Np1 -i $KEEP/gcc/13_all_default-ssp-fix.patch
	patch -Np1 -i $KEEP/gcc/25_all_alpha-mieee-default.patch
	patch -Np1 -i $KEEP/gcc/34_all_ia64_note.GNU-stack.patch
	patch -Np1 -i $KEEP/gcc/35_all_i386_libgcc_note.GNU-stack.patch
	patch -Np1 -i $KEEP/gcc/50_all_libiberty-asprintf.patch
	patch -Np1 -i $KEEP/gcc/51_all_libiberty-pic.patch
	patch -Np1 -i $KEEP/gcc/54_all_nopie-all-flags.patch
	patch -Np1 -i $KEEP/gcc/55_all_extra-options.patch
	patch -Np1 -i $KEEP/gcc/90_all_pr55930-dependency-tracking.patch
	patch -Np1 -i $KEEP/gcc/92_all_sh-drop-sysroot-suffix.patch
	patch -Np1 -i $KEEP/gcc/93_all_arm-arch.patch
	patch -Np1 -i $KEEP/gcc/94_all_mips-o32-asan.patch
	patch -Np1 -i $KEEP/gcc/95_all_ia64-TEXTREL.patch
	patch -Np1 -i $KEEP/gcc/96_all_lto-O2-PR85655.patch
	patch -Np1 -i $KEEP/gcc/97_all_disable-systemtap-switch.patch
	patch -Np1 -i $KEEP/gcc/gcc-pure64.patch
	patch -Np1 -i $KEEP/gcc/gcc-pure64-mips.patch
	mv ../gmp-$GMPVER gmp
	mv ../mpfr-$MPFRVER mpfr
	mv ../mpc-$MPCVER mpc
	mv ../isl-$ISLVER isl
	sed -i 's@\./fixinc\.sh@-c true@' gcc/Makefile.in
	mkdir build
	cd build
	../configure $GCCOPTS \
		--prefix=$TOOLS \
		--build=$XHOST \
		--host=$XHOST \
		--target=$XTARGET \
		--with-pkgversion="sssz" \
		--with-sysroot=$ROOTFS \
		--with-newlib \
		--without-headers \
		--enable-languages=c \
		--disable-decimal-float \
		--disable-libatomic \
		--disable-libcilkrts \
		--disable-libgomp \
		--disable-libitm \
		--disable-libmudflap \
		--disable-libmpx \
		--disable-libquadmath \
		--disable-libsanitizer \
		--disable-libssp \
		--disable-libstdc++-v3 \
		--disable-libvtv \
		--disable-multilib \
		--disable-nls \
		--disable-shared \
		--disable-threads
	make all-gcc all-target-libgcc $MKOPTS
	make install-gcc install-target-libgcc

	printmsg "Installing Linux headers"
	tarxf https://cdn.kernel.org/pub/linux/kernel/v4.x/ linux-$LINUXVER .tar.xz
	patch -Np1 -i $SOURCES/linux-hardened-$LINUXPATCHVER.patch
	make mrproper $MKOPTS
	make ARCH=$XKARCH INSTALL_HDR_PATH=$ROOTFS headers_install
	find $ROOTFS/include -name .install -or -name ..install.cmd | xargs rm -rf
	clean_libtool

	printmsg "Building musl libc"
	tarxf http://www.musl-libc.org/releases/ musl-$MUSLVER .tar.gz
	./configure \
		--prefix= \
		--syslibdir=/lib \
		--build=$XHOST \
		--host=$XTARGET \
		--enable-optimize
	make $MKOPTS
	make DESTDIR=$ROOTFS install
	clean_libtool

	printmsg "Configuring musl libc"
	ln -sf ../lib/libc.so $ROOTFS/bin/ldd

	printmsg "Building host GCC (final stage)"
	tarxfalt http://ftpmirror.gnu.org/gnu/gmp/ gmp-$GMPVER .tar.xz
	tarxfalt http://www.mpfr.org/mpfr-$MPFRVER/ mpfr-$MPFRVER .tar.xz
	tarxfalt http://ftpmirror.gnu.org/gnu/mpc/ mpc-$MPCVER .tar.gz
	tarxfalt http://isl.gforge.inria.fr/ isl-$ISLVER .tar.xz
	tarxf http://ftpmirror.gnu.org/gnu/gcc/gcc-$GCCVER/ gcc-$GCCVER .tar.xz
	patch -Np1 -i $KEEP/gcc/10_all_default-fortify-source.patch
	patch -Np1 -i $KEEP/gcc/11_all_default-warn-format-security.patch
	patch -Np1 -i $KEEP/gcc/12_all_default-warn-trampolines.patch
	patch -Np1 -i $KEEP/gcc/13_all_default-ssp-fix.patch
	patch -Np1 -i $KEEP/gcc/25_all_alpha-mieee-default.patch
	patch -Np1 -i $KEEP/gcc/34_all_ia64_note.GNU-stack.patch
	patch -Np1 -i $KEEP/gcc/35_all_i386_libgcc_note.GNU-stack.patch
	patch -Np1 -i $KEEP/gcc/50_all_libiberty-asprintf.patch
	patch -Np1 -i $KEEP/gcc/51_all_libiberty-pic.patch
	patch -Np1 -i $KEEP/gcc/54_all_nopie-all-flags.patch
	patch -Np1 -i $KEEP/gcc/55_all_extra-options.patch
	patch -Np1 -i $KEEP/gcc/90_all_pr55930-dependency-tracking.patch
	patch -Np1 -i $KEEP/gcc/92_all_sh-drop-sysroot-suffix.patch
	patch -Np1 -i $KEEP/gcc/93_all_arm-arch.patch
	patch -Np1 -i $KEEP/gcc/94_all_mips-o32-asan.patch
	patch -Np1 -i $KEEP/gcc/95_all_ia64-TEXTREL.patch
	patch -Np1 -i $KEEP/gcc/96_all_lto-O2-PR85655.patch
	patch -Np1 -i $KEEP/gcc/97_all_disable-systemtap-switch.patch
	patch -Np1 -i $KEEP/gcc/gcc-pure64.patch
	patch -Np1 -i $KEEP/gcc/gcc-pure64-mips.patch
	mv ../gmp-$GMPVER gmp
	mv ../mpfr-$MPFRVER mpfr
	mv ../mpc-$MPCVER mpc
	mv ../isl-$ISLVER isl
	sed -i 's@\./fixinc\.sh@-c true@' gcc/Makefile.in
	mkdir build
	cd build
	../configure $GCCOPTS \
		--prefix=$TOOLS \
		--build=$XHOST \
		--host=$XHOST \
		--target=$XTARGET \
		--with-pkgversion="sssz" \
		--with-sysroot=$ROOTFS \
		--enable-__cxa_atexit \
		--enable-checking=release \
		--enable-default-pie \
		--enable-default-ssp \
		--enable-languages=c,c++ \
		--enable-lto \
		--enable-threads=posix \
		--enable-tls \
		--disable-gnu-indirect-function \
		--disable-libmpx \
		--disable-libmudflap \
		--disable-libsanitizer \
		--disable-multilib \
		--disable-nls \
		--disable-shared \
		--disable-symvers \
		--disable-werror
	make $MKOPTS
	make install
}

prepare_rootfs_build() {
	printmsg "Preparing for rootfs build"
	export CROSS_COMPILE="$XTARGET-"
	export CC="$XTARGET-gcc"
	export CXX="$XTARGET-g++"
	export AR="$XTARGET-ar"
	export AS="$XTARGET-as"
	export RANLIB="$XTARGET-ranlib"
	export LD="$XTARGET-ld"
	export STRIP="$XTARGET-strip"
	export PKG_CONFIG_PATH="$ROOTFS/usr/lib/pkgconfig:$ROOTFS/usr/share/pkgconfig"
	export PKG_CONFIG_SYSROOT_DIR="$ROOTFS"
}

build_rootfs() {
	source $KEEP/toolchain_vers
	printmsg "Building libz"
	tarxf https://sortix.org/libz/release/ libz-1.2.8.2015.12.26 .tar.gz
	./configure \
		--prefix= \
		--build=$XHOST \
		--host=$XTARGET \
		--disable-shared
	make $MKOPTS
	make DESTDIR=$ROOTFS install
	clean_libtool

	printmsg "Building m4"
	tarxf http://ftpmirror.gnu.org/gnu/m4/ m4-1.4.18 .tar.xz
	./configure \
		--prefix= \
		--build=$XHOST \
		--host=$XTARGET \
		--disable-shared
	make $MKOPTS
	make DESTDIR=$ROOTFS install
	clean_libtool

	printmsg "Building bison"
	tarxf http://ftpmirror.gnu.org/gnu/bison/ bison-3.0.5 .tar.xz
	./configure \
		--prefix= \
		--build=$XHOST \
		--host=$XTARGET \
		--disable-nls \
		--disable-shared
	make $MKOPTS
	make DESTDIR=$ROOTFS install
	clean_libtool

	printmsg "Building flex"
	tarxf http://github.com/westes/flex/releases/download/v2.6.4/ flex-2.6.4 .tar.gz
cat > config.cache << EOF
ac_cv_func_malloc_0_nonnull=yes
ac_cv_func_realloc_0_nonnull=yes
EOF
	./configure \
		--prefix= \
		--build=$XHOST \
		--host=$XTARGET \
		--cache-file=config.cache \
		--disable-nls \
		--disable-shared
	make $MKOPTS
	make DESTDIR=$ROOTFS install-strip
	clean_libtool

	printmsg "Building libelf"
	tarxf http://ftp.barfooze.de/pub/sabotage/tarballs/ libelf-compat-0.152c001 .tar.bz2
	echo "CFLAGS += $CFLAGS -fPIC" > config.mak
	sed -i 's@HEADERS = src/libelf.h@HEADERS = src/libelf.h src/gelf.h@' Makefile
	make CC="$CC" HOSTCC="$HOSTCC" $MKOPTS
	make prefix= DESTDIR=$ROOTFS install
	clean_libtool

	printmsg "Building binutils"
	tarxf http://ftpmirror.gnu.org/gnu/binutils/ binutils-$BINUTILSVER .tar.xz
	mkdir build
	cd build
	../configure \
		--prefix= \
		--libdir=/lib \
		--libexecdir=/lib \
		--build=$XHOST \
		--host=$XTARGET \
		--target=$XTARGET \
		--with-system-zlib \
		--enable-deterministic-archives \
		--enable-gold \
		--enable-ld=default \
		--enable-plugins \
		--disable-multilib \
		--disable-nls \
		--disable-shared \
		--disable-werror
	make configure-host $MKOPTS
	make tooldir=/ $MKOPTS
	make tooldir=/ DESTDIR=$ROOTFS install-strip
	clean_libtool

	printmsg "Building gmp"
	tarxf http://ftpmirror.gnu.org/gnu/gmp/ gmp-$GMPVER .tar.xz
	./configure \
		--prefix= \
		--build=$XHOST \
		--host=$XTARGET \
		--enable-cxx \
		--disable-shared
	make $MKOPTS
	make DESTDIR=$ROOTFS install-strip
	clean_libtool

	printmsg "Building mpfr"
	tarxf http://www.mpfr.org/mpfr-$MPFRVER/ mpfr-$MPFRVER .tar.xz
	./configure \
		--prefix= \
		--build=$XHOST \
		--host=$XTARGET \
		--enable-thread-safe \
		--disable-shared
	make $MKOPTS
	make DESTDIR=$ROOTFS install-strip
	clean_libtool

	printmsg "Building mpc"
	tarxf http://ftpmirror.gnu.org/gnu/mpc/ mpc-$MPCVER .tar.gz
	./configure \
		--prefix= \
		--build=$XHOST \
		--host=$XTARGET \
		--disable-shared
	make $MKOPTS
	make DESTDIR=$ROOTFS install-strip
	clean_libtool

	printmsg "Building isl"
	tarxf http://isl.gforge.inria.fr/ isl-$ISLVER .tar.xz
	./configure \
		--prefix= \
		--build=$XHOST \
		--host=$XTARGET \
		--disable-shared
	make $MKOPTS
	make DESTDIR=$ROOTFS install-strip
	clean_libtool

	printmsg "Building GCC"
	tarxf http://ftpmirror.gnu.org/gnu/gcc/gcc-$GCCVER/ gcc-$GCCVER .tar.xz
	patch -Np1 -i $KEEP/gcc/10_all_default-fortify-source.patch
	patch -Np1 -i $KEEP/gcc/11_all_default-warn-format-security.patch
	patch -Np1 -i $KEEP/gcc/12_all_default-warn-trampolines.patch
	patch -Np1 -i $KEEP/gcc/13_all_default-ssp-fix.patch
	patch -Np1 -i $KEEP/gcc/25_all_alpha-mieee-default.patch
	patch -Np1 -i $KEEP/gcc/34_all_ia64_note.GNU-stack.patch
	patch -Np1 -i $KEEP/gcc/35_all_i386_libgcc_note.GNU-stack.patch
	patch -Np1 -i $KEEP/gcc/50_all_libiberty-asprintf.patch
	patch -Np1 -i $KEEP/gcc/51_all_libiberty-pic.patch
	patch -Np1 -i $KEEP/gcc/54_all_nopie-all-flags.patch
	patch -Np1 -i $KEEP/gcc/55_all_extra-options.patch
	patch -Np1 -i $KEEP/gcc/90_all_pr55930-dependency-tracking.patch
	patch -Np1 -i $KEEP/gcc/92_all_sh-drop-sysroot-suffix.patch
	patch -Np1 -i $KEEP/gcc/93_all_arm-arch.patch
	patch -Np1 -i $KEEP/gcc/94_all_mips-o32-asan.patch
	patch -Np1 -i $KEEP/gcc/95_all_ia64-TEXTREL.patch
	patch -Np1 -i $KEEP/gcc/96_all_lto-O2-PR85655.patch
	patch -Np1 -i $KEEP/gcc/97_all_disable-systemtap-switch.patch
	patch -Np1 -i $KEEP/gcc/gcc-pure64.patch
	patch -Np1 -i $KEEP/gcc/gcc-pure64-mips.patch
	sed -i 's@\./fixinc\.sh@-c true@' gcc/Makefile.in
	mkdir build
	cd build
	../configure $GCCOPTS \
		--prefix= \
		--libdir=/lib \
		--libexecdir=/lib \
		--build=$XHOST \
		--host=$XTARGET \
		--target=$XTARGET \
		--with-pkgversion="sssz" \
		--with-system-zlib \
		--enable-__cxa_atexit \
		--enable-checking=release \
		--enable-default-pie \
		--enable-default-ssp \
		--enable-languages=c,c++ \
		--enable-lto \
		--enable-threads=posix \
		--enable-tls \
		--disable-gnu-indirect-function \
		--disable-libmpx \
		--disable-libmudflap \
		--disable-libsanitizer \
		--disable-libstdcxx-pch \
		--disable-multilib \
		--disable-nls \
		--disable-shared \
		--disable-symvers \
		--disable-werror
	make $MKOPTS
	make DESTDIR=$ROOTFS install-strip
	clean_libtool

	printmsg "Configuring GCC"
	ln -s gcc $PKG/bin/cc
}

strip_rootfs() {
	printmsg "Stripping rootfs"
}

check_for_root
setup_architecture
setup_environment
prepare_filesystem
build_toolchain
prepare_rootfs_build
build_rootfs
strip_rootfs

exit 0

