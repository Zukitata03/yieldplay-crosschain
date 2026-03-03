/**
 * Example usage of YieldPlay SDK
 * 
 * This file demonstrates how the backend can interact with
 * the YieldPlay smart contract using the SDK.
 * 
 * Run: npx ts-node sdk/example.ts
 */

import { ethers } from "ethers";
import { config } from "dotenv";
import { YieldPlaySDK, RoundStatus } from "./sdk";

// Load environment variables
config();

// ============ Configuration ============

// Sepolia Testnet Deployment
const YIELD_PLAY_ADDRESS = "0x02AA158dc37f4E1128CeE3E69e9E59920E799F90";
const RPC_URL = "https://ethereum-sepolia-rpc.publicnode.com";
const PRIVATE_KEY = process.env.PRIVATE_KEY || ""; // Set in .env file

// Token addresses on Sepolia
const TOKEN_ADDRESS = "0xdd13E55209Fd76AfE204dBda4007C227904f0a81"; // Vault's underlying token

// ============ Initialize SDK ============

async function initializeSDK(): Promise<YieldPlaySDK> {
  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const signer = new ethers.Wallet(PRIVATE_KEY, provider);

  return new YieldPlaySDK({
    yieldPlayAddress: YIELD_PLAY_ADDRESS,
    signer,
  });
}

// ============ Example: Deposit ============

async function exampleDeposit() {
  const sdk = await initializeSDK();

  // Deposit 100 tokens (assuming 18 decimals)
  const result = await sdk.deposit({
    gameId: "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
    roundId: 0,
    amount: ethers.parseUnits("100", 18),
  });

  console.log("Deposit successful!");
  console.log("Transaction hash:", result.hash);
  console.log("Gas used:", result.receipt?.gasUsed.toString());
}

// ============ Example: Create Game and Round ============

async function exampleCreateGameAndRound() {
  console.log("Initializing SDK...");
  const sdk = await initializeSDK();
  
  // Get signer address
  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const signer = new ethers.Wallet(PRIVATE_KEY, provider);
  const signerAddress = await signer.getAddress();
  console.log("Signer address:", signerAddress);

  // 1. Create a new game
  console.log("\n--- Creating Game ---");
  const gameResult = await sdk.createGame({
    gameName: "My Awesome Game " + Date.now(), // Unique name
    devFeeBps: 500, // 5% developer fee
    treasury: signerAddress // Developer treasury address
  });

  console.log("Game created!");
  console.log("Game ID:", gameResult.gameId);
  console.log("Transaction:", gameResult.hash);

  // 2. Create a round for the game
  console.log("\n--- Creating Round ---");
  const now = Math.floor(Date.now() / 1000);
  const roundResult = await sdk.createRound({
    gameId: gameResult.gameId,
    startTs: now,
    endTs: now + 86400, // 1 day deposit window
    lockTime: 604800, // 7 days lock period
    depositFeeBps: 100, // 1% deposit fee
    paymentToken: TOKEN_ADDRESS // Use the vault's underlying token
  });

  console.log("Round created!");
  console.log("Round ID:", roundResult.roundId.toString());
}

// ============ Example: Full Round Lifecycle ============

async function exampleFullRoundLifecycle() {
  const sdk = await initializeSDK();

  const gameId = "0x..."; // Your game ID
  const roundId = 0n;

  // 1. Check round status
  const status = await sdk.getCurrentStatus(gameId, roundId);
  console.log("Current status:", RoundStatus[status]);

  // 2. Get round info
  const round = await sdk.getRound(gameId, roundId);
  console.log("Total deposits:", ethers.formatUnits(round.totalDeposit, 18));

  // 3. User deposits (during InProgress status)
  if (status === RoundStatus.InProgress) {
    await sdk.deposit({
      gameId,
      roundId,
      amount: ethers.parseUnits("50", 18),
    });
  }

  // 4. Deploy to vault (during Locking or InProgress status)
  // This should be done by game owner
  if (status === RoundStatus.Locking || status === RoundStatus.InProgress) {
    await sdk.depositToVault(gameId, roundId);
  }

  // 5. Withdraw from vault and settle (during ChoosingWinners status)
  if (status === RoundStatus.ChoosingWinners) {
    // First withdraw
    await sdk.withdrawFromVault(gameId, roundId);

    // Then settle
    await sdk.settlement(gameId, roundId);

    // Choose winners
    await sdk.chooseWinner({
      gameId,
      roundId,
      winner: "0x...", // Winner address
      amount: round.totalWin,
    });

    // Or finalize if distributing remaining to treasury
    // await sdk.finalizeRound(gameId, roundId);
  }

  // 6. Users claim (during DistributingRewards status)
  if (status === RoundStatus.DistributingRewards) {
    await sdk.claim({ gameId, roundId });
  }
}

// ============ Example: Check User Position ============

async function exampleCheckUserPosition() {
  const sdk = await initializeSDK();

  const gameId = "0x...";
  const roundId = 0n;
  const userAddress = "0x...";

  // Get user deposit info
  const deposit = await sdk.getUserDeposit(gameId, roundId, userAddress);

  console.log("User position:");
  console.log("- Deposited:", ethers.formatUnits(deposit.depositAmount, 18));
  console.log("- Prize to claim:", ethers.formatUnits(deposit.amountToClaim, 18));
  console.log("- Already claimed:", deposit.isClaimed);
}

// ============ Example: Token Operations ============

async function exampleTokenOperations() {
  const sdk = await initializeSDK();

  const tokenAddress = TOKEN_ADDRESS; // Use the vault's underlying token
  
  // Get signer address
  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const signer = new ethers.Wallet(PRIVATE_KEY, provider);
  const userAddress = await signer.getAddress();

  // Check balance
  const balance = await sdk.getTokenBalance(tokenAddress, userAddress);
  console.log("Token balance:", ethers.formatUnits(balance, 18));

  // Check allowance
  const allowance = await sdk.getTokenAllowance(tokenAddress, userAddress);
  console.log("Current allowance:", ethers.formatUnits(allowance, 18));

  // Approve tokens (if needed)
  await sdk.approveToken(tokenAddress, ethers.MaxUint256);
  console.log("Token approved for unlimited spending");
}

// Run examples
async function main() {
  try {
    // Uncomment the example you want to run
    // await exampleDeposit();
    await exampleCreateGameAndRound();
    // await exampleFullRoundLifecycle();
    // await exampleCheckUserPosition();
    // await exampleTokenOperations();

    console.log("Example completed successfully!");
  } catch (error) {
    console.error("Error:", error);
  }
}

main();
