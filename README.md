# 伴伴 · Vidu iOS 数字人 Demo

SwiftUI 数字人界面与 Vidu 国内 API 接口示例。**需要自行申请并配置 Vidu（api.vidu.cn）API Key。仓库不提供账号、额度或可用的公共后端，也不会连接作者的私人服务。**

未配置 API 时，可以查看三个演示角色、使用原图新增、编辑删除角色和播放内置音色样音。实时通话、场景生成不可用；配置后调用 Vidu 会按自己的账户计费。API Key 只放服务端，不能放进 iOS App。

## 已包含

- 小夏、星野、陆川三个演示角色。
- 新增角色：选图、起名后可直接加入；专属场景生成为可选步骤。
- 音色匹配失败不会阻止新增，支持手动选音色；公开版使用默认音色建议，不依赖额外 AI 服务。
- 未完成的场景可保存并恢复；不存在的任务沿用原编号恢复提交；不自动重建提交结果未知的付费任务。
- 列表左上角「编辑」可删除角色。默认角色小夏始终保留，删除当前角色后自动切回默认角色。
- 中文语音识别、实时通话控制、音色试听和前置摄像头小窗。

## 本地启动

需要 macOS、Xcode（iOS 17+）和 Node.js 20+、pnpm。

```sh
cp .env.example .env.local
# 编辑 .env.local，填写你自己的 VIDU_API_KEY
cd server
pnpm install --frozen-lockfile
pnpm start
```

然后打开 `ios/BedroomRoom.xcodeproj`，选择 iPhone 模拟器运行。模拟器访问本机 `127.0.0.1:8787`。首次允许麦克风与语音识别权限。

如果不配置 Key，也可以启动服务浏览本地界面；付费接口会提示缺少配置。

## iPhone 真机：同一 Wi-Fi 本地运行

不需要购买域名，也不需要使用作者的云端服务。先完成上面的依赖安装与 `.env.local` 配置，然后在 `server` 目录运行：

```sh
pnpm prepare:phone
pnpm start:phone
```

`prepare:phone` 会检测电脑的局域网 IPv4 地址，创建本机 HTTPS 证书和随机设备令牌，生成被 Git 忽略的 `DeviceConfig.json`，并自动将配置加入 Xcode 的 App 资源。若电脑有多个网卡，可明确指定：

```sh
pnpm prepare:phone --host 192.168.1.10
```

将示例地址换成你电脑的 Wi-Fi 地址。然后打开 Xcode 项目，在 Signing & Capabilities 中选择自己的 Team 和设备，编译安装到 iPhone。手机与电脑连接同一 Wi-Fi，首次允许 App 的本地网络权限；保持后端终端运行、电脑在线。若系统防火墙询问，允许该本地服务接收连接。访客 Wi-Fi 的设备隔离会阻止手机访问电脑，请使用允许设备互通的网络。

手机验证本机证书指纹、域名/IP 与有效期，并使用设备令牌鉴权；没有关闭 HTTPS 校验。Vidu Key 只存在运行后端的电脑上，不能写入 App。电脑地址变更后，重新运行 `prepare:phone` 并重新编译安装。

证书、令牌、生成任务与角色图片保存在被忽略的本地目录，不随仓库分发。仓库不包含作者的个人服务配置。需要部署自己的远程后端时，可参考 `ios/DeviceConfig.example.json`，使用自己的 HTTPS 地址及设备令牌；这不是运行本地 Demo 的前提。

## 验证范围

```sh
cd server
pnpm test
```

服务测试使用模拟上游，不产生 Vidu 费用。iOS 模拟器已验证新增保存、删除回退、默认角色保护、未完成任务恢复；另已用真实 Vidu 生图结果完成 iOS 模拟器和同一 Wi-Fi 下的 iPhone 下载、加入角色列表、选择角色与重启后保留验证；没有使用模拟生图返回。真机通话不在本次验证范围。模拟器的音频行为可能与真机不同。

## 资源与来源

服务端基于盛数官方 Vidu 示例，原许可证保留在 `server/UPSTREAM-LICENSE`。Aliyun RTC SDK、音色样音及演示图片不由本仓库授予额外的商业使用权；替换成有权使用的素材后再用于自己的产品。接口以 [Vidu 国内平台](https://platform.vidu.cn/) 文档为准。

更多页仅保留名字、人设和声音；连接状态、连接检查及 API 接入说明均不展示在产品设置中。
