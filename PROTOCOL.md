# MTM 线协议 v1

Swift（`apple/MTMKit/Sources/Wire`）与 Kotlin（`android/app/src/main/java/app/mtm/Wire.kt`）都按本文实现，互通由 `vectors.json` 校验。

## 传输

- UDP，Mac 监听端口 **47800**，Bonjour 服务类型 **`_mtm._udp`**，TXT 记录 `id`（Mac 编号，32 位十六进制）。
- 手机也在 47800 端口接收 Mac 的信标（热点场景下 Mac 把信标发给默认网关，即手机）。
- 所有整数为大端序。坐标单位 0.01 mm，原点在触控面板左上角，x 向右、y 向下。

## 包头（12 字节，明文）

| 偏移 | 长度 | 字段 |
|---|---|---|
| 0 | 1 | magic `0x4D` |
| 1 | 1 | 版本 `1` |
| 2 | 1 | 消息类型 |
| 3 | 1 | 保留，填 0 |
| 4 | 4 | 会话编号 sid（未建立会话的消息填 0） |
| 8 | 4 | 序号 seq |

加密消息的包体为 `AES-128-GCM(明文包体)`，即密文加 16 字节认证标签；附加认证数据为 12 字节包头；随机数（nonce）为 `方向(u32) ‖ sid(u32) ‖ seq(u32)`，方向 0 表示手机发往 Mac，1 表示 Mac 发往手机。每个方向的 seq 从 1 开始严格递增，接收方丢弃不大于已接收最大值的包。

## 基本编码

- `id16`：16 字节设备编号（UUID）。
- `str`：1 字节长度加 UTF-8 字节，最长 255 字节。
- `key`：1 字节长度加 P-256 公钥的 X.509 SubjectPublicKeyInfo DER 编码（91 字节）。
- `n16`：16 字节随机数。

## 消息

| 类型 | 名称 | 方向 | 加密 | 包体 |
|---|---|---|---|---|
| 0x01 | BEACON | Mac → 网关 | 否 | `macId:id16 ‖ name:str` |
| 0x10 | PAIR_REQUEST | 手机 → Mac | 否 | `phoneId:id16 ‖ pubP:key ‖ name:str` |
| 0x11 | PAIR_COMMIT | Mac → 手机 | 否 | `macId:id16 ‖ pubM:key ‖ commit:32 字节 ‖ name:str` |
| 0x12 | PAIR_NONCE | 手机 → Mac | 否 | `phoneId:id16 ‖ nP:n16` |
| 0x13 | PAIR_REVEAL | Mac → 手机 | 否 | `nM:n16` |
| 0x14 | PAIR_DONE | Mac → 手机 | 否 | `accepted:u8 ‖ tag:16 字节` |
| 0x20 | HELLO | 手机 → Mac | 否 | `phoneId:id16 ‖ nP:n16 ‖ tag:16 字节` |
| 0x21 | HELLO_ACK | Mac → 手机 | 否 | `phoneId:id16 ‖ nP:n16 ‖ nM:n16 ‖ tag:16 字节`（包头 sid 为新会话编号） |
| 0x22 | HELLO_NAK | Mac → 手机 | 否 | `reason:u8`（1 = 未配对） |
| 0x30 | FRAME | 手机 → Mac | 是 | 见下 |
| 0x31 | HEARTBEAT | 双向 | 是 | `t:u64 ‖ echoT:u64 ‖ echoHold:u32` |
| 0x33 | FEEDBACK | Mac → 手机 | 是 | `kind:u8`（1 = 轻触感） |
| 0x3F | BYE | 双向 | 是 | `reason:u8`（0 = 正常，1 = 被其他设备接管） |

### FRAME 包体

```
t:u64            触摸事件时间，手机单调时钟，微秒
w:u16  h:u16     触控面板当前宽、高，0.01 mm
na:u8            当前触点数
  na × { id:u8  x:u16  y:u16 }
ne:u8            最近 150 ms 内抬起的触点数
  ne × { id:u8  x:u16  y:u16  downAgo:u16  upAgo:u16 }   // 按下、抬起时刻距 t 的毫秒数
```

触点编号由手机分配，每次按下加 1（8 位回绕），不复用系统的指针编号，保证 150 ms 窗口内不会重号。手机每收到一次触摸事件就发送一帧；抬起的触点在之后 150 ms 内的每一帧里重复出现，接收方按编号去重。

### HEARTBEAT

`t` 为发送方单调时钟（微秒）；`echoT` 为最近收到的对方心跳的 `t`，`echoHold` 为收到它到发出本心跳之间经过的微秒数。往返时延 = 本地当前时间 − `echoT` − `echoHold`。会话期间双方每 50 ms 发送一次，超过 1 秒未收到对方任何包即判定断线。

## 配对（数字比对加承诺值）

1. 手机生成临时 P-256 密钥对，发送 PAIR_REQUEST。
2. Mac 生成临时密钥对和 `nM`，计算 `commit = SHA256("mtm-commit" ‖ pubM ‖ pubP ‖ nM)`，回复 PAIR_COMMIT。
3. 手机生成 `nP`，发送 PAIR_NONCE。
4. Mac 回复 PAIR_REVEAL；手机校验 commit。
5. 双方计算：
   - `shared` = ECDH 共享秘密（32 字节 x 坐标）
   - `code` = `SHA256("mtm-code" ‖ pubP ‖ pubM ‖ nP ‖ nM)` 前 4 字节按大端 u32 取模 1 000 000，补足 6 位
   - `pairKey = HMAC-SHA256(key: shared, "mtm-pair" ‖ pubP ‖ pubM ‖ nP ‖ nM)`
6. 两端显示 `code`，由用户在 Mac 上确认。Mac 回复 PAIR_DONE，`tag = HMAC-SHA256(pairKey, "mtm-pair-done" ‖ accepted)` 前 16 字节。

手机在等待期间每秒重发 PAIR_NONCE，Mac 对同一配对幂等回复（用户确认前回复 PAIR_REVEAL，确认后回复 PAIR_DONE）。配对状态 120 秒后失效，同一时间只处理一个等待确认的配对。

## 建立会话

1. 手机发送 HELLO，`tag = HMAC-SHA256(pairKey, "mtm-hello" ‖ 包头 ‖ phoneId ‖ nP)` 前 16 字节。
2. Mac 校验后分配非零 `sid`，回复 HELLO_ACK，`tag = HMAC-SHA256(pairKey, "mtm-hello-ack" ‖ 包头 ‖ phoneId ‖ nP ‖ nM)` 前 16 字节。
3. 会话密钥 `key = HMAC-SHA256(pairKey, "mtm-session" ‖ nP ‖ nM ‖ sid)` 前 16 字节。
4. Mac 收到该会话第一个通过认证的加密包后才让它成为当前控制会话（防止重放旧 HELLO 抢占控制），旧会话收到 BYE(1)。
5. 会话不绑定地址：通过认证的包来自新地址时，Mac 把回复地址切换到新地址。
