/**
 * testCrossChain.ts
 *
 * End-to-end test script for the Teleporter cross-chain deposit flow.
 *
 * What it does:
 *   1. Creates a game + round on chainB (via an ethers provider pointing at chainB)
 *   2. Funds a test user with source token on chainA
 *   3. Calls YieldPlaySender.crossChainDeposit() on chainA
 *   4. Waits for the Teleporter relayer to deliver the message to chainB (~10s)
 *   5. Reads getUserDeposit() on chainB and asserts the deposit was credited
 *
 * Usage (run AFTER deploySender.ts and deployReceiver.ts):
 *   npx hardhat run scripts/testCrossChain.ts --network chainA
 *
 * Required env vars (in addition to .env set up for chainA):
 *   CHAIN_A_RPC_URL            — RPC of chainA local node
 *   CHAIN_B_RPC_URL            — RPC of chainB local node
 *   YIELD_PLAY_SENDER_ADDR     — YieldPlaySender on chainA
 *   YIELD_PLAY_ADDR_CHAIN_B    — YieldPlay on chainB
 *   YIELD_PLAY_RECEIVER_ADDR   — YieldPlayReceiver on chainB
 *   SOURCE_TOKEN_CHAIN_A       — ERC20 on chainA
 *   PAYMENT_TOKEN_CHAIN_B      — ERC20 on chainB
 *   VAULT_CHAIN_B              — ERC4626 vault address on chainB
 *   GAME_OWNER_PRIVATE_KEY     — private key (must have tokens on BOTH chains)
 */

import { ethers } from "hardhat";

const IERC20_ABI = [
    "function approve(address,uint256) returns (bool)",
    "function transfer(address,uint256) returns (bool)",
    "function balanceOf(address) view returns (uint256)",
];

const YIELDPLAY_ABI = [
    "function createGame(string,uint16,address) returns (bytes32)",
    "function createRound(bytes32,uint64,uint64,uint64,uint16,address) returns (uint256)",
    "function getUserDeposit(bytes32,uint256,address) view returns (tuple(uint256 depositAmount, uint256 amountToClaim, bool isClaimed, bool exists))",
    "function setVault(address,address)",
    "function setCrossChainReceiver(address)",
];

const SENDER_ABI = [
    "function crossChainDeposit(bytes32,uint256,uint256) returns (bytes32)",
];

const RECEIVER_ABI = [
    "function setTrustedSender(bytes32,address)",
];

function required(name: string): string {
    const v = process.env[name];
    if (!v) throw new Error(`Missing env var: ${name}`);
    return v;
}

async function sleep(ms: number) {
    return new Promise((r) => setTimeout(r, ms));
}

async function main() {
    // ── Providers ──────────────────────────────────────────────────────────────
    const pk = required("GAME_OWNER_PRIVATE_KEY");

    const chainAProvider = new ethers.JsonRpcProvider(required("CHAIN_A_RPC_URL"));
    const chainBProvider = new ethers.JsonRpcProvider(required("CHAIN_B_RPC_URL"));

    const walletA = new ethers.Wallet(pk, chainAProvider);
    const walletB = new ethers.Wallet(pk, chainBProvider);

    console.log("Test account:", walletA.address);

    // ── Contract references ───────────────────────────────────────────────────
    const sender = new ethers.Contract(required("YIELD_PLAY_SENDER_ADDR"), SENDER_ABI, walletA);
    const yieldPlay = new ethers.Contract(required("YIELD_PLAY_ADDR_CHAIN_B"), YIELDPLAY_ABI, walletB);
    const receiver = new ethers.Contract(required("YIELD_PLAY_RECEIVER_ADDR"), RECEIVER_ABI, walletB);
    const tokenA = new ethers.Contract(required("SOURCE_TOKEN_CHAIN_A"), IERC20_ABI, walletA);
    const tokenB = new ethers.Contract(required("PAYMENT_TOKEN_CHAIN_B"), IERC20_ABI, walletB);

    const VAULT_CHAIN_B = required("VAULT_CHAIN_B");

    // ── Step 1: Wire vault on chainB (may already be set) ───────────────────
    console.log("\n[1] Setting vault on chainB YieldPlay...");
    try {
        await (await yieldPlay.setVault(required("PAYMENT_TOKEN_CHAIN_B"), VAULT_CHAIN_B)).wait();
        console.log("  Vault set.");
    } catch (e: any) {
        console.log("  (already set or skipping):", e.shortMessage ?? e.message);
    }

    // ── Step 2: Create game + round on chainB ─────────────────────────────────
    console.log("\n[2] Creating game on chainB...");
    const gameName = `CrossChainTest_${Date.now()}`;
    const gameId = ethers.solidityPackedKeccak256(
        ["address", "string"], [walletB.address, gameName]
    );
    await (await yieldPlay.createGame(gameName, 500, walletB.address)).wait();
    console.log("  gameId:", gameId);

    const now = BigInt(Math.floor(Date.now() / 1000));
    const startTs = now + 10n;
    const endTs = now + 3600n;   // 1 hour deposit window
    const lockTime = 3600n;         // 1 hour lock

    console.log("\n[3] Creating round on chainB...");
    const roundTx = await yieldPlay.createRound(gameId, startTs, endTs, lockTime, 100, required("PAYMENT_TOKEN_CHAIN_B"));
    await roundTx.wait();
    const roundId = 0n; // first round = 0
    console.log("  roundId:", roundId.toString());

    // ── Step 3: Fund receiver on chainB with enough tokens ───────────────────
    const DEPOSIT_AMOUNT = ethers.parseUnits("10", 6); // 10 USDC (6 decimals)

    console.log("\n[4] Funding YieldPlayReceiver on chainB with tokens...");
    const receiverAddr = required("YIELD_PLAY_RECEIVER_ADDR");
    await (await tokenB.transfer(receiverAddr, DEPOSIT_AMOUNT)).wait();
    console.log("  Funded receiver with", ethers.formatUnits(DEPOSIT_AMOUNT, 6), "tokens");

    // ── Step 4: Wait for round to start ──────────────────────────────────────
    console.log("\n[5] Waiting for round to start (10s)...");
    await sleep(12_000);

    // ── Step 5: Approve + fire cross-chain deposit on chainA ─────────────────
    console.log("\n[6] Approving YieldPlaySender on chainA...");
    const senderAddr = required("YIELD_PLAY_SENDER_ADDR");
    await (await tokenA.approve(senderAddr, DEPOSIT_AMOUNT)).wait();

    console.log("\n[7] Calling crossChainDeposit() on chainA...");
    const tx = await sender.crossChainDeposit(gameId, roundId, DEPOSIT_AMOUNT);
    const receipt = await tx.wait();
    console.log("  TX hash:", receipt.hash);

    // ── Step 6: Wait for relayer to deliver message ────────────────────────
    console.log("\n[8] Waiting for Teleporter relayer to deliver message to chainB (~15s)...");
    await sleep(15_000);

    // ── Step 7: Verify deposit credited on chainB ─────────────────────────
    console.log("\n[9] Checking deposit on chainB...");
    const dep = await yieldPlay.getUserDeposit(gameId, roundId, walletA.address);
    console.log("  exists:", dep.exists);
    console.log("  depositAmount:", ethers.formatUnits(dep.depositAmount, 6));

    if (!dep.exists || dep.depositAmount === 0n) {
        console.error("\n❌ FAIL: Deposit not credited on chainB. Check relayer logs.");
        process.exit(1);
    }

    console.log("\n✅ SUCCESS: Cross-chain deposit verified on chainB!");
    console.log(`   User ${walletA.address} deposited ${ethers.formatUnits(dep.depositAmount, 6)} tokens cross-chain.`);
}

main().catch((e) => { console.error(e); process.exit(1); });
