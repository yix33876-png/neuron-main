# RK3506 一键编译部署说明

本文档说明如何在客户自己的 Linux 主机上拉取项目源码，交叉编译 RK3506/ARMHF 版本，传输到 RK3506，并启动 NanoMQ 和 Neuron。

## 1. 前提

目标板：

```text
设备：RK3506
架构：armv7l / arm-linux-gnueabihf
默认 SSH：root/root
Neuron 部署目录：/opt/neuron
NanoMQ：/usr/local/bin/nanomq
```

Linux 主机需要先安装基础工具：

```bash
sudo apt-get update
sudo apt-get install -y \
  gcc-arm-linux-gnueabihf g++-arm-linux-gnueabihf \
  make cmake pkg-config git curl wget unzip tar \
  autoconf automake libtool gettext bison flex perl python3 \
  protobuf-compiler sshpass
```

还需要先准备好交叉编译依赖目录：

```bash
export TARGET=arm-linux-gnueabihf
export STAGING=$HOME/neuron-staging/$TARGET
```

`$STAGING` 中应已经包含 OpenSSL、zlog、jansson、mbedtls、NanoSDK/nng、libjwt、sqlite、protobuf-c、libxml2 等 ARMHF 依赖。完整依赖编译步骤见：

```text
docs/rk3506_armhf_build.md
```

## 2. 已有源码时一键编译、部署、启动

进入仓库根目录：

```bash
cd /path/to/neuron-main
```

执行：

```bash
scripts/build_deploy_start_rk3506.sh --host <RK3506_IP>
```

例如：

```bash
scripts/build_deploy_start_rk3506.sh --host 192.168.9.10
```

脚本会执行：

```text
1. 配置 ARMHF CMake 构建
2. 编译 Neuron 和插件
3. 打包 /tmp/neuron-rk3506
4. 传输到 root@<RK3506_IP>:/opt/neuron
5. 停止旧的 neuron/nanomq
6. 启动 NanoMQ
7. 启动 Neuron
8. 打印 7000 和 1883 端口状态
```

如果只更新 MQTT、MQTT Auth、MQTT Aggregate 插件，不覆盖完整 Neuron：

```bash
scripts/build_deploy_start_rk3506.sh --host <RK3506_IP> --plugins-only
```

如果只编译和传输，不启动服务：

```bash
scripts/build_deploy_start_rk3506.sh --host <RK3506_IP> --skip-start
```

如果目标板 SSH 密码不是 `root`：

```bash
scripts/build_deploy_start_rk3506.sh \
  --host <RK3506_IP> \
  --user root \
  --password '<password>'
```

## 3. 从 Git 仓库拉代码后一键部署

如果客户主机上还没有源码，可以使用：

```bash
scripts/bootstrap_rk3506_from_git.sh \
  --repo-url <GIT_REPO_URL> \
  --branch main \
  -- \
  --host <RK3506_IP>
```

示例：

```bash
scripts/bootstrap_rk3506_from_git.sh \
  --repo-url https://codeup.aliyun.com/<group>/<project>/neuron-main.git \
  --branch main \
  -- \
  --host 192.168.9.10
```

如果仓库是私有的，不建议把账号密码写进脚本。推荐使用：

```text
1. SSH key
2. Git credential manager
3. 阿里云 Codeup 个人访问令牌
```

也可以使用 SSH 地址：

```bash
scripts/bootstrap_rk3506_from_git.sh \
  --repo-url git@codeup.aliyun.com:<group>/<project>/neuron-main.git \
  --branch main \
  -- \
  --host 192.168.9.10
```

## 4. 一条命令给客户执行

如果脚本已经在 Git 仓库中，客户可以先克隆：

```bash
git clone <GIT_REPO_URL> neuron-main
cd neuron-main
scripts/build_deploy_start_rk3506.sh --host <RK3506_IP>
```

如果要做成真正的一条命令，可以在阿里云托管平台提供 raw 脚本地址，然后执行类似：

```bash
curl -fsSL '<RAW_BOOTSTRAP_SCRIPT_URL>' -o /tmp/bootstrap_rk3506_from_git.sh
bash /tmp/bootstrap_rk3506_from_git.sh \
  --repo-url '<GIT_REPO_URL>' \
  --branch main \
  -- \
  --host <RK3506_IP>
```

## 5. 启动后验证

Web：

```text
http://<RK3506_IP>:7000
```

MQTT 普通消息：

```bash
mosquitto_sub -h <RK3506_IP> -p 1883 -t 'neuron/#' -v
```

只看聚合消息：

```bash
mosquitto_sub -h <RK3506_IP> -p 1883 -t 'neuron/+/aggregate' -v
```

目标板上检查进程：

```bash
ssh root@<RK3506_IP>
ps | grep -E 'neuron|nanomq' | grep -v grep
netstat -lntp | grep -E ':(7000|1883)'
```

## 6. 注意事项

`build_deploy_start_rk3506.sh` 默认会启动目标板已有的：

```text
/usr/local/bin/nanomq
```

并使用：

```text
/root/nanomq-local.conf
```

如果客户板子上还没有 NanoMQ，需要先安装或单独部署 NanoMQ。Neuron 的一键部署脚本不会从源码编译 NanoMQ。

## 7. 使用 GitHub Release 分发编译产物

如果不希望客户在自己的 Linux 主机上编译，可以把 RK3506 编译产物打成 Release 资产。

### 7.1 生成 Release tar.gz

在开发主机上执行：

```bash
cd /path/to/neuron-main
export STAGING=$HOME/neuron-staging/arm-linux-gnueabihf

scripts/make_rk3506_release_bundle.sh --version v1.0.0
```

生成：

```text
dist/neuron-rk3506-v1.0.0.tar.gz
dist/neuron-rk3506-v1.0.0.tar.gz.sha256
```

这个 tar.gz 里面包含：

```text
neuron/
  neuron
  lib/
  plugins/
  plugins/schema/
  config/
  persistence/
  logs/
  dist/

deploy_rk3506_release_bundle.sh
```

把 `dist/neuron-rk3506-v1.0.0.tar.gz` 和 `.sha256` 上传到 GitHub Release 或阿里云托管平台 Release。

### 7.2 客户从 Release 部署到 RK3506

如果客户已经下载 tar.gz 到本地：

```bash
bash deploy_rk3506_release_bundle.sh \
  --host <RK3506_IP> \
  --bundle-file neuron-rk3506-v1.0.0.tar.gz
```

如果客户直接从 Release URL 下载并部署：

```bash
curl -fsSL '<RAW_DEPLOY_SCRIPT_URL>' -o /tmp/deploy_rk3506_release_bundle.sh

bash /tmp/deploy_rk3506_release_bundle.sh \
  --host <RK3506_IP> \
  --bundle-url 'https://github.com/<user>/<repo>/releases/download/v1.0.0/neuron-rk3506-v1.0.0.tar.gz'
```

这样客户不需要编译 Neuron，只需要：

```text
1. Linux 主机能 SSH 到 RK3506
2. Linux 主机安装 sshpass、curl、tar
3. RK3506 上已有 /usr/local/bin/nanomq 和 NanoMQ 配置
```

### 7.3 创建 GitHub Release 的建议

源码仓库里不要提交 `build-armhf/`、`dist/*.tar.gz`、`*.so` 这些编译产物。当前 `.gitignore` 已经忽略了它们。

推荐流程：

```bash
git tag v1.0.0
git push origin main
git push origin v1.0.0
```

然后在 GitHub 页面创建 Release，选择 `v1.0.0` tag，上传：

```text
dist/neuron-rk3506-v1.0.0.tar.gz
dist/neuron-rk3506-v1.0.0.tar.gz.sha256
```

如果安装了 GitHub CLI，也可以：

```bash
gh release create v1.0.0 \
  dist/neuron-rk3506-v1.0.0.tar.gz \
  dist/neuron-rk3506-v1.0.0.tar.gz.sha256 \
  --title "RK3506 Neuron v1.0.0" \
  --notes "Neuron RK3506 build with MQTT Auth and MQTT Aggregate plugins."
```
