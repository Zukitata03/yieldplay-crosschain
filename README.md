# YieldPlay - Giao thức Xổ số Không Mất Vốn

YieldPlay là một giao thức xổ số phi tập trung **không mất vốn**, nơi người dùng gửi tài sản vào các Round có thời hạn. Toàn bộ số tiền gửi được đưa vào các ERC4626 Vault (Aave, Compound, Yearn, v.v.) để tạo **yield**. Yield thu được sẽ tạo thành quỹ giải thưởng phân phối cho người thắng, trong khi **tất cả người gửi đều nhận lại đầy đủ số vốn gốc**.

## Mục lục

- [Tổng quan](#tổng-quan)
- [Deployed Contracts](#deployed-contracts)
- [Kiến trúc](#kiến-trúc)
- [Cấu trúc Contract](#cấu-trúc-contract)
- [Vòng đời Round](#vòng-đời-round)
- [Cấu trúc Phí](#cấu-trúc-phí)
- [Hướng dẫn Sử dụng](#hướng-dẫn-sử-dụng)
- [SDK](#sdk)
- [Triển khai](#triển-khai)
- [Bảo mật](#bảo-mật)
- [Tham chiếu API](#tham-chiếu-api)

---

## Tổng quan

### Cách hoạt động

1. **Protocol Owner** cấu hình vault ERC4626 cho mỗi payment token
2. **Game Owner** tạo một Game với các tham số cấu hình (dev fee, treasury)
3. **Game Owner** tạo các Round với thời gian bắt đầu/kết thúc, deposit fee, payment token
4. **User** gửi token vào Round trong giai đoạn InProgress
5. **Game Owner** đưa tiền từ Round vào Vault trong giai đoạn Locking để tạo yield
6. Sau giai đoạn khóa, **Game Owner** rút tiền và yield về lại contract
7. **Game Owner** thực hiện settlement (tính phí, lưu prize pool) và chọn Winner
8. **User** ở trạng thái thắng có thể claim vốn gốc + tiền thưởng; các user còn lại claim vốn gốc

### Tính năng chính

- 🔒 **No-Loss**: Tất cả depositor đều nhận lại principal (vốn gốc)
- 🎲 **Phân phối giải thưởng linh hoạt**: Game Owner tự quyết định logic chia prize pool
- 💰 **Tích hợp ERC4626**: Hỗ trợ bất kỳ vault ERC4626 compliant (Aave, Yearn, Compound, v.v.)
- 🛡️ **Bảo mật theo best-practice**: ReentrancyGuard, Pausable, SafeERC20, Access Control rõ ràng
- ⛽ **Tối ưu gas**: Dùng custom errors, cấu trúc storage hợp lý
- 📦 **SDK TypeScript**: Tích hợp dễ dàng với backend

---

## Deployed Contracts

### Sepolia Testnet

| Contract | Address |
|----------|---------|
| **YieldPlay** | `0x02AA158dc37f4E1128CeE3E69e9E59920E799F90` |
| Vault (ERC4626) | `0xf323aEa80bF9962e26A3499a4Ffd70205590F54d` |
| Token | `0xdd13E55209Fd76AfE204dBda4007C227904f0a81` |

**Etherscan**: https://sepolia.etherscan.io/address/0x02AA158dc37f4E1128CeE3E69e9E59920E799F90

---

## Kiến trúc

```
┌─────────────────────────────────────────────────────────────────┐
│                         YieldPlay.sol                           │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐  │
│  │   Games     │  │   Rounds    │  │    User Deposits        │  │
│  │ mapping     │  │  mapping    │  │      mapping            │  │
│  └─────────────┘  └─────────────┘  └─────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                     ERC4626 Vaults                              │
│  ┌─────────────────────┐  ┌─────────────────────────────────┐   │
│  │   Aave aTokens      │  │     Yearn Vaults                │   │
│  │   Compound cTokens  │  │     Euler Vaults                │   │
│  └─────────────────────┘  └─────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

---

## Cấu trúc Contract

```
contracts/
├── YieldPlay.sol                 # Contract giao thức chính
├── interfaces/
│   └── IYieldStrategy.sol        # Interface tùy chỉnh (không sử dụng)
├── libraries/
│   ├── DataTypes.sol             # Structs và enums
│   └── Errors.sol                # Custom errors
sdk/
├── sdk.ts                        # TypeScript SDK
├── example.ts                    # Ví dụ sử dụng
├── index.ts                      # Export module
└── README.md                     # Tài liệu SDK
```

---

## Vòng đời Round

```
┌──────────────┐    ┌──────────────┐    ┌──────────────┐    ┌───────────────────┐    ┌──────────────────────┐
│  NotStarted  │───►│  InProgress  │───►│   Locking    │───►│  ChoosingWinners  │───►│  DistributingRewards │
│              │    │              │    │              │    │                   │    │                      │
│  Round       │    │  User gửi    │    │  Tài sản     │    │  Đã rút tài sản   │    │  User claim          │
│  được tạo    │    │  deposit     │    │  trong Vault │    │  + yield về       │    │  principal + reward  │
└──────────────┘    └──────────────┘    └──────────────┘    └───────────────────┘    └──────────────────────┘
     │                    │                   │                      │                        │
     │                    │                   │                      │                        │
    now < startTs    startTs ≤ now ≤ endTs   endTs < now ≤         now > endTs +           Sau khi chooseWinner
                                             endTs + lockTime       lockTime               hoặc finalizeRound
```

### Chuyển đổi trạng thái Round

| Trạng thái | Mô tả | Hành động chính |
|-----------|-------|-----------------|
| `NotStarted` | Round đã tồn tại nhưng chưa bắt đầu | - |
| `InProgress` | Mở cho user deposit | `deposit()` |
| `Locking` | Đóng deposit, deploy sang Vault | `depositToVault()` |
| `ChoosingWinners` | Đã rút tài sản từ Vault, tính toán yield và chọn Winner | `withdrawFromVault()`, `settlement()`, `chooseWinner()` |
| `DistributingRewards` | Mở cho user claim principal + reward | `claim()` |

---

## Cấu trúc Phí

### Tổng quan

YieldPlay có 3 loại phí:

| Loại phí | Tỷ lệ | Người nhận | Thời điểm |
|----------|-------|------------|-----------|
| **Performance Fee** | 20% cố định | Protocol Treasury | Settlement |
| **Developer Fee** | 0-100% (tùy chọn) | Game Treasury | Settlement |
| **Deposit Fee** | 0-10% (tùy chọn) | Bonus Prize Pool | Deposit |

### Công thức tính

```
Tổng Yield từ Vault
    │
    ├── 20% ──► Protocol Treasury (Performance Fee - cố định)
    │
    └── 80% ──► Net Yield
                    │
                    ├── X% ──► Game Treasury (Dev Fee - cài đặt khi tạo Game)
                    │
                    └── Phần còn lại ──► Yield Prize Pool
                    
Deposit Fee (khi user deposit) ──► Bonus Prize Pool

Total Prize Pool = Yield Prize Pool + Bonus Prize Pool
```

### Ví dụ tính toán

**Cài đặt:**
- Performance Fee: 20% (cố định)
- Developer Fee: 5% (`devFeeBps = 500`)
- Deposit Fee: 1% (`depositFeeBps = 100`)
- Total Deposits: 10,000 USDC
- Yield từ vault: 500 USDC

**Tính toán:**

```
1. Deposit Phase:
   - User deposits: 10,000 USDC
   - Deposit Fee (1%): 100 USDC → Bonus Prize Pool
   - Net Deposits: 9,900 USDC

2. Settlement Phase:
   - Yield từ vault: 500 USDC
   - Performance Fee (20%): 100 USDC → Protocol Treasury
   - Yield sau performance: 400 USDC
   - Developer Fee (5%): 20 USDC → Game Treasury
   - Yield Prize: 380 USDC

3. Total Prize Pool:
   - Yield Prize: 380 USDC
   - Bonus Prize Pool: 100 USDC
   - Total: 480 USDC cho winners

4. Users nhận về:
   - Principal: 9,900 USDC (chia theo deposit)
   - Prize: 480 USDC (chia cho winners)
```

### Basis Points (BPS)

```
1 bps = 0.01%
100 bps = 1%
1000 bps = 10%
10000 bps = 100%
```

---

## Hướng dẫn Sử dụng

### Dành cho Protocol Owner

#### Cấu hình Vault cho Payment Token

```solidity
// Chỉ Protocol Owner mới có quyền
yieldPlay.setVault(
    usdcAddress,    // ERC20 token address
    vaultAddress    // ERC4626 vault address
);
```

### Dành cho Game Owner

#### 1. Tạo Game

```solidity
bytes32 gameId = yieldPlay.createGame(
    "MyLottery",           // gameName (unique với mỗi owner)
    500,                   // devFeeBps (5% = 500)
    treasuryAddress        // địa chỉ treasury nhận dev fee
);
```

#### 2. Tạo Round

```solidity
uint256 roundId = yieldPlay.createRound(
    gameId,
    uint64(block.timestamp),             // startTs - bắt đầu ngay
    uint64(block.timestamp + 1 days),    // endTs - đóng deposit sau 1 ngày
    uint64(7 days),                      // lockTime - khóa 7 ngày
    100,                                 // depositFeeBps - 1% deposit fee
    usdcAddress                          // paymentToken
);
```

#### 3. Quản lý vòng đời Round

```solidity
// Sau khi đóng deposit, deploy funds sang Vault
yieldPlay.depositToVault(gameId, roundId);

// Sau giai đoạn khóa, rút tài sản + yield từ Vault về contract
yieldPlay.withdrawFromVault(gameId, roundId);

// Settlement: tính toán phí, cập nhật prizePool
yieldPlay.settlement(gameId, roundId);

// Chọn Winner và phân bổ prizePool cho từng Winner
yieldPlay.chooseWinner(gameId, roundId, winnerAddress, prizeAmount);

// Hoặc kết thúc Round (tiền thưởng còn lại về treasury)
yieldPlay.finalizeRound(gameId, roundId);
```

### Dành cho User

#### Gửi tiền (deposit)

```solidity
// Approve trước cho YieldPlay
usdc.approve(yieldPlayAddress, amount);

// Gửi tiền
yieldPlay.deposit(gameId, roundId, amount);
```

#### Nhận tiền (claim)

```solidity
// Sau khi round ở trạng thái DistributingRewards
yieldPlay.claim(gameId, roundId);
```

### Hàm xem thông tin

```solidity
// Lấy thông tin game
Game memory game = yieldPlay.getGame(gameId);

// Lấy thông tin round
Round memory round = yieldPlay.getRound(gameId, roundId);

// Lấy thông tin gửi tiền của user
UserDeposit memory deposit = yieldPlay.getUserDeposit(gameId, roundId, userAddress);

// Lấy trạng thái hiện tại
RoundStatus status = yieldPlay.getCurrentStatus(gameId, roundId);

// Tính game ID
bytes32 gameId = yieldPlay.calculateGameId(ownerAddress, "gameName");
```

---

## SDK

YieldPlay cung cấp TypeScript SDK để tích hợp dễ dàng với backend.

### Cài đặt

```bash
npm install ethers
```

### Sử dụng cơ bản

```typescript
import { ethers } from "ethers";
import { YieldPlaySDK } from "./sdk/sdk";

// Khởi tạo
const provider = new ethers.JsonRpcProvider("https://ethereum-sepolia-rpc.publicnode.com");
const signer = new ethers.Wallet(PRIVATE_KEY, provider);

const sdk = new YieldPlaySDK({
  yieldPlayAddress: "0x02AA158dc37f4E1128CeE3E69e9E59920E799F90",
  signer,
});

// Tạo game
const gameResult = await sdk.createGame({
  gameName: "My Game",
  devFeeBps: 500,
  treasury: ownerAddress,
});

// Tạo round
const roundResult = await sdk.createRound({
  gameId: gameResult.gameId,
  startTs: Math.floor(Date.now() / 1000),
  endTs: Math.floor(Date.now() / 1000) + 86400,
  lockTime: 604800,
  depositFeeBps: 100,
  paymentToken: tokenAddress,
});

// User deposit (tự động approve)
await sdk.deposit({
  gameId: gameResult.gameId,
  roundId: roundResult.roundId,
  amount: ethers.parseUnits("100", 18),
});

// User claim
await sdk.claim({
  gameId: gameResult.gameId,
  roundId: roundResult.roundId,
});
```

### Chạy Example

```bash
npx ts-node sdk/example.ts
```

**Xem tài liệu SDK đầy đủ tại [sdk/README.md](sdk/README.md)**

---

## Triển khai

### Yêu cầu

```bash
npm install
cp .env.example .env
# Chỉnh sửa .env với private key và RPC URLs của bạn
```

### Phát triển local

```bash
# Chạy tests với Avalanche fork
npm run test
```

### Triển khai testnet

```bash
# Sepolia
npx hardhat run scripts/deploySepolia.ts --network sepolia

# Base Sepolia  
npx hardhat run scripts/deployTestnet.ts --network baseSepolia
```

### Xác minh contract

```bash
npx hardhat verify --network sepolia 0x02AA158dc37f4E1128CeE3E69e9E59920E799F90 0x7C8dc5A5D0B5F067100414EbB19f9Fe07dF999Eb
```

---

## Bảo mật

### Tính năng bảo mật

| Tính năng | Mô tả |
|-----------|-------|
| **ReentrancyGuard** | Bảo vệ chống reentrancy cho các hàm external quan trọng |
| **SafeERC20** | Thao tác ERC20 an toàn, hỗ trợ cả token không chuẩn |
| **Pausable** | Cho phép pause/unpause toàn bộ giao thức khi khẩn cấp |
| **Custom Errors** | Giảm gas so với require string, thông báo lỗi rõ ràng |
| **CEI Pattern** | Tuân thủ thứ tự Checks → Effects → Interactions |
| **Access Control** | Tách bạch vai trò Protocol Owner và Game Owner |

### Ma trận quyền truy cập

| Hàm | Protocol Owner | Game Owner | User |
|-----|--------------|----------|------------|
| `pause/unpause` | ✅ | ❌ | ❌ |
| `setVault` | ✅ | ❌ | ❌ |
| `setProtocolTreasury` | ✅ | ❌ | ❌ |
| `createGame` | ✅ | ✅ | ✅ |
| `createRound` | ❌ | ✅ | ❌ |
| `depositToVault` | ❌ | ✅ | ❌ |
| `withdrawFromVault` | ❌ | ✅ | ❌ |
| `settlement` | ❌ | ✅ | ❌ |
| `chooseWinner` | ❌ | ✅ | ❌ |
| `finalizeRound` | ❌ | ✅ | ❌ |
| `deposit` | ❌ | ❌ | ✅ |
| `claim` | ❌ | ❌ | ✅ |

---

## Tham chiếu API

### Events

```solidity
event GameCreated(bytes32 indexed gameId, address indexed owner, string gameName, uint16 devFeeBps);
event RoundCreated(bytes32 indexed gameId, uint256 indexed roundId, uint64 startTs, uint64 endTs, uint64 lockTime, uint16 depositFeeBps, address paymentToken, address vault);
event Deposited(bytes32 indexed gameId, uint256 indexed roundId, address indexed user, uint256 amount, uint256 depositFee);
event FundsDeployed(bytes32 indexed gameId, uint256 indexed roundId, uint256 amount, uint256 shares);
event FundsWithdrawn(bytes32 indexed gameId, uint256 indexed roundId, uint256 principal, uint256 yield);
event RoundSettled(bytes32 indexed gameId, uint256 indexed roundId, uint256 totalYield, uint256 performanceFee, uint256 devFee, uint256 prizePool);
event WinnerChosen(bytes32 indexed gameId, uint256 indexed roundId, address indexed winner, uint256 amount);
event Claimed(bytes32 indexed gameId, uint256 indexed roundId, address indexed user, uint256 principal, uint256 prize);
event VaultUpdated(address indexed token, address indexed vault);
event ProtocolTreasuryUpdated(address indexed newTreasury);
```

### Errors

```solidity
error InvalidDevFeeBps();          // devFeeBps > 10000
error InvalidPaymentToken();       // paymentToken không hợp lệ hoặc vault asset không khớp
error InvalidRoundTime();          // endTs <= startTs
error Unauthorized();              // Caller không có quyền thực hiện hành động
error RoundNotActive();            // Round không ở trạng thái cho phép hành động
error NoDepositsFound();           // User không có deposit trong Round
error RoundNotCompleted();         // Round chưa ở trạng thái DistributingRewards
error AlreadyClaimed();            // User đã claim trước đó
error InvalidAmount();             // amount = 0 hoặc không hợp lệ
error RoundNotEnded();             // Round chưa kết thúc (chưa tới ChoosingWinners)
error RoundAlreadySettled();       // Round đã settlement trước đó
error RoundNotSettled();           // Round chưa settlement
error GameAlreadyExists();         // Game đã tồn tại với gameId này
error GameNotFound();              // Không tìm thấy Game tương ứng
error RoundNotFound();             // Không tìm thấy Round tương ứng
error FundsAlreadyWithdrawn();     // Đã withdraw funds từ vault
error FundsNotDeployed();          // Funds chưa được deploy sang Vault
error FundsNotWithdrawn();         // Chưa withdraw từ vault
error StrategyNotSet();            // Chưa cấu hình Vault cho paymentToken này
error ZeroAddress();               // Tham số address là address(0)
error InsufficientPrizePool();     // prizePool không đủ cho amount yêu cầu
```

---

## Kiểm thử

```bash
# Chạy tất cả tests (với Avalanche mainnet fork)
npm run test

# Chạy với báo cáo gas
npm run test:gas

# Chạy với coverage
npm run test:coverage
```

### Phạm vi test

- ✅ Tạo Game và validate tham số
- ✅ Tạo Round và kiểm tra chuyển trạng thái
- ✅ Deposit trong giai đoạn InProgress với deposit fee
- ✅ Toàn bộ vòng đời Round end-to-end
- ✅ Nhiều Winner trong cùng một Round
- ✅ Kiểm soát quyền truy cập cho Game Owner / Protocol Owner
- ✅ Hành vi các hàm admin
- ✅ Các hàm view
- ✅ Integration test với real ERC4626 vault (Euler)

---

## Giấy phép

MIT
