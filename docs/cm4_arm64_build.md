# Neuron 在树莓派 CM4 上的 ARM64 交叉编译与部署记录

本文档基于当前仓库已经验证通过的 RK3506 流程整理，目标平台改为树莓派 CM4：

- 编译主机：`x86_64 Linux`
- 目标平台：`Raspberry Pi CM4`
- 目标架构：`arm64 / aarch64 / aarch64-linux-gnu`
- 目标部署目录：`/opt/neuron`

你给出的目标板环境是：

```bash
uname -m
getconf LONG_BIT
dpkg --print-architecture
```

结果分别是：

- `aarch64`
- `64`
- `arm64`

这说明应该使用 `aarch64-linux-gnu` 交叉工具链，而不是 `arm-linux-gnueabihf`。

## 1. 主机上安装交叉编译工具

```bash
sudo apt-get update
sudo apt-get install -y \
  gcc-aarch64-linux-gnu g++-aarch64-linux-gnu \
  make cmake pkg-config git curl wget unzip tar \
  autoconf automake libtool gettext bison flex perl python3 \
  protobuf-compiler sshpass
```

## 2. 统一环境变量

```bash
export TARGET=aarch64-linux-gnu
export STAGING=$HOME/neuron-staging/$TARGET

mkdir -p "$STAGING"

export CC=${TARGET}-gcc
export CXX=${TARGET}-g++
export AR=${TARGET}-ar
export AS=${TARGET}-as
export LD=${TARGET}-ld
export NM=${TARGET}-nm
export RANLIB=${TARGET}-ranlib
export STRIP=${TARGET}-strip

export PKG_CONFIG_PATH=$STAGING/lib/pkgconfig:$STAGING/share/pkgconfig
export PKG_CONFIG_LIBDIR=$PKG_CONFIG_PATH
export CFLAGS="-fPIC -I$STAGING/include"
export CXXFLAGS="-fPIC -I$STAGING/include"
export LDFLAGS="-L$STAGING/lib"
```

建议单独建一个依赖构建目录：

```bash
mkdir -p ~/neuron-arm64-build
cd ~/neuron-arm64-build
```

## 3. 需要交叉编译的第三方依赖

和 RK3506 流程一致，仍然是这些：

- OpenSSL
- zlog
- jansson
- mbedtls
- NanoSDK / nng
- libjwt
- sqlite
- protobuf-c
- libxml2

## 4. 依赖交叉编译命令

### 4.1 OpenSSL

```bash
cd ~/neuron-arm64-build
rm -rf openssl
git clone --branch OpenSSL_1_1_1w --depth 1 https://github.com/openssl/openssl.git
cd openssl

unset CC CXX AR AS LD NM RANLIB STRIP

./Configure linux-aarch64 no-tests no-shared \
  --prefix=$STAGING \
  --cross-compile-prefix=${TARGET}-

make -j$(nproc) build_libs
make install_sw
```

然后把交叉编译变量重新导出：

```bash
export CC=${TARGET}-gcc
export CXX=${TARGET}-g++
export AR=${TARGET}-ar
export AS=${TARGET}-as
export LD=${TARGET}-ld
export NM=${TARGET}-nm
export RANLIB=${TARGET}-ranlib
export STRIP=${TARGET}-strip
```

### 4.2 zlog

```bash
cd ~/neuron-arm64-build
rm -rf zlog
git clone -b 1.2.15 https://github.com/HardySimpson/zlog.git
cd zlog
make DEBUG='' CC=$CC AR=$AR CFLAGS="$CFLAGS"
make DEBUG='' PREFIX=$STAGING install
```

### 4.3 jansson

```bash
cd ~/neuron-arm64-build
rm -rf jansson
git clone https://github.com/neugates/jansson.git
cd jansson
cmake -S . -B build \
  -DCMAKE_SYSTEM_NAME=Linux \
  -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
  -DCMAKE_C_COMPILER=$CC \
  -DCMAKE_INSTALL_PREFIX=$STAGING \
  -DCMAKE_PREFIX_PATH=$STAGING \
  -DJANSSON_BUILD_DOCS=OFF \
  -DJANSSON_EXAMPLES=OFF
cmake --build build -j$(nproc)
cmake --install build
```

### 4.4 mbedtls

```bash
cd ~/neuron-arm64-build
rm -rf mbedtls
git clone -b v2.16.12 https://github.com/Mbed-TLS/mbedtls.git
cd mbedtls
cmake -S . -B build \
  -DCMAKE_SYSTEM_NAME=Linux \
  -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
  -DCMAKE_C_COMPILER=$CC \
  -DCMAKE_INSTALL_PREFIX=$STAGING \
  -DUSE_SHARED_MBEDTLS_LIBRARY=OFF \
  -DENABLE_TESTING=OFF \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON
cmake --build build -j$(nproc)
cmake --install build
```

### 4.5 sqlite

```bash
cd ~/neuron-arm64-build
curl -L -o sqlite3.tar.gz https://www.sqlite.org/2022/sqlite-autoconf-3390000.tar.gz
rm -rf sqlite3-src
mkdir -p sqlite3-src
tar xzf sqlite3.tar.gz --strip-components=1 -C sqlite3-src
cd sqlite3-src
./configure --host=$TARGET --prefix=$STAGING CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS"
make -j$(nproc)
make install
```

### 4.6 NanoSDK / nng

```bash
cd ~/neuron-arm64-build
rm -rf NanoSDK
git clone https://github.com/neugates/NanoSDK.git
cd NanoSDK
cmake -S . -B build \
  -DCMAKE_SYSTEM_NAME=Linux \
  -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
  -DCMAKE_C_COMPILER=$CC \
  -DCMAKE_CXX_COMPILER=$CXX \
  -DCMAKE_INSTALL_PREFIX=$STAGING \
  -DCMAKE_PREFIX_PATH=$STAGING \
  -DBUILD_SHARED_LIBS=OFF \
  -DNNG_TESTS=OFF \
  -DNNG_ENABLE_SQLITE=ON \
  -DNNG_ENABLE_TLS=ON
cmake --build build -j$(nproc)
cmake --install build
```

### 4.7 libjwt

```bash
cd ~/neuron-arm64-build
rm -rf libjwt
git clone -b v1.13.1 https://github.com/benmcollins/libjwt.git
cd libjwt

cmake -S . -B build \
  -DCMAKE_SYSTEM_NAME=Linux \
  -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
  -DCMAKE_C_COMPILER=$CC \
  -DCMAKE_CXX_COMPILER=$CXX \
  -DCMAKE_INSTALL_PREFIX=$STAGING \
  -DCMAKE_PREFIX_PATH=$STAGING \
  -DOPENSSL_ROOT_DIR=$STAGING \
  -DOPENSSL_INCLUDE_DIR=$STAGING/include \
  -DOPENSSL_CRYPTO_LIBRARY=$STAGING/lib/libcrypto.a \
  -DOPENSSL_SSL_LIBRARY=$STAGING/lib/libssl.a \
  -DBUILD_SHARED_LIBS=OFF \
  -DBUILD_EXAMPLES=OFF \
  -DBUILD_TESTS=OFF

cmake --build build -j$(nproc)
cmake --install build
```

### 4.8 protobuf-c

```bash
cd ~/neuron-arm64-build
rm -rf protobuf-c
git clone -b v1.4.0 https://github.com/protobuf-c/protobuf-c.git
cd protobuf-c
./autogen.sh
./configure \
  --host=$TARGET \
  --prefix=$STAGING \
  --disable-protoc \
  --enable-shared=no \
  CFLAGS="$CFLAGS" \
  CXXFLAGS="$CXXFLAGS" \
  LDFLAGS="$LDFLAGS"
make -j$(nproc)
make install
```

### 4.9 libxml2

```bash
cd ~/neuron-arm64-build
rm -rf libxml2
git clone -b v2.9.14 https://github.com/GNOME/libxml2.git
cd libxml2
NOCONFIGURE=1 ./autogen.sh
./configure \
  --host=$TARGET \
  --prefix=$STAGING \
  --enable-shared=no \
  --without-python \
  CC=$CC \
  CXX=$CXX \
  AR=$AR \
  RANLIB=$RANLIB \
  CFLAGS="$CFLAGS" \
  CXXFLAGS="$CXXFLAGS" \
  LDFLAGS="$LDFLAGS"
make -j$(nproc)
make install
```

## 5. 编译 Neuron

当前仓库里已经有适合 CM4 的工具链文件：

- `cmake/aarch64-linux-gnu.cmake`

交叉编译命令如下：

```bash
cd /home/swlts/neuron-main
export STAGING=$HOME/neuron-staging/aarch64-linux-gnu

cmake -S . \
  -B build-arm64 \
  -DCMAKE_TOOLCHAIN_FILE=cmake/aarch64-linux-gnu.cmake \
  -DCMAKE_BUILD_TYPE=Release \
  -DDISABLE_UT=ON \
  -DDISABLE_ASAN=ON \
  -DDISABLE_WERROR=ON \
  -DENABLE_DATALAYERS=OFF

cmake --build build-arm64 -j$(nproc)
```

### 5.1 MQTT 鉴权插件和这一步的关系

MQTT 鉴权插件不是单独写一个可执行程序再复制到设备上，而是作为 Neuron 插件源码参与 Neuron 的 CMake 构建。

也就是说，必须先把下面这些源码修改放进 `neuron-main`：

```text
plugins/mqtt/mqtt_auth.c
plugins/mqtt/mqtt_auth.h
plugins/mqtt/mqtt_auth_plugin.c
plugins/mqtt/mqtt-auth.json
plugins/mqtt/CMakeLists.txt
plugins/mqtt/mqtt_config.c
plugins/mqtt/mqtt_config.h
plugins/mqtt/mqtt_handle.c
plugins/mqtt/mqtt.json
default_plugins.json
```

然后再执行本节的 `cmake --build`。完整构建时会同时生成：

```text
build-arm64/plugins/libplugin-mqtt.so
build-arm64/plugins/libplugin-mqtt-auth.so
build-arm64/plugins/schema/mqtt.json
build-arm64/plugins/schema/mqtt-auth.json
```

如果 CMake 已经配置过，只想单独重编 MQTT 相关插件，可以执行：

```bash
cmake --build build-arm64 --target plugin-mqtt plugin-mqtt-auth -j"$(nproc)"
```

RK3506/ARMHF 流程中位置完全相同，只是构建目录从 `build-arm64` 换成 `build-armhf`：

```bash
cmake --build build-armhf --target plugin-mqtt plugin-mqtt-auth -j"$(nproc)"
```

本插件使用 OpenSSL 的 `libcrypto` 提供 HMAC-SHA256，依赖的是前面已经交叉编译并安装到 `$STAGING` 的 OpenSSL：

```text
$STAGING/include/openssl/*.h
$STAGING/lib/libcrypto.a
```

`plugins/mqtt/CMakeLists.txt` 中已经链接：

```cmake
target_link_libraries(plugin-mqtt crypto)
target_link_libraries(plugin-mqtt-auth crypto)
```

所以不需要在设备上单独编译 OpenSSL，也不需要在 RK3506/CM4 上现场编译插件；只要在 Linux 主机交叉编译后，把生成的 `.so` 和 schema JSON 一起部署到 Neuron 目录即可。

## 6. 检查最终 ARM64 产物

```bash
file build-arm64/neuron
file build-arm64/libneuron-base.so
file build-arm64/plugins/libplugin-modbus-tcp.so
file build-arm64/plugins/libplugin-mqtt.so
file build-arm64/plugins/libplugin-mqtt-auth.so
file build-arm64/plugins/libplugin-monitor.so
file build-arm64/plugins/libplugin-ekuiper.so
```

正常结果应该包含：

- `ELF 64-bit`
- `ARM aarch64`

## 7. 打包并传到 CM4

当前仓库里的打包脚本可以直接复用，但要显式指定 `build-arm64` 和新的 `STAGING`：

```bash
cd /home/swlts/neuron-main
export STAGING=$HOME/neuron-staging/aarch64-linux-gnu

bash scripts/package_rk3506_bundle.sh \
  --build-dir /home/swlts/neuron-main/build-arm64 \
  --staging-dir $STAGING \
  --output-dir /tmp/neuron-cm4
```

然后传输到 CM4：

```bash
sshpass -p admin ssh -o StrictHostKeyChecking=no admin@192.168.142.193 \
  "mkdir -p /home/admin/neuron/lib /home/admin/neuron/plugins/schema /home/admin/neuron/config /home/admin/neuron/persistence /home/admin/neuron/logs /home/admin/neuron/certs"

sshpass -p admin scp -o StrictHostKeyChecking=no -r /tmp/neuron-cm4/* \
  admin@192.168.142.193:/home/admin/neuron/
```

mkdir -p /tmp/neuron-dashboard
cd /tmp/neuron-dashboard
wget -O neuron-dashboard.zip \
  https://github.com/emqx/neuron-dashboard/releases/download/2.6.3/neuron-dashboard.zip
unzip -oq neuron-dashboard.zip
scp -r /tmp/neuron-dashboard/dist admin@192.168.142.193:/home/admin/neuron/


## 8. 在 CM4 上启动

```bash
cd /home/admin/neuron
export LD_LIBRARY_PATH=/home/admin/neuron/lib
./neuron --log
```

## 9. 和 RK3506 流程相比真正变化了什么

只有这些关键点需要改：

- `TARGET` 从 `arm-linux-gnueabihf` 改成 `aarch64-linux-gnu`
- 工具链包从 `gcc-arm-linux-gnueabihf` 改成 `gcc-aarch64-linux-gnu`
- OpenSSL 配置目标从 `linux-armv4` 改成 `linux-aarch64`
- `CMAKE_SYSTEM_PROCESSOR` 从 `arm` / `armv7l` 改成 `aarch64`
- 构建目录建议从 `build-armhf` 改成 `build-arm64`
- `STAGING` 目录建议改成 `~/neuron-staging/aarch64-linux-gnu`

其余目录整理、部署结构、启动方法和 RK3506 基本一致。

## 10. 额外说明

如果你在 CM4 上也遇到类似：

- `unexpected reloc type ...`

这通常不是 CM4 特有问题，而是共享库里混入了非 PIC 静态库。出现这种情况时，优先检查第三方依赖是否应该重新以共享库或 `-fPIC` 方式构建。
