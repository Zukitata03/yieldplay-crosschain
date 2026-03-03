/**
 * deploySender.ts
 *
 * Deploy YieldPlaySender on chainA (source subnet).
 *
 * Usage:
 *   npx hardhat run scripts/deploySender.ts --network chainA
 *
 * Required env vars:
 *   CHAIN_B_BLOCKCHAIN_ID     — bytes32 chain ID of chainB (from `avalanche blockchain describe chainB`)
 *   YIELD_PLAY_RECEIVER_ADDR  — YieldPlayReceiver address on chainB (from deployReceiver.ts output)
 *   SOURCE_TOKEN_CHAIN_A      — ERC20 token address on chainA
 *   SOURCE_CHAIN_A_BLOCKCHAIN_ID — bytes32 chain ID of chainA (to register as trusted sender on chainB)
 *
 * After running, call setTrustedSender() on YieldPlayReceiver (chainB) with:
 *   - sourceChainId = chainA blockchain ID
 *   - senderContract = YieldPlaySender address on chainA
 */

import { ethers } from "hardhat";

async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("Deployer:", deployer.address);
    console.log("Network:", (await ethers.provider.getNetwork()).name);

    // ── Config ──────────────────────────────────────────────────────────────────
    const CHAIN_B_BLOCKCHAIN_ID = process.env.CHAIN_B_BLOCKCHAIN_ID;
    const RECEIVER_ADDR = process.env.YIELD_PLAY_RECEIVER_ADDR;
    const SOURCE_TOKEN = process.env.SOURCE_TOKEN_CHAIN_A;

    if (!CHAIN_B_BLOCKCHAIN_ID) throw new Error("Set CHAIN_B_BLOCKCHAIN_ID in .env");
    if (!RECEIVER_ADDR) throw new Error("Set YIELD_PLAY_RECEIVER_ADDR in .env");
    if (!SOURCE_TOKEN) throw new Error("Set SOURCE_TOKEN_CHAIN_A in .env");

    // ── Deploy YieldPlaySender ──────────────────────────────────────────────────
    console.log("\n[1/2] Deploying YieldPlaySender...");
    const Sender = await ethers.getContractFactory("YieldPlaySender");
    const sender = await Sender.deploy(
        CHAIN_B_BLOCKCHAIN_ID,   // destinationBlockchainID
        RECEIVER_ADDR,           // destinationReceiver
        SOURCE_TOKEN             // sourceToken
    );
    await sender.waitForDeployment();
    const senderAddr = await sender.getAddress();
    console.log("  YieldPlaySender:", senderAddr);

    // ── Output ──────────────────────────────────────────────────────────────────
    console.log("\n[2/2] ✅ Deployment complete:");
    console.log({
        yieldPlaySender: senderAddr,
        destinationChainB: CHAIN_B_BLOCKCHAIN_ID,
        destinationReceiver: RECEIVER_ADDR,
        sourceToken: SOURCE_TOKEN,
    });

    console.log("\n─── Next Steps ────────────────────────────────────────────────");
    console.log("Register this Sender as trusted on chainB's YieldPlayReceiver:");
    console.log("  chainA blockchain ID: run `avalanche blockchain describe chainA`");
    console.log("  Call YieldPlayReceiver.setTrustedSender(chainA_ID, YieldPlaySender_addr)");
    console.log("\nThen run the E2E test:");
    console.log("  npx hardhat run scripts/testCrossChain.ts --network chainA");
}

main().catch((e) => { console.error(e); process.exit(1); });
