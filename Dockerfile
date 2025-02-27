#####################################################################################################
# Needs to derive from an old Linux to be able to generate binaries compatible with old kernels
FROM debian:buster as base

# Set basic env vars
ENV GOROOT          /usr/local/go
ENV GOPATH          /go
ENV PATH            ${GOPATH}/bin:${GOROOT}/bin:${PATH}
ENV OSX_NDK_X86     /usr/local/osx-ndk-x86
ENV PATH            ${OSX_NDK_X86}/bin:$PATH
ENV LD_LIBRARY_PATH ${OSX_NDK_X86}/lib:$LD_LIBRARY_PATH

WORKDIR ${GOPATH}

# Install tools
ENV DEBIAN_FRONTEND noninteractive
RUN apt-get update && \
    apt-get install -y automake autogen \
    libtool libxml2-dev uuid-dev libssl-dev bash \
    patch cmake make tar xz-utils bzip2 gzip zlib1g-dev sed cpio \
    git apt-transport-https ca-certificates wget ssh python \
    gcc-multilib g++-multilib clang llvm-dev --no-install-recommends \
    || exit 1

# Install other cross-compiling tools and dependencies
RUN dpkg --add-architecture armhf && \
    dpkg --add-architecture arm64 && \
    dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y \
# Install Windows toolset
    gcc-mingw-w64 g++-mingw-w64 \
# Install ARM toolset
    gcc-arm-linux-gnueabihf g++-arm-linux-gnueabihf libc6-dev-armhf-cross \
    gcc-aarch64-linux-gnu g++-aarch64-linux-gnu libc6-dev-arm64-cross \
# Install build & runtime dependencies	
    lib32z1-dev \
    || exit 1

# Fix support for 386 (Linux 32bits) platform
# From https://stackoverflow.com/a/38751292
RUN ln -s /usr/include/asm-generic /usr/include/asm

RUN mkdir -p /root/.ssh; \
    chmod 0700 /root/.ssh; \
    ssh-keyscan github.com > /root/.ssh/known_hosts;

#####################################################################################################
# Install macOS cross-compiling toolset
FROM base as base-macos

ENV OSX_SDK_VERSION 	11.1
ENV OSX_SDK     		MacOSX$OSX_SDK_VERSION.sdk
ENV OSX_SDK_PATH 		$OSX_SDK.tar.xz

COPY $OSX_SDK_PATH /go

RUN git clone https://github.com/tpoechtrager/osxcross.git && \
    git -C osxcross checkout 035cc170338b7b252e3f13b0e3ccbf4411bffc41 || exit 1; \
    mv $OSX_SDK_PATH osxcross/tarballs/ && \
    UNATTENDED=yes SDK_VERSION=${OSX_SDK_VERSION} OSX_VERSION_MIN=10.10 osxcross/build.sh || exit 1; \
    mv osxcross/target $OSX_NDK_X86; \
    rm -rf osxcross;

#####################################################################################################
FROM base as base-taglib

# Download TagLib source
ENV TAGLIB_VERSION        1.12
ENV TAGLIB_SHA            7fccd07669a523b07a15bd24c8da1bbb92206cb19e9366c3692af3d79253b703
ENV TAGLIB_DOWNLOAD_FILE  taglib-$TAGLIB_VERSION.tar.gz
ENV TABLIB_BUILD_OPTS     -DCMAKE_BUILD_TYPE=Release -DWITH_MP4=ON -DWITH_ASF=ON

RUN cd /tmp && \
    wget https://taglib.github.io/releases/$TAGLIB_DOWNLOAD_FILE && \
    echo "$TAGLIB_SHA $TAGLIB_DOWNLOAD_FILE" | sha256sum -c - || exit 1;

RUN cd /tmp && \
    tar xvfz taglib-$TAGLIB_VERSION.tar.gz && \
    mv taglib-${TAGLIB_VERSION} /tmp/taglib-src

#####################################################################################################
FROM base-macos as build-macos

COPY --from=base-taglib /tmp/taglib-src /tmp/taglib-src

RUN echo "Build static taglib for macOS" && \
    cd /tmp/taglib-src && \
    cmake  \
        $TABLIB_BUILD_OPTS -DCMAKE_INSTALL_PREFIX=/darwin \
        -DCMAKE_C_COMPILER=${OSX_NDK_X86}/bin/o64-clang \
        -DCMAKE_CXX_COMPILER=${OSX_NDK_X86}/bin/o64-clang++ \
        -DCMAKE_RANLIB=${OSX_NDK_X86}/bin/x86_64-apple-darwin20.2-ranlib \
        -DCMAKE_AR=${OSX_NDK_X86}/bin/x86_64-apple-darwin20.2-ar && \
    make install 

#####################################################################################################
FROM base-taglib as build-linux32

RUN echo "Build static taglib for Linux 32" && \
    cd /tmp/taglib-src && \
    CXXFLAGS=-m32 CFLAGS=-m32 cmake -DCMAKE_INSTALL_PREFIX=/i386 $TABLIB_BUILD_OPTS && \
    make install 

#####################################################################################################
FROM base-taglib as build-arm

RUN echo "Build static taglib for Linux ARM" && \
    cd /tmp/taglib-src && \
    cmake \
        -DCMAKE_INSTALL_PREFIX=/arm $TABLIB_BUILD_OPTS \
        -DCMAKE_C_COMPILER=arm-linux-gnueabihf-gcc \
        -DCMAKE_CXX_COMPILER=arm-linux-gnueabihf-g++ && \
    make install 

#####################################################################################################
FROM base-taglib as build-arm64

RUN echo "Build static taglib for Linux ARM64" && \
    cd /tmp/taglib-src && \
    cmake \
        -DCMAKE_INSTALL_PREFIX=/arm64 $TABLIB_BUILD_OPTS \
        -DCMAKE_C_COMPILER=aarch64-linux-gnu-gcc \
        -DCMAKE_CXX_COMPILER=aarch64-linux-gnu-g++ && \
    make install

#####################################################################################################
FROM base-taglib as build-win32

RUN echo "Build static taglib for Windows 32" && \
    cd /tmp/taglib-src && \
    cmake  \
        $TABLIB_BUILD_OPTS -DCMAKE_INSTALL_PREFIX=/mingw32 \
        -DBUILD_SHARED_LIBS=OFF -DCMAKE_SYSTEM_NAME=Windows \
        -DCMAKE_C_COMPILER=i686-w64-mingw32-gcc \
        -DCMAKE_CXX_COMPILER=i686-w64-mingw32-g++ && \
    make install 

#####################################################################################################
FROM base-taglib as build-win64

RUN echo "Build static taglib for Windows 64" && \
    cd /tmp/taglib-src && \
    cmake  \
        $TABLIB_BUILD_OPTS -DCMAKE_INSTALL_PREFIX=/mingw64 \
        -DBUILD_SHARED_LIBS=OFF -DCMAKE_SYSTEM_NAME=Windows \
        -DCMAKE_C_COMPILER=x86_64-w64-mingw32-gcc \
        -DCMAKE_CXX_COMPILER=x86_64-w64-mingw32-g++ && \
    make install 


#####################################################################################################
FROM base-taglib as final

LABEL maintainer="deluan@navidrome.org"

# Build TagLib for Linux64
RUN echo "Build static taglib for Linux 64" && \
    cd /tmp/taglib-src && \
    cmake -DCMAKE_INSTALL_PREFIX=/usr $TABLIB_BUILD_OPTS && \
    make install 

# Install GoLang
ENV GO_VERSION        1.19.1
ENV GO_SHA            acc512fbab4f716a8f97a8b3fbaa9ddd39606a28be6c2515ef7c6c6311acffde
ENV GO_DOWNLOAD_FILE  go${GO_VERSION}.linux-amd64.tar.gz
ENV GO_DOWNLOAD_URL   https://golang.org/dl/${GO_DOWNLOAD_FILE} 

RUN cd /tmp && \
    wget ${GO_DOWNLOAD_URL} && \
    echo "${GO_SHA} ${GO_DOWNLOAD_FILE}" | sha256sum -c - || exit 1; \
    tar -xf ${GO_DOWNLOAD_FILE} && \
    mv go /usr/local

# Install GoReleaser
ENV GORELEASER_VERSION        1.11.4
ENV GORELEASER_SHA            55c2a911b33f1da700d937e51696a8be376fe64afe6f6681fd194456a640c3d6
ENV GORELEASER_DOWNLOAD_FILE  goreleaser_Linux_x86_64.tar.gz
ENV GORELEASER_DOWNLOAD_URL   https://github.com/goreleaser/goreleaser/releases/download/v${GORELEASER_VERSION}/${GORELEASER_DOWNLOAD_FILE}
ENV GOOS linux
ENV GOARCH amd64

RUN wget ${GORELEASER_DOWNLOAD_URL}; \
    echo "${GORELEASER_SHA} ${GORELEASER_DOWNLOAD_FILE}" | sha256sum -c - || exit 1; \
    tar -xzf ${GORELEASER_DOWNLOAD_FILE} -C /usr/bin/ goreleaser; \
    rm ${GORELEASER_DOWNLOAD_FILE};

# Copy cross-compiled static libraries
COPY --from=build-linux32 /i386 /i386
COPY --from=build-arm /arm /arm
COPY --from=build-arm64 /arm64 /arm64
COPY --from=build-win32 /mingw32 /mingw32
COPY --from=build-win64 /mingw64 /mingw64
COPY --from=build-macos /darwin /darwin

# Copy OSX_NDK
COPY --from=base-macos ${OSX_NDK_X86} ${OSX_NDK_X86}

CMD ["goreleaser", "-v"]
