# OneDrive 同步设置（Microsoft Graph + OAuth）

App 通过**微软登录授权**直接读写你 OneDrive 里的一个 App 专属文件夹（`Apps/Explore Journal/`），
不再依赖系统文件选择器（方案 B 在很多机型上选不到 OneDrive 文件夹，已弃用）。

实现：授权码 + PKCE 流程（`lib/services/sync/onedrive_service.dart`）。点「连接 OneDrive」后，
微软登录页在应用内浏览器标签打开，授权后通过自定义 scheme 回跳，App 拿到授权码换取令牌。只申请
最小权限 `Files.ReadWrite.AppFolder`（仅能动它自己的文件夹）。

> **客户端 ID 一次性内置，用户无需手填。** 维护者注册 Azure 应用拿到 client ID 后，把它写进
> `OneDriveService.defaultClientId`，或构建时
> `flutter build apk --release --dart-define=ONEDRIVE_CLIENT_ID=<你的id>`。这样发出去的包里用户
> 只要点「连接 OneDrive（跳转微软登录）」就直接跳转，**不用再粘贴 ID**。（没内置时，设置页才会
> 出现一个可选的覆盖输入框。）

---

## 一次性准备（维护者做一次）

### 第 0 步：为什么会「无法注册应用程序」

用个人微软账号（outlook/hotmail/live）登录 Entra 时，你默认待在一个叫
**「Microsoft Services」的租户**里——**这个租户不支持应用注册**。所以哪怕你已经注册了 Azure，在
应用注册页（ApplicationsListBlade）还是会显示「无法注册应用程序」。

解决办法只有一个：**建一个属于你自己的 Entra 租户，再把门户「切换」到那个租户里**。最容易漏的
就是「切换目录」这一步——很多人建完租户但门户还停在 Microsoft Services，于是一直注册不了。

> ⚠️ 别再纠结 M365 开发者计划——它现在基本只发给有 Visual Studio 订阅的人，多数人会被拒
> （“You don't currently qualify…”）。下面这条免费、通常不需要信用卡。

### 第 1 步：创建你自己的 Entra 租户
1. 打开 **https://entra.microsoft.com** ，个人微软账号登录。
2. 左侧 **Identity（标识）→ Overview（概述）→ Manage tenants（管理租户）→ ＋ Create（创建）**。
   （或直接访问 `https://entra.microsoft.com/#view/Microsoft_AAD_IAM/TenantOverview.ReactView`）
3. 类型选 **Microsoft Entra ID**（不是 B2C）→ Next。
4. 填 组织名 / 初始域名（如 `mytravel`）/ 国家 → **Review + create** → 过一下人机验证 → **Create**。
   建免费 Entra ID 租户不需要付费订阅。

### 第 2 步：切换到这个新租户（关键，别漏）
- 右上角**设置齿轮 ⚙ → Directories + subscriptions（目录 + 订阅）**，或 **Manage tenants** 列表里
  勾选刚建的租户 → **Switch（切换）**。
- 切换后确认**右上角显示的是新租户名**（如 “mytravel”），而**不是 “Microsoft Services” / 你的
  @outlook.com 默认目录**。在错误的目录里，注册按钮会一直灰/报错。

### 第 3 步：在新租户里注册应用
1. **App registrations（应用注册）→ New registration（新注册）**。现在能注册了。
2. **受支持的账户类型**：选「**任何组织目录中的帐户 + 个人 Microsoft 帐户**」
   （`AzureADandPersonalMicrosoftAccount`）——这样别人（以及你自己）用个人微软账号也能登录、访问
   各自的 OneDrive。
3. **重定向 URI**：平台选「**移动和桌面应用程序（Mobile and desktop applications）**」，填：
   ```
   com.explorejournal.oauth://auth
   ```
   必须与 `OneDriveService.redirectUri` 完全一致。

   **⚠️ Web 版还需要额外一个平台**：浏览器无法把自定义 scheme 跳回网页（表现为
   微软登录完成后弹「要打开 …oauth 吗？」然后没有任何反应），所以 web 走
   `auth.html` 回调页。在「身份验证 → 添加平台」中再加一个
   「**单页应用程序（Single-page application, SPA）**」平台——**必须是 SPA
   而不是 Web/移动平台**，否则浏览器侧的 token 交换会被拒绝
   （`AADSTS9002326`）。重定向 URI 按你的部署填（可多个）：
   ```
   https://ej-front.<你的域名>/auth.html     ← web-front 经 Cloudflare Tunnel（推荐姿态）
   http://<NAS 或本机>:48080/auth.html       ← web-front 局域网直连（应用在根路径）
   https://<你的域名>/app/auth.html          ← 线上宣传站（build-site.sh 的 /app/ 部署）
   ```

   > 有几种访问方式就加几条，因为回调路径与 origin 都不同：**web-front 镜像**把
   > 应用托管在根路径，所以回调是 `/auth.html`（经隧道访问时 origin 变成那个
   > `https://ej-front.…` 子域，得单独再加一条）；**宣传站**把应用放在 `/app/` 下，
   > 所以回调是 `/app/auth.html`。重定向 URI 必须与页面实际所在的 origin + 路径
   > 逐字一致，Azure 不做前缀匹配。隧道那条见
   > [web-display-deploy.md](web-display-deploy.md#经-cloudflare-tunnel-暴露到公网推荐)。
   >
   > 早先文档里写的 `48082` 是那个已经不存在的独立静态服务的端口——现在 web 由
   > web-front 自己在 **48080** 上托管。
4. **Register** 后，在「**概述（Overview）**」复制 **应用程序(客户端) ID**。

### 第 4 步：权限 + 公共客户端
5. 「**API 权限**」→ 添加 → Microsoft Graph → **委托的权限**，加上：
   - `Files.ReadWrite.AppFolder`
   - `offline_access`（拿 refresh token，长期免重复登录）
   - `User.Read`（仅用于显示登录的是哪个账号）
   个人账户无需管理员同意。
6. 「**身份验证**」→ 把「**允许公共客户端流（Allow public client flows）**」设为 **是**
   （移动端 PKCE 公共客户端，无 client secret）。

### 第 5 步：内置 client ID
- 把第 3 步拿到的 ID 写进 `lib/services/sync/onedrive_service.dart` 的
  `defaultClientId`（改 `defaultValue`），或构建时用
  `--dart-define=ONEDRIVE_CLIENT_ID=你的id`。
- 重新构建。之后 App 里点「连接 OneDrive」即直接跳转登录。

---

## App 内使用（终端用户）
1. 设置 → 导出与导入 → **OneDrive（微软账号登录）** → 点「**连接 OneDrive（跳转微软登录）**」。
2. 完成微软登录授权后，即可「**立即同步到 OneDrive**」/「**从 OneDrive 恢复**」。备份 zip 与本地
   导出 / WebDAV 同格式，按勾选模块增量合并（UUID 去重）。

## 说明
- refresh token 存本地，并已加入备份导出的**敏感字段剥离**名单，不会进导出 zip。
- 大备份走**可续传上传会话**（5 MiB 分块），不受 4 MB 简单上传限制。
- iOS 无需额外配置（ASWebAuthenticationSession 直接用回调 scheme）；Android 已在
  `AndroidManifest.xml` 注册 `com.linusu.flutter_web_auth_2.CallbackActivity` 接收回跳。
- 回调 scheme `com.explorejournal.oauth` 不能带下划线（flutter_web_auth_2 的限制），所以没用
  bundle id。
