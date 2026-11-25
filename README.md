# 签到中心 · SigninHub iOS 移植版

把 [Ayanguser/SigninHub](https://github.com/Ayanguser/SigninHub) 二开成 iPhone 可装的 IPA。
原仓库许可证为 **CC BY-NC-SA 4.0**：个人学习/研究/自用 OK；若分发二开版本，必须署名原作者+附原仓库链接、同样用 CC BY-NC-SA 4.0 开源、禁止商用。

## 一、构建 IPA（在 macOS 上）

前置：Xcode + [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）。

```bash
cd SigninHub-iOS
./build.sh
```

产物：`build/SigninHub-unsigned.ipa`（无签名）。

## 二、安装

| 方式 | 支持系统 | 说明 |
|---|---|---|
| **TrollStore（巨魔）** | iOS 14.0–16.6.1 / 17.0 | 直接装此 IPA，设备永久签名，无需续签。**iOS 16.7+ / 17.0.1+ / 18+ 不支持**（CoreTrust 漏洞已修） |
| **自签**（AltStore / Sideloadly / SideStore / 爱思） | **任意 iOS 版本** | 用你的 Apple ID 重新签名后安装；免费证书 7 天掉签，付费开发者账号 1 年 |

> 想要「不限系统版本」→ 只能自签。巨魔有硬性版本上限，两者不可兼得。

## 三、iOS 与安卓的差异（务必知晓）

- ❌ **不能到点静默全自动签到**：iOS 非越狱不给后台静默跑代码，BGTaskScheduler 只给「建议」不保证准点。实际形态是**打开 App 一键签到 / 点通知跳转后签到**。
- ❌ **无障碍自动点击**：iOS 无第三方无障碍 API，安卓的 `AutoClickService` 整条不可移植。
- ✅ 接口模式签到引擎、Keychain 凭据存储、webhook 通知、本地提醒 → 全部可移植，已实现。

## 四、配置（接口模式）

App「设置」页直接编辑 `config.json`。默认三个服务均为占位（未就绪），填入真实接口后即可真签到。

```json
{
  "providers": [
    {
      "kind": "workbuddy",
      "enabled": true,
      "http": {
        "method": "POST",
        "url": "https://实际抓到的签到接口",
        "headers": { "Content-Type": "application/json" },
        "body": { "如抓包": "字段" },
        "bodyType": "json",
        "successExpr": "code",
        "successValue": "0"
      },
      "tokenKey": "wbToken",
      "tokenHeader": "Authorization",
      "tokenPrefix": "Bearer "
    }
  ],
  "schedulerTimes": ["08:30"],
  "notify": { "enabled": false, "webhookURL": "https://api.day.app/<bark-key>" }
}
```

- `body` 内可用 `{date}` 占位当天日期。
- `successExpr` 支持 `data.status` 点路径。
- Token 在「签到」页各服务下方粘贴，存 Keychain（不落明文 config）。

### 已知接口（来自原仓库 README，签到 claim 端点随版本变，建议抓包确认）

| 服务 | 用途 | 接口 |
|---|---|---|
| WorkBuddy | 签到状态 | `POST /v2/billing/meter/checkin-activity-status` |
| WorkBuddy | 领取（claim） | 见原仓库 `docs/WORKBUDDY.md`（随版本变） |
| Trae Solo | session 换 token | `POST https://api.trae.cn/cloudide/api/v3/common/GetUserToken`（Cookie: `X-Cloudide-Session`） |
| Trae Solo | 签到状态 | `POST /trae/api/v2/ug/checkin_credits/status`（`Authorization: Cloud-IDE-JWT <token>` + `x-device-id`） |
| Trae Solo | 领取（claim） | 见原仓库 `docs/TRAE.md` |

## 五、工程结构

```
SigninHub-iOS/
├── project.yml            # XcodeGen 工程定义
├── build.sh               # 一键生成 .xcodeproj + archive + 打包 IPA
├── SigninHub/
│   ├── SigninHubApp.swift
│   ├── Models.swift       # 配置模型
│   ├── Keychain.swift     # 凭据存储
│   ├── CheckinEngine.swift# 接口模式引擎 + 成功判定 + 通知
│   ├── AppModel.swift     # 配置读写 + 编排 + 历史
│   ├── Scheduler.swift    # BGTask + 本地提醒
│   └── ContentView.swift  # UI（签到 / 记录 / 设置）
```

## 六、常见问题

- **最低系统**：iOS 15（如需降到 13，把 `async/await` 换成 completion handler 即可）。
- **Bundle ID**：默认 `com.signinhub.app`，如需改，编辑 `project.yml` 的 `PRODUCT_BUNDLE_IDENTIFIER`。
- **通知点开不自动签**：iOS 限制，点通知只是打开 App，需手动点「签到」。
