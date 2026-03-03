

import { ethers } from "hardhat";

async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("Deployer:", deployer.address);
    console.log("Network:", (await ethers.provider.getNetwork()).name);

    // ── Config ──────────────────────────────────────────────────────────────────
    // Token on chainB.
    const PAYMENT_TOKEN = process.env.PAYMENT_TOKEN_CHAIN_B;
    if (!PAYMENT_TOKEN) throw new Error("Set PAYMENT_TOKEN_CHAIN_B in .env");

    // ── Deploy YieldPlay ────────────────────────────────────────────────────────
    console.log("\n[1/4] Deploying YieldPlay...");
    const YieldPlay = await ethers.getContractFactory("YieldPlay");
    const yieldPlay = await YieldPlay.deploy(deployer.address); // deployer = protocol treasury
    await yieldPlay.waitForDeployment();
    const yieldPlayAddr = await yieldPlay.getAddress();
    console.log("  YieldPlay:", yieldPlayAddr);


    // ── Deploy YieldPlayReceiver ────────────────────────────────────────────────
    console.log("\n[2/4] Deploying YieldPlayReceiver...");
    const Receiver = await ethers.getContractFactory("YieldPlayReceiver");
    const receiver = await Receiver.deploy(yieldPlayAddr, PAYMENT_TOKEN);
    await receiver.waitForDeployment();
    const receiverAddr = await receiver.getAddress();
    console.log("  YieldPlayReceiver:", receiverAddr);

    // ── Wire YieldPlay to trust the Receiver ───────────────────────────────────
    console.log("\n[3/4] Setting cross-chain receiver on YieldPlay...");
    await yieldPlay.setCrossChainReceiver(receiverAddr);
    console.log("  Done.");

    // ── Output ──────────────────────────────────────────────────────────────────
    console.log("\n[4/4] ✅ Deployment complete:");
    console.log({
        yieldPlay: yieldPlayAddr,
        yieldPlayReceiver: receiverAddr,
        paymentToken: PAYMENT_TOKEN,
        deployer: deployer.address,
    });

    console.log("\n─── Next Steps ────────────────────────────────────────────────");
    console.log("1. Get chainB blockchain ID:  avalanche blockchain describe chainB");
    console.log("2. Copy RECEIVER address and chainB_ID into deploySender.ts");
    console.log("3. Run: npx hardhat run scripts/deploySender.ts --network chainA");
}

main().catch((e) => { console.error(e); process.exit(1); });
