---
name: caldav-sync
description: "CalDAV 日历同步服务 — 在个人服务器上基于 Baikal 搭建 CalDAV 服务，实现 iPhone 日历同步。触发词：搭建日历服务、部署CalDAV、安装日历同步、配置日历、连接iPhone日历、iPhone同步日历、iOS日历配置、日历同步失败、日历不同步、CalDAV排查、修复日历、查看日历状态、备份日历、恢复日历、日历服务状态、添加日历、创建日历、新建日历、删除日历、日历列表、重命名日历、日历改名、管理工作日历、家庭日历、个人日历、添加日程、新建日程、创建日程、添加事件、安排日程、提醒我、帮我记一下、明天下午、后天上午、下周、几点开会"
---

# CalDAV 日历同步 Skill

> **目标**：在本机服务器上部署 Baikal CalDAV 服务，配置 Nginx 反向代理 + Let's Encrypt SSL，实现 iPhone 日历同步。裸机部署，单用户场景。

## 触发规则

### 搭建部署类（触发完整部署流程）
用户说：`搭建日历服务` `部署CalDAV` `安装日历同步` `搭建CalDAV服务器` `部署日历同步`

→ 执行 **工作流 A：首次部署**

### 配置管理类
用户说：`配置日历` `添加日历用户` `日历权限` `SSL证书` `域名配置` `日历配置`

→ 执行对应子步骤或 **工作流 B：增量配置**

### 日历管理类
用户说：`添加日历` `创建日历` `新建日历` `删除日历` `日历列表` `重命名日历` `日历改名` `管理工作日历` `家庭日历` `个人日历` `添加一个日历`

→ 执行 **工作流 F：日历管理**

### 日程事件类
用户说：`添加日程` `新建日程` `创建日程` `添加事件` `安排` `提醒我` `帮我记一下` `记一个日程` `加个日程` `明天下午` `后天上午` `下周一` `下周` `几点开会` `什么时间`

→ 执行 **工作流 G：添加日程事件**

### 设备连接类
用户说：`连接iPhone日历` `iPhone同步日历` `iOS日历配置` `手机连日历` `iPad日历同步`

→ 执行 **工作流 C：设备连接指引**

### 诊断修复类
用户说：`日历同步失败` `日历不同步` `CalDAV排查` `修复日历` `同步出问题了`

→ 执行 **工作流 D：故障诊断**

### 运维操作类
用户说：`查看日历状态` `备份日历` `恢复日历` `日历服务状态`

→ 执行 **工作流 E：日常运维**

---

## 技术架构

```
用户 iPhone (iOS 日历 App)
        │
        ▼ HTTPS (443)
┌──────────────────────┐
│   Nginx (反向代理)    │  ← SSL 终止 (Let's Encrypt)
│   监听 443 端口       │
└────────┬─────────────┘
         │ HTTP (127.0.0.1:8080)
         ▼
┌──────────────────────┐
│   Baikal (PHP)       │  ← CalDAV / CardDAV 服务
│   内置 HTTP Server    │
└────────┬─────────────┘
         │
         ▼
┌──────────────────────┐
│   SQLite 数据库       │  ← 日历/联系人数据存储
└──────────────────────┘
```

### 关键路径

| 组件 | 路径/地址 |
|------|----------|
| Baikal 安装目录 | `/opt/baikal` |
| Nginx 配置 | `/etc/nginx/sites-available/caldav` |
| SSL 证书 | `/etc/letsencrypt/live/<域名>/` |
| Baikal 数据目录 | `/opt/baikal/Specific/` |
| PHP Built-in Server | `127.0.0.1:8080` |
| CalDAV 端点 | `https://<域名>/cal.php/principals/<用户名>/` |

---

## 工作流 A：首次部署

这是核心工作流，从零搭建完整 CalDAV 服务。按顺序执行以下步骤，每步完成后确认再继续。

### A1. 收集部署信息

部署前必须确认以下信息，缺少任何一项都**先询问用户**：

| 信息项 | 说明 | 示例 |
|--------|------|------|
| 域名 | 用于 CalDAV 服务的子域名 | `cal.example.com` |
| 邮箱 | Let's Encrypt 证书通知邮箱 | `admin@example.com` |
| 用户名 | CalDAV 登录用户名 | `myname` |
| 密码 | CalDAV 登录密码（或自动生成） | 自动生成 16 位随机密码 |

**询问模板**：
```
搭建 CalDAV 日历服务前需要确认以下信息：
1. 你准备用什么域名？（如 cal.example.com，需提前将 DNS A 记录指向本机 IP）
2. SSL 证书通知邮箱？
3. CalDAV 登录用户名？（默认用你当前用户名）
4. 登录密码？（留空则自动生成安全密码）
```

### A2. 检查系统环境

运行系统检查，确保依赖可用：

```bash
# 检查 PHP 版本（需要 >= 8.0）
php -v 2>/dev/null || echo "PHP_NOT_INSTALLED"

# 检查 PHP 必要扩展
php -m 2>/dev/null | grep -E "xml|mbstring|pdo_sqlite|sqlite3|ctype|json|filter|dom|libxml|simplexml|iconv"

# 检查 Nginx
nginx -v 2>/dev/null || echo "NGINX_NOT_INSTALLED"

# 检查 certbot
certbot --version 2>/dev/null || echo "CERTBOT_NOT_INSTALLED"

# 检查 80/443 端口
ss -tlnp | grep -E ':80 |:443 '
```

根据检查结果，缺什么装什么。参考 `references/dependencies.md` 了解各系统安装命令。

### A3. 部署 Baikal

执行 `scripts/deploy_baikal.sh` 完成 Baikal 下载、配置和启动：

```bash
sudo bash <skill-directory>/scripts/deploy_baikal.sh \
  --domain "<域名>" \
  --install-dir /opt/baikal \
  --port 8080
```

脚本执行内容：
1. 下载 Baikal 最新发行版到 `/opt/baikal`
2. 创建目录结构并设置权限
3. 生成 Baikal 配置文件 `config.php` 和 `Specific/config.system.php`
4. 初始化 SQLite 数据库
5. 创建 systemd service 文件 `baikal.service`
6. 启动 Baikal PHP 内置服务器（监听 127.0.0.1:8080）

部署完成后验证：

```bash
# 检查服务状态
sudo systemctl status baikal

# 检查端口监听
ss -tlnp | grep 8080

# 测试本地访问
curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8080/
```

### A4. 配置 Nginx 反向代理 + SSL

#### 4a. 先确认 DNS 解析生效：

```bash
dig +short <域名> A
# 应返回本机公网 IP
```

#### 4b. 申请 SSL 证书（HTTP-01 验证，需 80 端口可用）：

```bash
sudo certbot certonly --standalone \
  -d "<域名>" \
  --email "<邮箱>" \
  --agree-tos \
  --non-interactive
```

#### 4c. 写入 Nginx 配置：

读取参考模板 `references/nginx_config.md`，根据实际域名生成配置并写入 `/etc/nginx/sites-available/caldav`。

关键配置要点：
- 监听 443 端口，HTTP/2
- SSL 证书路径指向 Let's Encrypt
- 反向代理到 `http://127.0.0.1:8080`
- 透传 `Host`、`X-Forwarded-For`、`X-Forwarded-Proto` 头
- 限制请求体大小（日历数据通常不大，设 10M 即可）
- 增加 `.well-known` 路径用于证书续期

#### 4d. 启用站点并重载 Nginx：

```bash
sudo ln -sf /etc/nginx/sites-available/caldav /etc/nginx/sites-enabled/caldav
sudo nginx -t && sudo systemctl reload nginx
```

#### 4e. 验证 HTTPS 访问：

```bash
curl -s -o /dev/null -w "%{http_code}" https://<域名>/
# 应返回 200
```

### A5. 初始化 Baikal 并创建用户

部署完成后，通过 Baikal 的 Web 管理界面或命令行完成初始化。

**方式一：命令行初始化（推荐）**

执行 `scripts/init_baikal.sh`：

```bash
sudo bash <skill-directory>/scripts/init_baikal.sh \
  --install-dir /opt/baikal \
  --admin-password "<管理密码>"
```

**方式二：Web 界面初始化**

如果命令行方式不可行，引导用户访问 `https://<域名>/` 完成 Web 初始化：
1. 浏览器打开 `https://<域名>/`
2. 按向导设置管理员密码
3. 进入管理面板 → 创建用户
4. 为用户创建默认日历

### A6. 输出 iPhone 连接信息

部署成功后，输出以下信息给用户：

```
✅ CalDAV 日历服务部署完成！

📱 iPhone 连接配置：
━━━━━━━━━━━━━━━━━━━━━━━━━━━
设置 → 日历 → 账户 → 添加账户 → 其他 → 添加 CalDAV 账户

服务器：  <域名>
用户名：  <用户名>
密码：    <密码>
描述：    个人日历
使用 SSL： ✅ 开启
端口：    443
━━━━━━━━━━━━━━━━━━━━━━━━━━━

🔗 管理面板：https://<域名>/admin/
📋 详细配置指引见：references/iphone_setup_guide.md
```

---

## 工作流 B：增量配置

### 添加新用户

```bash
# 通过 Baikal 管理面板操作
# 引导用户访问 https://<域名>/admin/ 登录后添加
```

或使用脚本 `scripts/manage_user.sh`：

```bash
sudo bash <skill-directory>/scripts/manage_user.sh add \
  --install-dir /opt/baikal \
  --username "<用户名>" \
  --password "<密码>"
```

### 续期 SSL 证书

```bash
sudo certbot renew --dry-run  # 先测试
sudo certbot renew             # 正式续期
sudo systemctl reload nginx
```

建议设置自动续期 cron：
```bash
# 每天凌晨 3 点检查续期
echo "0 3 * * * root certbot renew --quiet --post-hook 'systemctl reload nginx'" | sudo tee /etc/cron.d/certbot-renew
```

### 修改域名

1. 重新申请新域名的 SSL 证书
2. 更新 Nginx 配置中的 `server_name`
3. 重载 Nginx
4. 更新 iPhone 上的服务器地址

---

## 工作流 F：日历管理

用户在 CalDAV 中管理日历的完整操作。用户说「添加日历」「创建工作日历」「删除日历」「有哪些日历」时触发。

### F1. 识别用户意图

从用户语句中提取关键信息，缺少则询问：

| 用户说 | 提取 |
|--------|------|
| `添加一个工作日历` | 操作=添加, 名称=工作, 显示名=工作日历 |
| `创建一个家庭日历` | 操作=添加, 名称=family, 显示名=家庭日历 |
| `帮我新建个人日历` | 操作=添加, 名称=个人, 显示名=个人日历 |
| `删除工作日历` | 操作=删除, 名称=工作 |
| `查看所有日历` / `日历列表` | 操作=列表 |
| `把工作日历改名为工作日程` | 操作=重命名, 旧名=工作, 新名=工作日程 |

如果用户只说「添加日历」没说明是什么日历，**主动询问**：
```
你想创建什么日历？比如：
- 工作日历（工作安排、会议）
- 家庭日历（家庭活动、纪念日）
- 个人日历（健身、学习计划）
也可以自定义名称和颜色。
```

### F2. 添加日历

使用 `scripts/manage_calendar.sh add`：

```bash
sudo bash <skill-directory>/scripts/manage_calendar.sh add \
  --username "<用户名>" \
  --calendar "<日历URI>" \
  --display-name "<显示名称>" \
  --color "<颜色代码>" \
  --description "<描述>" \
  --install-dir /opt/baikal
```

**参数说明**：

| 参数 | 必填 | 说明 | 示例 |
|------|------|------|------|
| `--username` | ✅ | CalDAV 用户名 | `myname` |
| `--calendar` | ✅ | 日历 URI（英文标识符，无空格） | `work`、`family`、`personal` |
| `--display-name` | 否 | iPhone 上显示的名称，默认同 calendar | `工作日历`、`家庭日历` |
| `--color` | 否 | 日历颜色，hex 格式 | `#FF9500`（橙色）、`#34C759`（绿色） |
| `--description` | 否 | 日历描述 | `工作安排与会议` |

**颜色预设**：

| 颜色名 | Hex | 适合场景 |
|--------|-----|----------|
| 蓝色 | `#007AFF` | 工作、商务 |
| 橙色 | `#FF9500` | 重要事项、截止日期 |
| 绿色 | `#34C759` | 家庭、生活 |
| 红色 | `#FF3B30` | 紧急、健康 |
| 紫色 | `#AF52DE` | 个人成长、学习 |
| 黄色 | `#FFCC00` | 生日、纪念日 |

**日历 URI 命名建议**：
- 用英文小写，无空格，无特殊字符
- `work`、`family`、`personal`、`health`、`study`、`travel`

**添加成功后**，告诉用户：
```
✅ 日历「显示名称」创建成功！

📱 iPhone 上打开日历 App → 底部点「日历」→ 勾选新日历即可看到。
如果没出现，下拉刷新一下。
```

### F3. 删除日历

使用 `scripts/manage_calendar.sh delete`：

```bash
sudo bash <skill-directory>/scripts/manage_calendar.sh delete \
  --username "<用户名>" \
  --calendar "<日历URI>" \
  --install-dir /opt/baikal
```

**重要**：删除前必须向用户确认！删除会永久丢失该日历下所有事件。

### F4. 查看日历列表

使用 `scripts/manage_calendar.sh list`：

```bash
# 查看所有日历
sudo bash <skill-directory>/scripts/manage_calendar.sh list --install-dir /opt/baikal

# 查看指定用户的日历
sudo bash <skill-directory>/scripts/manage_calendar.sh list --username "<用户名>" --install-dir /opt/baikal
```

输出示例：
```
user    calendar_id  display_name  color    events  components
──────  ───────────  ────────────  ───────  ──────  ──────────────────
myname  default      默认日历      #007AFF  42      VEVENT,VJOURNAL,VTODO
myname  work         工作日历      #FF9500  128     VEVENT,VJOURNAL,VTODO
myname  family       家庭日历      #34C759  15      VEVENT,VJOURNAL,VTODO
```

### F5. 重命名日历

使用 `scripts/manage_calendar.sh rename`：

```bash
sudo bash <skill-directory>/scripts/manage_calendar.sh rename \
  --username "<用户名>" \
  --calendar "<日历URI>" \
  --new-name "<新显示名称>" \
  --install-dir /opt/baikal
```

> **注意**：rename 只改显示名称，日历 URI 不变。iPhone 会自动同步新名称。

### F6. 日历 URI 与 iPhone 的关系

- 日历 URI 是内部标识符，用户在 iPhone 上看到的是 **显示名称**（display-name）
- 同一个用户可以有多个日历，每个日历独立显示在 iPhone 日历 App 中
- 用户可以在 iPhone 上选择显示或隐藏某个日历
- 日历颜色在 iPhone 端独立设置，服务器的颜色作为初始值

---

## 工作流 G：添加日程事件

用户通过自然语言描述日程，agent 自动解析时间、地点、内容并写入 CalDAV。用户说「明天下午3点开会」「周六晚上吃饭」「下周二体检」等时触发。

### G1. 解析自然语言

使用 `scripts/parse_event.py` 解析用户的自然语言描述：

```bash
python3 <skill-directory>/scripts/parse_event.py --json "<用户原文>"
```

解析器会自动提取：

| 字段 | 说明 | 示例输入 → 输出 |
|------|------|----------------|
| `title` | 日程标题 | "明天下午3点在301开会" → "301开会讨论Q3计划" |
| `start_time` | 开始时间（ISO） | "明天下午3点" → "2026-06-26T15:00:00" |
| `end_time` | 结束时间（默认+1h） | 自动计算 |
| `location` | 地点 | "在301" → "301" |
| `description` | 备注 | "记得空腹" → "空腹" |
| `calendar` | 日历归属（自动识别） | "开会讨论" → "工作" |
| `confidence` | 置信度 | `high` / `medium` |

**支持的时间表达**：

| 类型 | 示例 |
|------|------|
| 相对日期 | 今天下午3点、明天上午9点、后天晚上8点、大后天早上7点 |
| 星期 | 周一上午10点、下周三下午2点、下下周五 |
| 绝对日期 | 6月30日下午2点半、12月25日晚上7点 |
| 相对偏移 | 半小时后、2小时后、10分钟后 |
| 句中时间 | 晚上8点和朋友吃饭（自动判断今天/明天） |

**支持的日历自动识别**：

| 用户说 | 自动归属 |
|--------|----------|
| 开会、会议、汇报、项目、评审、上线 | → **工作** |
| 爸妈、家人、聚餐、吃饭、孩子 | → **家庭** |
| 健身、跑步、体检、学习、看书 | → **个人** |
| 生日、纪念日 | → **生日** |

### G2. 向用户确认

**关键步骤**：解析后必须向用户展示结果并确认，再写入数据库。

确认模板：
```
📅 解析结果确认：

  标题:   Q3计划讨论会
  时间:   2026年6月26日 15:00 - 16:00
  地点:   301会议室
  日历:   工作
  备注:   (无)

  确认添加吗？（回复「确认」或「好的」写入，回复「修改 XXX」调整）
```

如果 `confidence` 为 `medium`（时间解析不确定），**必须额外提示**：
```
⚠️ 时间解析不太确定，请确认时间是否正确。
```

### G3. 写入日程

用户确认后，使用 `scripts/add_event.sh` 写入：

```bash
sudo bash <skill-directory>/scripts/add_event.sh \
  --username "<用户名>" \
  --calendar "<calendar_uri>" \
  --title "<标题>" \
  --start "<YYYY-MM-DD HH:MM>" \
  --end "<YYYY-MM-DD HH:MM>" \
  --location "<地点>" \
  --description "<备注>" \
  --install-dir /opt/baikal
```

写入成功后的输出：
```
✅ 日程已添加

  标题:    Q3计划讨论会
  时间:    2026年06月26日 15:00 - 16:00
  地点:    301会议室
  日历:    work

📱 iPhone 上打开日历 App 即可看到，等待几秒自动同步。
```

### G4. 用户修改

如果用户说「把标题改成XXX」「时间不对，改成下午4点」等：
1. 重新调用 `parse_event.py` 解析修改后的文本
2. 或者直接接受用户指定的具体字段值
3. 重新确认后再写入

### G5. 删除日程

如果用户说「删除刚才那个日程」「取消明天下午的会议」：
1. 先查询匹配的日程（通过 `add_event.sh` 暂无删除功能，引导用户通过 Baikal 管理面板或 iPhone 端操作）
2. 未来可扩展 `add_event.sh delete` 子命令

### G6. 查询日程

如果用户说「明天有什么安排」「这周有什么日程」：
```bash
# 查询指定日期范围的日程
sqlite3 /opt/baikal/Specific/db.sqlite "
SELECT c.uri AS calendar, co.uid, 
       substr(co.calendardata, instr(co.calendardata, 'SUMMARY:')+8, 
              instr(substr(co.calendardata, instr(co.calendardata, 'SUMMARY:')), char(10))-1) AS title,
       datetime(co.firstoccurence, 'unixepoch', 'localtime') AS start_time,
       datetime(co.lastoccurence, 'unixepoch', 'localtime') AS end_time
FROM calendarobjects co
JOIN calendars c ON c.id = co.calendarid
WHERE co.firstoccurence >= strftime('%s', 'now', 'start of day')
  AND co.firstoccurence < strftime('%s', 'now', '+7 days')
ORDER BY co.firstoccurence;
"
```

### 完整示例

**用户说**：「明天下午3点在301开会讨论Q3计划」

**Agent 执行流程**：
1. 运行 `parse_event.py --json "明天下午3点在301开会讨论Q3计划"`
2. 解析得到：title=301开会讨论Q3计划, start=2026-06-26T15:00, calendar=工作
3. 展示确认信息给用户
4. 用户确认后运行 `add_event.sh`
5. 输出成功信息

---

## 工作流 C：设备连接指引

### iPhone / iPad 连接步骤

详细图文指引见 `references/iphone_setup_guide.md`。

快速步骤：
1. 打开 **设置** → **日历** → **账户** → **添加账户** → **其他**
2. 选择 **添加 CalDAV 账户**
3. 填写：
   - 服务器：`<域名>`（不带 https://）
   - 用户名：`<用户名>`
   - 密码：`<密码>`
   - 描述：`个人日历`
4. 点击 **下一步**，等待验证
5. 验证通过后，打开 **日历 App**，稍等片刻即可看到同步的日历

### 常见连接问题

| 问题 | 原因 | 解决 |
|------|------|------|
| "无法验证账户信息" | 密码错误或路径不对 | 检查密码，确认服务器地址不含 https:// |
| 连接超时 | 443 端口不通 | 检查防火墙、Nginx 状态 |
| SSL 错误 | 证书问题 | 检查证书是否过期 |
| 日历空白 | 用户未分配日历 | 登录管理面板创建日历 |

---

## 工作流 D：故障诊断

执行诊断脚本进行全面检查：

```bash
sudo bash <skill-directory>/scripts/diagnose.sh --domain "<域名>"
```

诊断项目：
1. **服务进程**：`baikal.service` 是否 running
2. **端口监听**：8080（Baikal）、443（Nginx）、80（HTTP）是否正常
3. **Nginx 状态**：配置语法是否正确，服务是否运行
4. **SSL 证书**：是否过期（Let's Encrypt 90 天有效期）
5. **DNS 解析**：域名是否正确指向本机 IP
6. **Baikal 响应**：HTTP 200 正常返回
7. **CalDAV 端点**：PROPFIND 请求是否正常
8. **磁盘空间**：数据目录是否有足够空间
9. **日志检查**：Nginx 错误日志、Baikal 日志有无异常

根据诊断结果给出针对性修复建议。参考 `references/troubleshooting.md` 了解常见故障处理。

---

## 工作流 E：日常运维

### 查看服务状态

```bash
# Baikal 状态
sudo systemctl status baikal

# Nginx 状态
sudo systemctl status nginx

# SSL 证书有效期
sudo certbot certificates
```

### 备份日历数据

```bash
sudo bash <skill-directory>/scripts/backup.sh \
  --install-dir /opt/baikal \
  --backup-dir /workspace/caldav-backups
```

备份内容：
- `Specific/` 目录（含 SQLite 数据库和用户数据）
- `config.php` 和 `Specific/config.system.php`
- Nginx 配置文件

### 恢复日历数据

```bash
sudo bash <skill-directory>/scripts/backup.sh restore \
  --backup-file /workspace/caldav-backups/baikal_backup_<日期>.tar.gz \
  --install-dir /opt/baikal
```

---

## 安全注意事项

1. **密码安全**：所有生成的密码通过安全方式展示给用户，不存储明文
2. **文件权限**：Baikal 数据目录权限设为 750，防止未授权访问
3. **防火墙**：确保只开放 80/443 端口对外，8080 仅本地监听
4. **自动更新**：建议定期检查 Baikal 新版本并升级
5. **日志清理**：Nginx 访问日志建议配置 logrotate

---

## 资源文件说明

### scripts/
- `deploy_baikal.sh` — Baikal 一键部署（下载、配置、启动 systemd 服务）
- `init_baikal.sh` — Baikal 初始化和管理员创建
- `manage_user.sh` — 用户管理（添加/删除/修改密码）
- `manage_calendar.sh` — 日历管理（添加/删除/列表/重命名）
- `parse_event.py` — 自然语言日程解析（提取时间、地点、标题、日历归属）
- `add_event.sh` — 日程事件写入（生成 ICS 数据并写入 SQLite）
- `diagnose.sh` — 全链路故障诊断
- `backup.sh` — 日历数据备份与恢复

### references/
- `nginx_config.md` — Nginx 反向代理配置模板（含详细注释）
- `iphone_setup_guide.md` — iPhone/iPad CalDAV 连接配置图文指南
- `troubleshooting.md` — 常见问题排查手册
- `dependencies.md` — 各 Linux 发行版 PHP/Nginx/certbot 安装命令
