# YieldPlay SDK Documentation

## Giới thiệu

YieldPlay SDK cung cấp interface đơn giản để tương tác với smart contract YieldPlay - một giao thức no-loss prize game, nơi tiền gửi của người dùng sinh lợi nhuận và được phân phối cho người chiến thắng.

## Cài đặt

```bash
npm install ethers
```

## Cấu hình

### Khởi tạo SDK

```typescript
import { ethers } from "ethers";
import { YieldPlaySDK } from "./sdk/sdk";

// Khởi tạo provider và signer
const provider = new ethers.JsonRpcProvider("https://ethereum-sepolia-rpc.publicnode.com");
const signer = new ethers.Wallet(PRIVATE_KEY, provider);

// Khởi tạo SDK
const sdk = new YieldPlaySDK({
  yieldPlayAddress: "0x02AA158dc37f4E1128CeE3E69e9E59920E799F90", // Sepolia
  signer: signer,
});
```

### Contract Addresses (Sepolia Testnet)

| Contract | Address |
|----------|---------|
| YieldPlay | `0x02AA158dc37f4E1128CeE3E69e9E59920E799F90` |
| Vault | `0xf323aEa80bF9962e26A3499a4Ffd70205590F54d` |
| Token | `0xdd13E55209Fd76AfE204dBda4007C227904f0a81` |

---

## Types

### SDKConfig

```typescript
interface SDKConfig {
  yieldPlayAddress: string;  // Địa chỉ contract YieldPlay
  signer: Signer;            // Ethers signer để ký giao dịch
  provider?: Provider;       // Provider (mặc định dùng provider của signer)
}
```

### RoundStatus

```typescript
enum RoundStatus {
  NotStarted = 0,        // Round chưa bắt đầu
  InProgress = 1,        // Đang nhận deposit
  Locking = 2,           // Đang khóa, không nhận deposit
  ChoosingWinners = 3,   // Game owner chọn người thắng
  DistributingRewards = 4 // Người dùng có thể claim
}
```

### GameInfo

```typescript
interface GameInfo {
  owner: string;         // Địa chỉ owner của game
  gameName: string;      // Tên game
  devFeeBps: bigint;     // Phí developer (basis points)
  treasury: string;      // Địa chỉ nhận phí developer
  roundCounter: bigint;  // Số round đã tạo
  initialized: boolean;  // Game đã được khởi tạo
}
```

### RoundInfo

```typescript
interface RoundInfo {
  gameId: string;         // ID của game
  roundId: bigint;        // ID của round
  totalDeposit: bigint;   // Tổng tiền gửi
  bonusPrizePool: bigint; // Pool tiền thưởng từ deposit fee
  devFee: bigint;         // Phí developer
  totalWin: bigint;       // Tổng tiền thưởng còn lại
  yieldAmount: bigint;    // Lợi nhuận từ vault
  paymentToken: string;   // Token được chấp nhận
  vault: string;          // Địa chỉ vault
  depositFeeBps: bigint;  // Phí deposit (basis points)
  startTs: bigint;        // Thời gian bắt đầu
  endTs: bigint;          // Thời gian kết thúc nhận deposit
  lockTime: bigint;       // Thời gian khóa
  initialized: boolean;   // Round đã khởi tạo
  isSettled: boolean;     // Đã settlement
  status: bigint;         // Trạng thái hiện tại
  isWithdrawn: boolean;   // Đã rút từ vault
}
```

### UserDepositInfo

```typescript
interface UserDepositInfo {
  depositAmount: bigint;   // Số tiền đã gửi
  amountToClaim: bigint;   // Tiền thưởng được nhận
  isClaimed: boolean;      // Đã claim chưa
  exists: boolean;         // Có deposit trong round này
}
```

### TransactionResult

```typescript
interface TransactionResult {
  hash: string;                    // Transaction hash
  receipt: TransactionReceipt | null; // Receipt sau khi confirm
}
```

---

## API Reference

### User Actions (Người dùng)

#### `deposit(params)`

Gửi token vào một round. SDK tự động approve token nếu cần.

```typescript
interface DepositParams {
  gameId: string;           // Game ID (bytes32)
  roundId: bigint | number; // Round ID
  amount: bigint | string;  // Số lượng token
}

// Ví dụ
const result = await sdk.deposit({
  gameId: "0xa1db8e50e38f11de7e376c05d6956181b6e27b26173dfcdb49aaffdf951815cd",
  roundId: 0,
  amount: ethers.parseUnits("100", 18), // 100 tokens
});

console.log("Tx hash:", result.hash);
```

#### `claim(params)`

Claim principal và tiền thưởng (nếu có) sau khi round kết thúc.

```typescript
interface ClaimParams {
  gameId: string;
  roundId: bigint | number;
}

// Ví dụ
const result = await sdk.claim({
  gameId: "0x...",
  roundId: 0,
});
```

---

### Game Management (Quản lý game)

#### `createGame(params)`

Tạo game mới. Chỉ game owner mới có quyền tạo round cho game.

```typescript
interface CreateGameParams {
  gameName: string;    // Tên game (unique với mỗi owner)
  devFeeBps: number;   // Phí developer (0-10000, 10000 = 100%)
  treasury: string;    // Địa chỉ nhận phí developer
}

// Ví dụ
const result = await sdk.createGame({
  gameName: "My Prize Game",
  devFeeBps: 500,      // 5%
  treasury: "0x...",
});

console.log("Game ID:", result.gameId);
```

#### `createRound(params)`

Tạo round mới cho game. Chỉ game owner mới có quyền.

```typescript
interface CreateRoundParams {
  gameId: string;           // Game ID
  startTs: bigint | number; // Unix timestamp bắt đầu
  endTs: bigint | number;   // Unix timestamp kết thúc nhận deposit
  lockTime: bigint | number;// Thời gian khóa (giây)
  depositFeeBps: number;    // Phí deposit (0-1000, max 10%)
  paymentToken: string;     // Địa chỉ token
}

// Ví dụ
const now = Math.floor(Date.now() / 1000);
const result = await sdk.createRound({
  gameId: "0x...",
  startTs: now,
  endTs: now + 86400,      // 1 ngày
  lockTime: 604800,        // 7 ngày
  depositFeeBps: 100,      // 1%
  paymentToken: "0x...",
});

console.log("Round ID:", result.roundId);
```

---

### Game Owner Actions (Hành động của game owner)

#### `depositToVault(gameId, roundId)`

Deploy tiền của round vào ERC4626 vault để sinh lợi nhuận.

```typescript
await sdk.depositToVault(gameId, roundId);
```

#### `withdrawFromVault(gameId, roundId)`

Rút tiền từ vault về contract. Phải thực hiện sau khi lock time kết thúc.

```typescript
await sdk.withdrawFromVault(gameId, roundId);
```

#### `settlement(gameId, roundId)`

Tính toán và phân phối fees. Phải thực hiện sau `withdrawFromVault`.

```typescript
await sdk.settlement(gameId, roundId);
```

#### `chooseWinner(params)`

Chọn người thắng và phân bổ tiền thưởng.

```typescript
interface ChooseWinnerParams {
  gameId: string;
  roundId: bigint | number;
  winner: string;           // Địa chỉ người thắng
  amount: bigint | string;  // Số tiền thưởng
}

// Ví dụ
await sdk.chooseWinner({
  gameId: "0x...",
  roundId: 0,
  winner: "0x...",
  amount: ethers.parseUnits("50", 18),
});
```

#### `finalizeRound(gameId, roundId)`

Kết thúc round và cho phép users claim. Tiền thưởng còn lại (nếu có) sẽ được chuyển về treasury.

```typescript
await sdk.finalizeRound(gameId, roundId);
```

---

### View Functions (Đọc thông tin)

#### `getGame(gameId)`

Lấy thông tin game.

```typescript
const game = await sdk.getGame(gameId);
console.log("Game name:", game.gameName);
console.log("Round count:", game.roundCounter);
```

#### `getRound(gameId, roundId)`

Lấy thông tin round.

```typescript
const round = await sdk.getRound(gameId, 0);
console.log("Total deposit:", ethers.formatUnits(round.totalDeposit, 18));
console.log("Status:", round.status);
```

#### `getUserDeposit(gameId, roundId, userAddress)`

Lấy thông tin deposit của user.

```typescript
const deposit = await sdk.getUserDeposit(gameId, 0, userAddress);
console.log("Deposited:", ethers.formatUnits(deposit.depositAmount, 18));
console.log("Prize:", ethers.formatUnits(deposit.amountToClaim, 18));
console.log("Claimed:", deposit.isClaimed);
```

#### `getCurrentStatus(gameId, roundId)`

Lấy trạng thái hiện tại của round.

```typescript
import { RoundStatus } from "./sdk/sdk";

const status = await sdk.getCurrentStatus(gameId, 0);

switch (status) {
  case RoundStatus.NotStarted:
    console.log("Round chưa bắt đầu");
    break;
  case RoundStatus.InProgress:
    console.log("Đang nhận deposit");
    break;
  case RoundStatus.Locking:
    console.log("Đang khóa");
    break;
  case RoundStatus.ChoosingWinners:
    console.log("Đang chọn người thắng");
    break;
  case RoundStatus.DistributingRewards:
    console.log("Có thể claim");
    break;
}
```

#### `calculateGameId(owner, gameName)`

Tính Game ID từ owner và tên game.

```typescript
const gameId = await sdk.calculateGameId(ownerAddress, "My Game");
```

#### `getVault(tokenAddress)`

Lấy địa chỉ vault cho một token.

```typescript
const vaultAddress = await sdk.getVault(tokenAddress);
```

#### `isPaused()`

Kiểm tra contract có đang pause không.

```typescript
const paused = await sdk.isPaused();
```

#### `getProtocolTreasury()`

Lấy địa chỉ protocol treasury.

```typescript
const treasury = await sdk.getProtocolTreasury();
```

#### `getDeployedAmounts(gameId, roundId)`

Lấy số tiền đã deploy vào vault.

```typescript
const amount = await sdk.getDeployedAmounts(gameId, 0);
```

#### `getDeployedShares(gameId, roundId)`

Lấy số shares nhận được từ vault.

```typescript
const shares = await sdk.getDeployedShares(gameId, 0);
```

---

### Token Utilities (Tiện ích token)

#### `getTokenBalance(tokenAddress, userAddress?)`

Lấy balance token của một địa chỉ.

```typescript
const balance = await sdk.getTokenBalance(tokenAddress, userAddress);
console.log("Balance:", ethers.formatUnits(balance, 18));
```

#### `getTokenAllowance(tokenAddress, ownerAddress?)`

Lấy allowance đã approve cho YieldPlay contract.

```typescript
const allowance = await sdk.getTokenAllowance(tokenAddress, ownerAddress);
```

#### `approveToken(tokenAddress, amount?)`

Approve token cho YieldPlay contract.

```typescript
// Approve số lượng cụ thể
await sdk.approveToken(tokenAddress, ethers.parseUnits("1000", 18));

// Approve unlimited
await sdk.approveToken(tokenAddress, ethers.MaxUint256);
```

---

### Utility Methods

#### `getContract()`

Lấy instance Contract để sử dụng nâng cao.

```typescript
const contract = sdk.getContract();
```

#### `updateSigner(newSigner)`

Cập nhật signer (khi user đổi account).

```typescript
const newSigner = new ethers.Wallet(NEW_PRIVATE_KEY, provider);
sdk.updateSigner(newSigner);
```

---

## Complete Example

### Tạo Game và Round

```typescript
import { ethers } from "ethers";
import { config } from "dotenv";
import { YieldPlaySDK, RoundStatus } from "./sdk/sdk";

config(); // Load .env

async function main() {
  // Setup
  const provider = new ethers.JsonRpcProvider("https://ethereum-sepolia-rpc.publicnode.com");
  const signer = new ethers.Wallet(process.env.PRIVATE_KEY!, provider);
  
  const sdk = new YieldPlaySDK({
    yieldPlayAddress: "0x02AA158dc37f4E1128CeE3E69e9E59920E799F90",
    signer,
  });

  // 1. Tạo game
  const gameResult = await sdk.createGame({
    gameName: "Lucky Draw " + Date.now(),
    devFeeBps: 500, // 5%
    treasury: await signer.getAddress(),
  });
  console.log("Game created:", gameResult.gameId);

  // 2. Tạo round
  const now = Math.floor(Date.now() / 1000);
  const roundResult = await sdk.createRound({
    gameId: gameResult.gameId,
    startTs: now,
    endTs: now + 86400,    // 1 ngày deposit
    lockTime: 604800,      // 7 ngày lock
    depositFeeBps: 100,    // 1%
    paymentToken: "0xdd13E55209Fd76AfE204dBda4007C227904f0a81",
  });
  console.log("Round created:", roundResult.roundId);
}

main().catch(console.error);
```

### Full Round Lifecycle

```typescript
async function fullRoundLifecycle(sdk: YieldPlaySDK, gameId: string, roundId: bigint) {
  // 1. Users deposit (trong thời gian InProgress)
  const status = await sdk.getCurrentStatus(gameId, roundId);
  if (status === RoundStatus.InProgress) {
    await sdk.deposit({
      gameId,
      roundId,
      amount: ethers.parseUnits("100", 18),
    });
  }

  // 2. Game owner deploy to vault (trong Locking hoặc InProgress)
  if (status === RoundStatus.Locking || status === RoundStatus.InProgress) {
    await sdk.depositToVault(gameId, roundId);
  }

  // 3. Sau lock time, withdraw và settle (ChoosingWinners)
  if (status === RoundStatus.ChoosingWinners) {
    await sdk.withdrawFromVault(gameId, roundId);
    await sdk.settlement(gameId, roundId);

    // Chọn người thắng
    const round = await sdk.getRound(gameId, roundId);
    await sdk.chooseWinner({
      gameId,
      roundId,
      winner: "0x...",
      amount: round.totalWin,
    });
  }

  // 4. Users claim (DistributingRewards)
  if (status === RoundStatus.DistributingRewards) {
    await sdk.claim({ gameId, roundId });
  }
}
```

---

## Error Handling

```typescript
try {
  await sdk.deposit({
    gameId: "0x...",
    roundId: 0,
    amount: ethers.parseUnits("100", 18),
  });
} catch (error: any) {
  // Xử lý các lỗi phổ biến
  if (error.message.includes("RoundNotActive")) {
    console.error("Round không đang active");
  } else if (error.message.includes("InvalidAmount")) {
    console.error("Số lượng không hợp lệ");
  } else if (error.message.includes("insufficient funds")) {
    console.error("Không đủ ETH cho gas");
  } else {
    console.error("Lỗi:", error.message);
  }
}
```

---

## Chạy Example

```bash
# 1. Tạo file .env
cp .env.example .env

# 2. Điền PRIVATE_KEY vào .env

# 3. Chạy example
npx ts-node sdk/example.ts
```

---

## Fee Structure

### Tổng quan

YieldPlay có 3 loại phí:

| Loại phí | Tỷ lệ | Người nhận | Mô tả |
|----------|-------|------------|-------|
| **Performance Fee** | 20% cố định | Protocol Treasury | Phí protocol trên yield sinh ra |
| **Developer Fee** | 0-100% (tùy chọn) | Game Treasury | Phí game owner trên yield (sau performance fee) |
| **Deposit Fee** | 0-10% (tùy chọn) | Prize Pool | Phí khi user deposit, được cộng vào prize pool |

### Chi tiết từng loại phí

#### 1. Performance Fee (20%)
- **Cố định**: 2000 basis points = 20%
- **Áp dụng**: Trên tổng yield sinh ra từ vault
- **Người nhận**: Protocol Treasury
- **Thời điểm**: Thu khi settlement

```
Yield từ vault = 1000 USDC
Performance Fee = 1000 * 20% = 200 USDC → Protocol Treasury
Còn lại = 800 USDC
```

#### 2. Developer Fee (0-100%)
- **Cài đặt**: Khi tạo game (`devFeeBps` trong `createGame()`)
- **Áp dụng**: Trên yield sau khi trừ Performance Fee
- **Người nhận**: Game Treasury

```typescript
// Ví dụ: devFeeBps = 500 (5%)
await sdk.createGame({
  gameName: "My Game",
  devFeeBps: 500,  // 5% = 500 basis points
  treasury: gameOwnerAddress,
});
```

```
Yield sau performance fee = 800 USDC
Developer Fee = 800 * 5% = 40 USDC → Game Treasury
Prize Pool từ yield = 760 USDC
```

#### 3. Deposit Fee (0-10%)
- **Cài đặt**: Khi tạo round (`depositFeeBps` trong `createRound()`)
- **Giới hạn**: Tối đa 1000 basis points = 10%
- **Áp dụng**: Trên mỗi lần user deposit
- **Đặc biệt**: Deposit fee được cộng vào Bonus Prize Pool, không phải phí thu

```typescript
// Ví dụ: depositFeeBps = 100 (1%)
await sdk.createRound({
  gameId: "0x...",
  depositFeeBps: 100,  // 1% = 100 basis points
  // ...
});
```

```
User deposit = 100 USDC
Deposit Fee = 100 * 1% = 1 USDC → Bonus Prize Pool
Net Deposit (user credit) = 99 USDC
```

### Ví dụ tính toán đầy đủ

**Cài đặt:**
- Performance Fee: 20% (cố định)
- Developer Fee: 5% (devFeeBps = 500)
- Deposit Fee: 1% (depositFeeBps = 100)
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

## Links

- **Sepolia Etherscan**: https://sepolia.etherscan.io/address/0x02AA158dc37f4E1128CeE3E69e9E59920E799F90
- **GitHub**: https://github.com/your-repo/yield-play-eth
