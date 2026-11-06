# 🛡️ Báo Cáo Phân Tích: Thiết Kế Cơ Chế Xác Thực 3 Lớp (MFA & TOTP) Cho Crypto Wallet

---

## 📌 Thông Tin Bài Nộp
* **Họ và tên:** Lê Hồ Thanh Thảo
* **Mã lớp / MSSV:** N26DTCN030
* **Môn học:** IT108-K26 - Nhập Môn Công Nghệ Thông Tin

---

## 1. Thiết Kế Kiến Trúc Bảo Vệ 3 Lớp (Multi-Factor Authentication - MFA)

### 1.1. Mô tả 3 Lớp Bảo Vệ (3 Security Layers)
Ứng dụng Ví tiền điện tử (Crypto Wallet) áp dụng mô hình 3 lớp xác thực độc lập để bảo vệ tối đa tài sản kỹ thuật số:

1. **Lớp 1 - Yếu tố Mật khẩu & Sinh trắc học (Something You Know / Are):**
   * Mật khẩu ứng dụng (Master PIN / Password) hoặc Xác thực vân tay/Khuôn mặt (Biometrics - TouchID / FaceID) để mở khóa giao diện ví cục bộ.
2. **Lớp 2 - Yếu tố Thiết bị & Khóa mật mã (Something You Have / Hold):**
   * Khóa tư nhân (**Private Key**) hoặc Cụm từ khôi phục (**Seed Phrase / 12-24 Mnemonic Words**) mã hóa được lưu an toàn trong chip bảo mật (**Secure Enclave / TEE**) của thiết bị hoặc Hardware Wallet (Ledger/Trezor).
3. **Lớp 3 - Yếu tố Động TOTP (Time-based One-Time Password):**
   * Mã xác thực 6 chữ số biến đổi liên tục mỗi 30 giây được sinh ra từ thuật toán **TOTP (RFC 6238)** thông qua ứng dụng Authenticator (Google Authenticator, Bitwarden Authenticator) hoặc Hardware Security Key (YubiKey).

---

### 1.2. Sơ Đồ Luồng Dữ Liệu (Data Flow Diagram)
[Người dùng / Hacker]
│
▼
┌───────────┐     Mật khẩu sai
│  Lớp 1    ├────────────────────► [TỪ CHỐI TRUY CẬP]
│ Password  │
└─────┬─────┘
│ Mật khẩu đúng (Hoặc Hacker trộm được Pass)
▼
┌───────────┐     Private Key sai / Không giữ thiết bị
│  Lớp 2    ├────────────────────► [TỪ CHỐI TRUY CẬP]
│Private Key│
└─────┬─────┘
│ Chữ ký số hợp lệ từ Secure Enclave
▼
┌───────────┐     Mã TOTP sai hoặc Hết hạn (>30s)
│  Lớp 3    ├────────────────────► [HUỶ GIAO DỊCH]
│ Mã TOTP   │
└─────┬─────┘
│ Mã TOTP khớp theo thời gian thực
▼
[XÁC THỰC THÀNH CÔNG & KÝ GIAO DỊCH LÊN BLOCKCHAIN]

---

### 1.3. Cơ Chế Chống Tấn Công Khi Hacker Có Mật Khẩu (Password Breach Scenario)

Dù hacker trộm được **Mật khẩu Lớp 1** (qua hình thức Keylogger, Credential Stuffing hoặc lộ từ diễn đàn khác), hệ thống vẫn chặn đứng tấn công nhờ 2 lớp rào cản phía sau:

* **Tại Lớp 2:** Hacker từ xa **không thể lấy được Private Key** vì Private Key không lưu dưới dạng text trên máy chủ mà được mã hóa độc lập trong phần cứng thiết bị của người dùng.
* **Tại Lớp 3:** Ngay cả khi hacker tạo lệnh chuyển tiền, hệ thống yêu cầu mã **TOTP 6 chữ số**. Mã này được sinh ra từ thiết bị di động vật lý của người dùng. Hacker không thể đoán hoặc bẻ khóa được mã này từ xa vì nó tự thay đổi sau mỗi 30 giây.

---

## 2. Phân Tích Kỹ Thuật Xử Lý Bẫy (Edge Case): Xác Thực Khi Không Có Internet / Sóng Điện Thoại

### 2.1. Đặt Tình Huống
Người dùng đang di chuyển trên máy bay, điện thoại bật **Chế độ máy bay (Airplane Mode)** – hoàn toàn không có kết nối Wi-Fi, 4G/5G hay sóng viễn thông SMS. Làm sao họ vẫn có thể lấy được mã OTP để xác thực giao dịch?

---

### 2.2. Giải Thích Bản Chất Kỹ Thuật Của Thuật Toán TOTP (RFC 6238)

Mã OTP **hoàn toàn có thể tạo thành công** offline nhờ cơ chế vận hành độc lập mạng của thuật toán **TOTP (Time-based One-Time Password)**:

#### A. Công thức tính toán mã TOTP
Thuật toán TOTP tính toán mã 6 chữ số dựa trên 2 tham số đầu vào duy nhất:
1. **Khóa bí mật dùng chung ($K$ - Shared Secret Key):** Được trao đổi duy nhất một lần giữa Ví và App Authenticator lúc quét mã QR ban đầu, lưu trữ bảo mật trong bộ nhớ cục bộ thiết bị.
2. **Khoảng thời gian ($T$ - Time Counter):** Được tính dựa trên Đồng hồ thời gian thực (**RTC - Real-Time Clock**) phần cứng của điện thoại theo công thức:

$$T = \left\lfloor \frac{T_{current} - T_0}{X} \right\rfloor$$

* Trong đó:
  * $T_{current}$: Thời gian Unix epoch hiện tại (tính bằng giây).
  * $T_0$: Thời điểm mốc ($0$ - ngày 1/1/1970).
  * $X$: Khoảng thời gian làm mới mã (thông thường $X = 30\text{ giây}$).

Sau đó, mã OTP được tạo ra bằng hàm băm mã hóa HMAC:

$$\text{TOTP} = \text{Truncate}(\text{HMAC-SHA1}(K, T)) \bmod 10^6$$

#### B. Tại sao KHÔNG cần Internet/Sóng điện thoại?
* **Tính toán hoàn toàn cục bộ (Client-side Execution):** Việc nhân $K$ và $T$ qua hàm HMAC diễn ra trực tiếp trên chip xử lý của điện thoại mà không cần bất kỳ gói tin mạng nào gửi ra ngoài.
* **Đồng bộ dựa trên Thời gian thực (Time Synchronization):** Đồng hồ nội vi của điện thoại di động vẫn tiếp tục chạy chính xác nhờ pin/thạch anh RTC phần cứng ngay cả khi tắt toàn bộ kết nối không dây.
* **Xác thực khớp kép phía Ví (Offline/Online Syncing):**
  * Khi giao dịch được gửi đi (khi máy bay có Wi-Fi nội bộ hoặc sau khi kết nối lại mạng), máy chủ Ví tính toán lại công thức TOTP với cùng tham số $K$ và $T$ tại thời điểm đó. Nếu hai kết quả trùng khớp, giao dịch được phê duyệt.

---

### 2.3. Các Giải Pháp Bổ Sung Khi Xác Thực Offline

1. **Mã khôi phục dự phòng (Offline Backup Codes):** Bộ 8-10 mã số sử dụng 1 lần được in/lưu an toàn từ trước.
2. **Khóa bảo mật phần cứng (Hardware Security Keys - YubiKey NFC/USB-C):** Cắm trực tiếp vào điện thoại hoặc quét NFC để tạo chữ số xác thực mã hóa asymmetric mà không cần mạng.

---

## 3. Kết Luận & Khuyến Nghị Bảo Mật Ví Crypto

1. **Tuyệt đối không dùng SMS OTP cho Crypto Wallet:** SMS OTP dễ bị tấn công SIM Swapping và bắt buộc phải có sóng viễn thông (không hoạt động trên máy bay).
2. **Ưu tiên Ứng dụng TOTP & Hardware Wallet:** Sử dụng Google Authenticator/Bitwarden Authenticator kết hợp Ví phần cứng để đảm bảo tính an toàn và khả năng hoạt động mọi lúc, mọi nơi.
