# Neuron 在 RK3506 上的 ARMHF 交叉编译与部署记录

本文档记录了一套已经验证可用的流程：

- 在 `x86_64 Linux` 主机上交叉编译开源版 `Neuron`
- 目标平台为 `RK3506`
- 目标架构为 `armhf / armv7l / arm-linux-gnueabihf`
- 最终部署目录为设备上的 `/opt/neuron`

本文档中的命令和问题处理过程，已经在一台 IP 为 `192.168.142.176` 的 RK3506 设备上实际验证通过。

## 1. 环境说明

### 1.1 主机环境

- 编译主机：`x86_64 Linux`
- 交叉编译器前缀：`arm-linux-gnueabihf`

### 1.2 目标设备环境

- 设备：`RK3506`
- 架构：`armv7l`
- 部署路径：`/opt/neuron`

## 2. 主机上先安装基础工具

先在编译主机安装基础依赖：

```bash
sudo apt-get update
sudo apt-get install -y \
  gcc-arm-linux-gnueabihf g++-arm-linux-gnueabihf \
  make cmake pkg-config git curl wget unzip tar \
  autoconf automake libtool gettext bison flex perl python3 \
  protobuf-compiler sshpass
```

说明：

- `gcc-arm-linux-gnueabihf` / `g++-arm-linux-gnueabihf`：ARMHF 交叉编译器
- `protobuf-compiler`：宿主机上的 `protoc`
- `sshpass`：后续部署到 RK3506 时用

## 3. 统一环境变量

必须统一使用一个 `STAGING` 目录，不要混用多个路径，否则后面很容易出现一部分库装到这个目录，另一部分库装到另一个目录，最终 `cmake` 找库会混乱。

建议直接用下面这组：

```bash
export TARGET=arm-linux-gnueabihf
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

建议专门创建一个依赖编译目录：

```bash
mkdir -p ~/neuron-armhf-build
cd ~/neuron-armhf-build
```

## 4. 需要交叉编译的第三方依赖

本次可用构建使用了以下依赖：

- OpenSSL
- zlog
- jansson
- mbedtls
- NanoSDK / nng
- libjwt
- sqlite
- protobuf-c
- libxml2

说明：

- `protobuf` C++ 库这次没有作为必须项补进最终 `STAGING`
- 当前仓库已经自带 `*.pb-c.c` 和 `*.pb-c.h`
- `Neuron` 链接时实际依赖的是 `protobuf-c`

## 5. 依赖交叉编译命令

### 5.1 OpenSSL

注意：

- `OpenSSL` 这一项比较特殊
- 在执行 `./Configure` 时，不要保留前面导出的 `CC/CXX/AR/...`
- 否则会出现前缀被重复拼接，变成：
  `arm-linux-gnueabihf-arm-linux-gnueabihf-gcc`

正确命令如下：

```bash
cd ~/neuron-armhf-build
rm -rf openssl
git clone --branch OpenSSL_1_1_1w --depth 1 https://github.com/openssl/openssl.git
cd openssl

unset CC CXX AR AS LD NM RANLIB STRIP

./Configure linux-armv4 no-tests no-shared \
  --prefix=$STAGING \
  --cross-compile-prefix=${TARGET}-

make -j$(nproc) build_libs
make install_sw
```

OpenSSL 编译完成后，把交叉编译变量重新导出回来：

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

### 5.2 zlog

```bash
cd ~/neuron-armhf-build
rm -rf zlog
git clone -b 1.2.15 https://github.com/HardySimpson/zlog.git
cd zlog
make DEBUG='' CC=$CC AR=$AR CFLAGS="$CFLAGS"
make DEBUG='' PREFIX=$STAGING install
```

说明：

- 如果当前 shell 里存在 `DEBUG=release` 之类的环境变量，`zlog` 的原始 `makefile` 会把它直接拼进编译参数，导致交叉编译报错
- 显式写 `DEBUG=''` 可以避免这类环境污染
- 安装完成后，建议确认 `$STAGING/lib` 下已经出现 `libzlog.a`、`libzlog.so`、`libzlog.so.1.2`

### 5.3 jansson

```bash
cd ~/neuron-armhf-build
rm -rf jansson
git clone https://github.com/neugates/jansson.git
cd jansson
cmake -S . -B build \
  -DCMAKE_SYSTEM_NAME=Linux \
  -DCMAKE_SYSTEM_PROCESSOR=arm \
  -DCMAKE_C_COMPILER=$CC \
  -DCMAKE_INSTALL_PREFIX=$STAGING \
  -DCMAKE_PREFIX_PATH=$STAGING \
  -DJANSSON_BUILD_DOCS=OFF \
  -DJANSSON_EXAMPLES=OFF
cmake --build build -j$(nproc)
cmake --install build
```

安装完成后，建议确认 `$STAGING/lib/libjansson.a` 已存在。

### 5.4 mbedtls

```bash
cd ~/neuron-armhf-build
rm -rf mbedtls
git clone -b v2.16.12 https://github.com/Mbed-TLS/mbedtls.git
cd mbedtls
cmake -S . -B build \
  -DCMAKE_SYSTEM_NAME=Linux \
  -DCMAKE_SYSTEM_PROCESSOR=arm \
  -DCMAKE_C_COMPILER=$CC \
  -DCMAKE_INSTALL_PREFIX=$STAGING \
  -DUSE_SHARED_MBEDTLS_LIBRARY=OFF \
  -DENABLE_TESTING=OFF \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON
cmake --build build -j$(nproc)
cmake --install build
```

### 5.5 sqlite

```bash
cd ~/neuron-armhf-build
curl -L -o sqlite3.tar.gz https://www.sqlite.org/2022/sqlite-autoconf-3390000.tar.gz
rm -rf sqlite3-src
mkdir -p sqlite3-src
tar xzf sqlite3.tar.gz --strip-components=1 -C sqlite3-src
cd sqlite3-src
./configure --host=$TARGET --prefix=$STAGING CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS"
make -j$(nproc)
make install
```

### 5.6 NanoSDK / nng

```bash
cd ~/neuron-armhf-build
rm -rf NanoSDK
git clone https://github.com/neugates/NanoSDK.git
cd NanoSDK
cmake -S . -B build \
  -DCMAKE_SYSTEM_NAME=Linux \
  -DCMAKE_SYSTEM_PROCESSOR=arm \
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

### 5.7 libjwt

注意：

- 这一步必须建立在 OpenSSL 已经安装到 `$STAGING` 的前提下
- 否则 `libjwt` 会出现：
  - `OPENSSL_CRYPTO_LIBRARY-NOTFOUND`
  - `OPENSSL_SSL_LIBRARY-NOTFOUND`

命令如下：

```bash
cd ~/neuron-armhf-build
rm -rf libjwt
git clone -b v1.13.1 https://github.com/benmcollins/libjwt.git
cd libjwt

cmake -S . -B build \
  -DCMAKE_SYSTEM_NAME=Linux \
  -DCMAKE_SYSTEM_PROCESSOR=arm \
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

安装完成后，建议确认 `$STAGING/lib/libjwt.a` 已存在。

### 5.8 protobuf-c

```bash
cd ~/neuron-armhf-build
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

### 5.9 libxml2

注意：

- `libxml2` 这一项必须使用：
  `NOCONFIGURE=1 ./autogen.sh`
- 否则 `autogen.sh` 会自己先跑一次宿主机的 `configure`
- 结果会把它错误编成 `x86_64` 版本

正确命令如下：

```bash
cd ~/neuron-armhf-build
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

## 6. 检查依赖是否已经正确安装到 STAGING

编完后执行：

```bash
find $STAGING/lib -maxdepth 1 | sort
find $STAGING/lib/pkgconfig -maxdepth 1 -name '*.pc' | sort
```

本次最终在 `$STAGING/lib` 中实际确认存在的关键库包括：

- `libcrypto.a`
- `libssl.a`
- `libzlog.a`
- `libzlog.so*`
- `libjansson.a`
- `libjwt.a`
- `libmbedtls.a`
- `libmbedx509.a`
- `libmbedcrypto.a`
- `libnng.a`
- `libsqlite3.a`
- `libsqlite3.so*`
- `libprotobuf-c.a`
- `libxml2.a`

如果要确认它们确实是 `ARMHF` 产物，而不是宿主机产物，可以这样检查：

```bash
o=$(ar t $STAGING/lib/libssl.a | head -n 1)
ar p $STAGING/lib/libssl.a "$o" > /tmp/libssl_check.o
file /tmp/libssl_check.o
```

正常结果应该包含：

- `ARM`
- `EABI5`

## 7. 这次为 ARMHF 构建修改过的仓库文件

本次为了让 `Neuron` 在 ARMHF 交叉构建中真正通过，对以下文件做了必要修改：

- `cmake/arm-linux-gnueabihf.cmake`
- `CMakeLists.txt`
- `plugins/ekuiper/CMakeLists.txt`
- `plugins/monitor/CMakeLists.txt`

### 7.1 修改原因

主要原因有四个：

1. 原始的 `arm-linux-gnueabihf.cmake` 写死了 staging 路径
2. 原始工具链文件会尝试把文件复制到 `/usr/local/lib`
3. 顶层 `CMakeLists.txt` 以及部分插件使用裸链接方式，例如：
   `-lnng -ljwt -lxml2`
4. `plugins/datalayers` 依赖 Arrow/gRPC，这次没有交叉编，必须先关掉

### 7.2 推荐做法：直接执行补丁脚本

开发文档里不要直接粘贴整段补丁内容，写清楚“执行哪个脚本”就够了。

仓库里已经提供了补丁脚本：

```bash
cd /path/to/neuron-main
bash scripts/apply_rk3506_armhf_patch.sh
```

说明：

- 这个脚本现在使用的是仓库相对路径
- 不再依赖 `/home/xxx/...` 这种绝对路径
- 换一台机器、换一个用户名、换一个工作目录，只要仓库内容完整，就可以直接执行

### 7.3 脚本实际修改了什么

如果需要在文档里说明“补丁改了哪些点”，建议只保留下面这种摘要，不要贴完整 diff。

- `cmake/arm-linux-gnueabihf.cmake`
  改为从环境变量 `STAGING` 或 `-DCMAKE_STAGING_PREFIX` 读取第三方库目录，去掉写死路径和向 `/usr/local/lib` 复制文件的逻辑。
- `CMakeLists.txt`
  增加 `ENABLE_DATALAYERS` 开关；使用 `find_library` 在 `$STAGING/lib` 中显式定位 `nng`、`jwt`、`xml2`、`sqlite3`、`protobuf-c`、`mbedtls` 等库，避免裸 `-lxxx` 在交叉链接时找错库或找不到库。
- `plugins/ekuiper/CMakeLists.txt`
  把 `nng` 的裸链接改成复用顶层解析出来的 `${NEURON_LIB_NNG}`。
- `plugins/monitor/CMakeLists.txt`
  把 `nng` 的裸链接改成复用顶层解析出来的 `${NEURON_LIB_NNG}`。

如果你希望完全不依赖脚本，也可以手工按上面 4 条修改仓库文件，但文档里没必要展开成几百行 patch。

## 8. Neuron 本体的 ARMHF 配置与编译

本次验证通过的构建命令如下：

```bash
cd /path/to/neuron-main

export STAGING=$HOME/neuron-staging/arm-linux-gnueabihf

cmake -S . \
  -B build-armhf \
  -DCMAKE_TOOLCHAIN_FILE=cmake/arm-linux-gnueabihf.cmake \
  -DCMAKE_BUILD_TYPE=Release \
  -DDISABLE_UT=ON \
  -DDISABLE_ASAN=ON \
  -DDISABLE_WERROR=ON \
  -DENABLE_DATALAYERS=OFF

cmake --build build-armhf -j$(nproc)
```

说明：

- `ENABLE_DATALAYERS=OFF`
  这次必须关闭，否则会卡在 Arrow/gRPC
- `DISABLE_UT=ON`
  不编单元测试
- `DISABLE_ASAN=ON`
  不启用 ASAN

## 9. 检查最终 ARMHF 产物

编完后执行：

```bash
file build-armhf/neuron
file build-armhf/libneuron-base.so
file build-armhf/plugins/libplugin-modbus-tcp.so
file build-armhf/plugins/libplugin-mqtt.so
file build-armhf/plugins/libplugin-monitor.so
file build-armhf/plugins/libplugin-ekuiper.so
```

本次实际检查结果都显示为：

- `ELF 32-bit`
- `ARM`
- `EABI5`

这说明最终生成的是可以给 RK3506 用的目标文件。

## 10. 部署到 RK3506 前的目录结构建议

设备上建议部署成下面这样：

```text
/opt/neuron
  neuron
  lib/
  plugins/
  plugins/schema/
  config/
  persistence/
  logs/
  dist/
  certs/
```

至少要拷这些内容：

- `build-armhf/neuron`
- `build-armhf/libneuron-base.so`
- `build-armhf/plugins/*.so`
- `build-armhf/plugins/schema/*.json`
- `default_plugins.json`
- `dev.conf`
- `zlog.conf`
- `sdk-zlog.conf`
- `neuron.json`
- `persistence/*.sql`
- `$STAGING/lib/libzlog.so*`

本次运行时最少确认需要带上的动态库是：

- `libneuron-base.so`
- `libzlog.so*`

## 10.1 一键整理本地部署目录

如果不想手工一项一项复制，可以直接执行仓库里的打包脚本：

```bash
cd /path/to/neuron-main
export STAGING=$HOME/neuron-staging/arm-linux-gnueabihf
bash scripts/package_rk3506_bundle.sh
```

如果你是把脚本正文直接复制到终端执行，也可以运行，但当前目录必须位于 `neuron-main` 仓库内；否则请显式传：

```bash
bash scripts/package_rk3506_bundle.sh --root-dir /path/to/neuron-main
```

默认会生成：

```text
/tmp/neuron-rk3506
```

脚本会自动整理这些内容：

- `build-armhf/neuron`
- `build-armhf/libneuron-base.so`
- `build-armhf/plugins/*.so`
- `build-armhf/plugins/schema/*.json`
- `default_plugins.json`
- `dev.conf`
- `zlog.conf`
- `sdk-zlog.conf`
- `neuron.json`
- `persistence/*.sql`
- `$STAGING/lib/*.so*`
- `/tmp/neuron-dashboard/dist`（如果存在）

额外说明：

- `persistence/*.sql` 会同时复制到 `config/` 和 `persistence/`，这样首次启动时不需要再手工补 schema
- 脚本会自动创建空的 `persistence/plugins.json`
- 如果本机还没有 `/tmp/neuron-dashboard/dist`，脚本会给出 warning，但仍然完成 Neuron 本体打包

常用可选参数：

```bash
bash scripts/package_rk3506_bundle.sh --output-dir /tmp/my-neuron-rk3506
bash scripts/package_rk3506_bundle.sh --dashboard-dir /path/to/dist
bash scripts/package_rk3506_bundle.sh --skip-dashboard
```

## 11. 部署到 RK3506 的命令示例

先在目标板子上创建目录：

```bash
sshpass -p root ssh -o StrictHostKeyChecking=no root@192.168.142.176 \
  "mkdir -p /opt/neuron/lib /opt/neuron/plugins/schema /opt/neuron/config /opt/neuron/persistence /opt/neuron/logs"
```

如果本地已经整理好 `/tmp/neuron-rk3506` 目录，可以这样传：

```bash
sshpass -p root scp -o StrictHostKeyChecking=no -r /tmp/neuron-rk3506/* \
  root@192.168.142.176:/opt/neuron/
```

## 12. 首次启动时在 RK3506 上需要做的修复

这一部分非常关键，因为第一次启动时最容易踩坑。

### 12.1 SQL schema 文件必须能从 `./config` 被读到

程序初始化 SQLite schema 时，实际读取的是：

- `./config`

不是：

- `./persistence`

如果 SQL 文件只在 `/opt/neuron/persistence` 下，启动时会报：

- `directory './config' contains no schema files`
- `no such table: settings`
- `no such table: nodes`

修复方式：

```bash
mkdir -p /opt/neuron/config
cp -f /opt/neuron/persistence/*.sql /opt/neuron/config/
```

### 12.2 如果之前错误启动过，先删掉空数据库

如果程序已经在 schema 缺失的情况下创建过空数据库，要先删：

```bash
rm -f /opt/neuron/persistence/sqlite.db \
      /opt/neuron/persistence/sqlite.db-shm \
      /opt/neuron/persistence/sqlite.db-wal
```

然后再重新启动。

### 12.3 创建 `certs` 目录

程序启动时会扫描 `certs` 目录做 JWT 相关初始化。

如果没有这个目录，会看到：

- `Open dir error: No such file or directory`

修复方式：

```bash
mkdir -p /opt/neuron/certs
```

### 12.4 可选：创建空的 `persistence/plugins.json`

如果 `persistence/plugins.json` 不存在，会看到：

- `cannot load user plugins`

这不是致命错误，但如果想消掉告警，可以创建一个空文件：

```bash
printf '{"plugins":[]}\n' > /opt/neuron/persistence/plugins.json
```

### 12.5 如果提示“进程已经在运行”，但实际没进程

如果日志里出现：

- `neuron process already running, exit.`

但实际上并没有存活进程，通常是残留的 PID 文件导致的：

```bash
rm -f /tmp/neuron.pid
```

## 13. 在 RK3506 上启动 Neuron

前台运行：

```bash
cd /opt/neuron
export LD_LIBRARY_PATH=/opt/neuron/lib
./neuron --log
```

后台运行：

```bash
cd /opt/neuron
export LD_LIBRARY_PATH=/opt/neuron/lib
nohup ./neuron --log >/tmp/neuron-start.log 2>&1 &
```

查看状态：
ps -ef | grep '[n]euron'
sed -n '1,200p' /tmp/neuron-start.log

本次最终启动成功后，关键日志包括：

- schema 全部成功 apply
- `bind url: http://0.0.0.0:7000`
- 插件加载成功
- `manager start`

## 14. `/web` 返回 404 的原因和修复

`Neuron` 的 HTTP 路由中，`/web` 实际映射到本地目录：

- `./dist`

如果设备上没有：

- `/opt/neuron/dist`

那么访问：

- `http://192.168.142.176:7000/web`

就会返回：

- `404 Not Found`

### 14.1 下载 dashboard

本次使用的是官方 dashboard 版本 `2.6.3`：

```bash
mkdir -p /tmp/neuron-dashboard
cd /tmp/neuron-dashboard
wget -O neuron-dashboard.zip \
  https://github.com/emqx/neuron-dashboard/releases/download/2.6.3/neuron-dashboard.zip
unzip -oq neuron-dashboard.zip
```

### 14.2 部署 dashboard 到设备

```bash
scp -r /tmp/neuron-dashboard/dist root@192.168.142.176:/opt/neuron/
```

传完之后，刷新：

```text
http://192.168.142.176:7000/web
```

## 15. 本次最终验证通过的状态

最终在 RK3506 上，已经确认：

- `Neuron` 能正常启动
- SQLite schema 能正常初始化
- HTTP API 绑定到 `7000`
- `modbus / mqtt / ekuiper / file / monitor` 等插件能正常加载
- `/web` 对应的 dashboard 静态文件已经部署完成

## 16. 已知说明

- 本次构建关闭了 `plugins/datalayers`
  因为没有交叉编译 Arrow/gRPC
- `load default-dashboard setting fail`
  在空数据库首次启动时属于正常现象，不是致命错误
- `cannot load user plugins`
  如果 `persistence/plugins.json` 为空或不存在，会出现该告警，但不影响程序主流程
