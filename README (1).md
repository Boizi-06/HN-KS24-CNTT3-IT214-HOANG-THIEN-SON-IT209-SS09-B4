# Bài 4: Thiết lập Custom Network & Named Volume bằng Docker CLI

## 1. Mục tiêu

- Tạo Custom Bridge Network tên `app-net`.
- Tạo Named Volume tên `db-data`.
- Chạy PostgreSQL 15 Alpine trong container `db-server`, kết nối vào `app-net`.
- Mount `db-data` vào `/var/lib/postgresql/data`.
- Chạy Backend API trong container `app-container`, kết nối PostgreSQL bằng hostname `db-server`.
- Xác minh DNS nội bộ và chứng minh dữ liệu vẫn còn sau khi xóa, tạo lại container database.

## 2. Thành phần sử dụng

| Thành phần | Giá trị |
|---|---|
| Docker network | `app-net` |
| Named volume | `db-data` |
| Database container | `db-server` |
| Backend container | `app-container` |
| Database image | `postgres:15-alpine` |
| Backend API image | `session10-ex4-backend:local` |
| API URL | `http://localhost:8090` |
| DB hostname từ Backend | `db-server` |
| Database | `appdb` |

Backend API là ứng dụng Python/Flask nhỏ được tạo và build tự động bởi `commands.sh`. Script tạo source tạm, build image, sau đó dọn source tạm. Không cần Docker Compose.

> Tài khoản và mật khẩu trong script chỉ phục vụ bài thực hành local, không dùng trong môi trường production.

## 3. Cách chạy trên macOS

Đảm bảo Docker Desktop đang chạy. Mở Terminal tại thư mục bài tập rồi cấp quyền thực thi cho script:

```bash
chmod +x commands.sh
```

Chạy script:

```bash
./commands.sh
```

Script sẽ:
1. Tạo `app-net` và `db-data` nếu chúng chưa tồn tại.
2. Build Backend API.
3. Khởi chạy PostgreSQL với named volume `db-data`.
4. Tạo bảng `persistence_items` và chèn dòng kiểm tra `persistence-check` nếu chưa có.
5. Khởi chạy Backend API với `DB_HOST=db-server`.
6. Kiểm tra network, volume, DNS, API và dữ liệu.
7. Xóa riêng container `db-server`, tạo lại container database với cùng volume rồi xác minh dữ liệu còn nguyên.

Script không xóa volume `db-data`, vì volume cần được giữ lại để chứng minh tính bền vững dữ liệu.

## 4. Các lệnh kiểm tra thủ công

### 4.1. Kiểm tra Network và Volume

```bash
docker network ls | grep app-net
docker volume ls | grep db-data
docker network inspect app-net
```

### 4.2. Kiểm tra DNS từ Backend tới Database

```bash
docker exec app-container ping -c 2 db-server
```

Kết quả mong đợi: `db-server` được phân giải thành địa chỉ IP nội bộ trong network Docker và nhận được phản hồi ping. Nếu image/container không có `ping`, script đã cài `iputils` vào image Backend.

### 4.3. Kiểm tra API kết nối database

```bash
curl -i http://localhost:8090/health
curl http://localhost:8090/items
```

Kết quả mong đợi của `/health` là HTTP `200 OK` và JSON có `status: "ok"` cùng `database_host: "db-server"`.

### 4.4. Thử thêm dữ liệu qua Backend API

```bash
curl -i -X POST http://localhost:8090/items \
  -H 'Content-Type: application/json' \
  -d '{"name":"my-persistence-test"}'
```

Xem lại danh sách:

```bash
curl http://localhost:8090/items
```

### 4.5. Kiểm tra Data Persistence

Script tự động thực hiện các thao tác sau:

```bash
docker rm -f db-server
```

Sau đó tạo lại `db-server` với cùng network và volume:

```bash
docker run -d \
  --name db-server \
  --network app-net \
  --network-alias db-server \
  -e POSTGRES_DB=appdb \
  -e POSTGRES_USER=appuser \
  -e POSTGRES_PASSWORD=appdemo123 \
  -v db-data:/var/lib/postgresql/data \
  postgres:15-alpine
```

Kiểm tra dữ liệu sau khi PostgreSQL khởi động lại:

```bash
docker exec db-server psql -U appuser -d appdb \
  -c "SELECT id, name FROM persistence_items ORDER BY id;"
```

Dòng `persistence-check` và các dòng đã thêm phải vẫn còn. Không xóa volume `db-data` trong quá trình kiểm thử.

## 5. Minh chứng thực hành

Sau khi chạy script thành công, chụp ảnh Terminal thật và lưu vào thư mục `screenshots/` với các tên sau.

### Ảnh 1 — Network và Volume

Chụp kết quả `docker network ls`, `docker volume ls` hoặc `docker network inspect app-net`.

![Minh chứng Network và Volume](screenshots/01-network-volume.png)

### Ảnh 2 — DNS và Backend API

Chụp kết quả `ping -c 2 db-server` từ `app-container` và lệnh `curl http://localhost:8090/health`.

![Minh chứng DNS và API](screenshots/02-dns-api.png)

### Ảnh 3 — Data Persistence

Chụp kết quả sau khi container DB được tạo lại, lệnh `SELECT` vẫn trả về dữ liệu và API `/items` vẫn đọc được dữ liệu.

![Minh chứng Data Persistence](screenshots/03-data-persistence.png)

> Ảnh minh chứng phải là ảnh chụp kết quả thực tế trên máy của bạn. Nếu chưa tạo ảnh, các đường dẫn ảnh trong README sẽ chưa hiển thị trên GitHub.

## 6. Dọn dẹp sau khi hoàn thành

Để xóa hai container demo:

```bash
docker rm -f app-container db-server
```

Có thể xóa network nếu không còn container nào sử dụng:

```bash
docker network rm app-net
```

**Không xóa volume `db-data`** nếu muốn giữ dữ liệu để kiểm tra lại. Chỉ khi chắc chắn không cần dữ liệu nữa mới chạy:

```bash
docker volume rm db-data
```

## 7. Cấu trúc thư mục nộp bài

```text
homework/
└── session_10/
    └── ex4/
        ├── commands.sh
        ├── README.md
        └── screenshots/
            ├── 01-network-volume.png
            ├── 02-dns-api.png
            └── 03-data-persistence.png
```

## 8. Kết luận

Bài thực hành minh họa cách dùng Docker CLI để tạo custom bridge network, phân giải DNS giữa các container bằng tên `db-server`, gắn named volume cho PostgreSQL và kiểm chứng dữ liệu vẫn tồn tại sau khi xóa rồi tạo lại container database.
