# ربات مستقل لینوکس برای نصب ۱۰۰٪ خودکار WhiteDNS Soar Server

این ربات به صورت **کاملاً خودکار** روی سرور شخصی لینوکس (VPS) شما اجرا می‌شود و با دریافت اطلاعات کلودفلر و سرور مقصد از کاربر، تمامی مراحل را به صورت مستقیم و بدون نیاز به دخالت انسان انجام می‌دهد:

1. ثبت رکوردهای DNS در کلودفلر (`ns-soar` A, `soar` NS, `panel` A با پروکسی خاموش)
2. اتصال مستقیم امن SSH (پورت ۲۲) به سرور لینوکس مقصد
3. آزادسازی پورت ۵۳ و حل تداخل `systemd-resolved`
4. دانلود باینری رسمی WhiteDNS Soar Server (نسخه v0.14.0) و تایید هش SHA256
5. مقداردهی اولیه پایگاه‌داده SQLite و ساخت کاربر سیستمی `soar-panel`
6. فعال‌سازی سرویس‌های دائم `soar-panel.service` و `soar-panel-ops.service`
7. صدور گواهی SSL از Let's Encrypt و ساخت آدرس امن با پسوند یکتا و تصادفی
8. استخراج آدرس واقعی و اختصاصی پنل با دستور `soar-panel access-url` و تحویل به چت تلگرام

---

## ⚡ ۱. دستور نصب یک‌خطی (One-Line Installer)

برای نصب و فعال‌سازی کامل ربات روی سرور لینوکس، کافیست با دسترسی `root` دستور زیر را در ترمینال اجرا کنید:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/DarkPoesidon/whitedns-panel-installer-bot/main/deploy.sh)
```

یا همراه با پاس‌دادن مستقیم توکن ربات:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/DarkPoesidon/whitedns-panel-installer-bot/main/deploy.sh) YOUR_BOT_TOKEN
```

---

## 🔄 ۲. دستور به‌روزرسانی یک‌خطی (One-Line Updater)

جهت دریافت آخرین آپدیت‌ها از گیت‌هاب و راه‌اندازی مجدد خودکار سرویس ربات:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/DarkPoesidon/whitedns-panel-installer-bot/main/update.sh)
```
*(یا ارسال دستور `/update` مستقیماً داخل چت تلگرام ربات)*

---

## 🗑 ۳. دستور لغو نصب و حذف کامل یک‌خطی (One-Line Uninstaller)

برای متوقف‌سازی و حذف کامل ربات و سرویس پس‌زمینه آن از روی سرور لینوکس:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/DarkPoesidon/whitedns-panel-installer-bot/main/uninstall.sh)
```
*(یا ارسال دستور `/uninstall` درون چت تلگرام جهت حذف پنل تانل از سرور مقصد یا پاک‌سازی خود ربات)*

---

## 🛠 دستورات مدیریت سرویس ربات در سرور

* **مشاهده لاگ‌های زنده ربات:**
  ```bash
  journalctl -u whitedns-bot -f
  ```
* **بررسی وضعیت اجرای سرویس:**
  ```bash
  systemctl status whitedns-bot
  ```
* **ریستارت ربات:**
  ```bash
  systemctl restart whitedns-bot
  ```
* **توقف ربات:**
  ```bash
  systemctl stop whitedns-bot
  ```

---

## 📱 دستورات منوی تلگرام

• `/start` - شروع فرآیند نصب پنل و تانل WhiteDNS  
• `/status` - مشاهده سرورها، پنل‌های فعال و وضعیت  
• `/update` - بررسی و آپدیت خودکار ربات به آخرین نسخه گیت‌هاب  
• `/uninstall` - حذف کامل پنل از روی سرور یا راهنمای لغو نصب ربات  
• `/help` - راهنمای جامع و پیش‌نیازها  
• `/reset` - لغو عملیات جاری و ریست نشست  
