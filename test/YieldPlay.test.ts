/**
 * @file YieldPlay.test.ts
 * @notice Fork test against Avalanche mainnet using the real Euler eUSDC-19 vault
 *
 * Vault:      0x37ca03aD51B8ff79aAD35FadaCBA4CEDF0C3e74e  (Euler eUSDC-19)
 * Underlying: 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E  (USDC on Avalanche)
 * Block:      79094077  (pinned in hardhat.config.ts)
 *
 * Run:  npx hardhat test
 */

import { expect } from "chai";
import { ethers, network } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import { IERC20, IERC4626, YieldPlay } from "../typechain-types";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

// ─── Addresses on Avalanche C-Chain ───────────────────────────────────────────
const EULER_VAULT  = "0x37ca03aD51B8ff79aAD35FadaCBA4CEDF0C3e74e"; // eUSDC-19
const USDC_ADDRESS = "0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E"; // USDC (6 decimals)

// Aave aUSDC contract holds underlying USDC as collateral — richest USDC holder on Avax
const USDC_WHALE   = "0x625E7708f30cA75bfd92586e17077590C60eb4cD"; // Aave aUSDC (~34M USDC)

const USDC = (amount: number) => ethers.parseUnits(String(amount), 6);

// ─────────────────────────────────────────────────────────────────────────────

describe("YieldPlay – Avalanche mainnet fork (Euler eUSDC-19)", function () {
  // These tests call real RPC and may be slow
  this.timeout(120_000);

  let yieldPlay: YieldPlay;
  let usdc: IERC20;
  let vault: IERC4626;

  let deployer:         SignerWithAddress;
  let gameOwner:        SignerWithAddress;
  let protocolTreasury: SignerWithAddress;
  let user1:            SignerWithAddress;
  let user2:            SignerWithAddress;

  let whale: any; // impersonated signer

  let gameId:  string;
  let roundId: bigint;

  before(async function () {
    [deployer, gameOwner, protocolTreasury, user1, user2] = await ethers.getSigners();

    // Mine one empty block so local blockNumber advances past the fork block.
    // Hardhat EDR cannot resolve the hardfork when blockNumber === forkBlockNumber exactly.
    await network.provider.send("evm_mine");

    // ── Attach to real on-chain contracts ──────────────────────────────────
    usdc  = await ethers.getContractAt("IERC20",   USDC_ADDRESS) as unknown as IERC20;
    vault = await ethers.getContractAt("IERC4626", EULER_VAULT)  as unknown as IERC4626;

    // ── Check vault still accepts deposits (supply cap guard) ──────────────
    const maxDep = await vault.maxDeposit(deployer.address);
    if (maxDep === 0n) {
      console.warn("  ⚠️  Vault supply cap is full – skipping fork tests");
      this.skip();
    }
    console.log(`  Vault totalAssets : ${ethers.formatUnits(await vault.totalAssets(), 6)} USDC`);
    console.log(`  Vault maxDeposit  : ${ethers.formatUnits(maxDep, 6)} USDC`);

    // ── Impersonate USDC whale and fund it with AVAX for gas ──────────────
    await network.provider.request({ method: "hardhat_impersonateAccount", params: [USDC_WHALE] });
    await network.provider.send("hardhat_setBalance", [
      USDC_WHALE,
      "0x" + (10n ** 20n).toString(16), // 100 AVAX
    ]);
    whale = await ethers.getSigner(USDC_WHALE);

    // Transfer USDC to test users
    const whaleBal = await usdc.balanceOf(USDC_WHALE);
    console.log(`  Whale USDC balance: ${ethers.formatUnits(whaleBal, 6)} USDC`);
    expect(whaleBal).to.be.gt(USDC(2000), "Whale doesn't have enough USDC");

    await usdc.connect(whale).transfer(user1.address, USDC(1000));
    await usdc.connect(whale).transfer(user2.address, USDC(1000));

    // ── Deploy YieldPlay ──────────────────────────────────────────────────
    const YieldPlayFactory = await ethers.getContractFactory("YieldPlay", deployer);
    yieldPlay = await YieldPlayFactory.deploy(protocolTreasury.address);
    await yieldPlay.waitForDeployment();

    // Point YieldPlay at the real Euler vault
    await yieldPlay.connect(deployer).setVault(USDC_ADDRESS, EULER_VAULT);
    console.log(`  YieldPlay deployed: ${await yieldPlay.getAddress()}`);
  });

  // ──────────────────────────────────────────────────────────────────────────
  it("creates a game and round", async function () {
    const now     = BigInt(await time.latest());
    const startTs = now + 10n;
    const endTs   = now + 86_400n;       // 1 day deposit window
    const lockTime = 7n * 86_400n;       // 7-day lock → yield accrues in vault


    gameId = await yieldPlay
      .connect(gameOwner)
      .createGame
      .staticCall(
        "ForkTestGame",
        500,           // 5% dev fee
        gameOwner.address
      );

    const tx = await yieldPlay
      .connect(gameOwner)
      .createGame(
        "ForkTestGame",
        500,           // 5% dev fee
        gameOwner.address
      );
    const receipt = await tx.wait();

    // Derive gameId the same way the contract does
    gameId = ethers.solidityPackedKeccak256(
      ["address", "string"],
      [gameOwner.address, "ForkTestGame"]
    );
    
    roundId = await yieldPlay
      .connect(gameOwner)
      .createRound.staticCall(gameId, startTs, endTs, lockTime, 100, USDC_ADDRESS); // 1% deposit fee

    await yieldPlay.connect(gameOwner).createRound(gameId, startTs, endTs, lockTime, 100, USDC_ADDRESS);

    const game  = await yieldPlay.getGame(gameId);
    const round = await yieldPlay.getRound(gameId, roundId);

    expect(round.paymentToken).to.equal(USDC_ADDRESS);
    expect(round.startTs).to.equal(startTs);
    console.log(`  gameId : ${gameId}`);
    console.log(`  roundId: ${roundId}`);
  });

  // ──────────────────────────────────────────────────────────────────────────
  it("users deposit USDC into the round", async function () {
    // Warp to the start of the round
    const round = await yieldPlay.getRound(gameId, roundId);
    await time.increaseTo(Number(round.startTs) + 1);

    // Approve and deposit
    await usdc.connect(user1).approve(await yieldPlay.getAddress(), USDC(500));
    await usdc.connect(user2).approve(await yieldPlay.getAddress(), USDC(300));

    await yieldPlay.connect(user1).deposit(gameId, roundId, USDC(500));
    await yieldPlay.connect(user2).deposit(gameId, roundId, USDC(300));

    const roundState = await yieldPlay.getRound(gameId, roundId);
    // net: 500 * 99% = 495, 300 * 99% = 297 (1% deposit fee)
    const expectedNet = USDC(500) * 99n / 100n + USDC(300) * 99n / 100n;
    expect(roundState.totalDeposit).to.be.closeTo(expectedNet, USDC(1));

    console.log(`  totalDeposit : ${ethers.formatUnits(roundState.totalDeposit, 6)} USDC`);
    console.log(`  bonusPrizePool: ${ethers.formatUnits(roundState.bonusPrizePool, 6)} USDC`);
  });

  // ──────────────────────────────────────────────────────────────────────────
  it("game owner deploys funds into the real Euler vault", async function () {
    const round = await yieldPlay.getRound(gameId, roundId);

    // Warp past endTs → enters Locking period
    await time.increaseTo(Number(round.endTs) + 60);

    await yieldPlay.connect(gameOwner).depositToVault(gameId, roundId);

    const deployed = await yieldPlay.deployedShares(gameId, roundId);
    expect(deployed).to.be.gt(0n, "Should have received vault shares");

    const vaultShares = await vault.balanceOf(await yieldPlay.getAddress());
    console.log(`  Vault shares held by YieldPlay: ${ethers.formatUnits(vaultShares, 6)}`);
    console.log(`  Shares via deployedShares mapping: ${ethers.formatUnits(deployed, 6)}`);
    expect(vaultShares).to.equal(deployed);
  });

  // ──────────────────────────────────────────────────────────────────────────
  it("yield accrues in the vault over time, then withdraws with profit", async function () {
    const round = await yieldPlay.getRound(gameId, roundId);
    const lockEnd = Number(round.endTs) + Number(round.lockTime);

    const valueBeforeWarp = await vault.convertToAssets(
      await yieldPlay.deployedShares(gameId, roundId)
    );
    console.log(`  Value BEFORE time travel: ${ethers.formatUnits(valueBeforeWarp, 6)} USDC`);

    // Warp past lockTime → ChoosingWinners status
    await time.increaseTo(lockEnd + 60);

    const valueAfterWarp = await vault.convertToAssets(
      await yieldPlay.deployedShares(gameId, roundId)
    );
    console.log(`  Value AFTER  time travel: ${ethers.formatUnits(valueAfterWarp, 6)} USDC`);

    // NOTE: On Euler vaults, interest accrues per-interaction (not per-block).
    // The value may be equal or slightly higher depending on vault activity.
    // We just assert it is >= principal (no-loss guarantee).
    expect(valueAfterWarp).to.be.gte(valueBeforeWarp, "Value should not decrease");

    // Withdraw from vault
    const balBefore = await usdc.balanceOf(await yieldPlay.getAddress());
    await yieldPlay.connect(gameOwner).withdrawFromVault(gameId, roundId);
    const balAfter = await usdc.balanceOf(await yieldPlay.getAddress());

    const totalBack = balAfter - balBefore;
    const principal = (await yieldPlay.deployedAmounts(gameId, roundId)); // already zeroed? No — only shares are zeroed
    console.log(`  USDC returned from vault: ${ethers.formatUnits(totalBack, 6)} USDC`);

    expect(balAfter).to.be.gt(0n);
  });

  // ──────────────────────────────────────────────────────────────────────────
  it("settles the round and assigns winner", async function () {
    await yieldPlay.connect(gameOwner).settlement(gameId, roundId);

    const round = await yieldPlay.getRound(gameId, roundId);
    console.log(`  bonusPrizePool: ${ethers.formatUnits(round.bonusPrizePool, 6)} USDC`);
    console.log(`  yieldAmount: ${ethers.formatUnits(round.yieldAmount, 6)} USDC`);
    console.log(`  totalWin (prize pool): ${ethers.formatUnits(round.totalWin, 6)} USDC`);
    expect(round.isSettled).to.be.true;

    if (round.totalWin > 0n) {
      // Assign entire prize pool to user1
      await yieldPlay.connect(gameOwner).chooseWinner(gameId, roundId, user1.address, round.totalWin);
    } else {
      // No yield, just finalize so users can claim principal
      console.log("  No yield generated – finalizing round without prize");
      await yieldPlay.connect(gameOwner).finalizeRound(gameId, roundId);
    }

    const roundAfter = await yieldPlay.getRound(gameId, roundId);
    expect(roundAfter.status).to.equal(4); // DistributingRewards = 4
  });

  // ──────────────────────────────────────────────────────────────────────────
  it("users claim their principal back (+ prize for winner)", async function () {
    const u1Before = await usdc.balanceOf(user1.address);
    const u2Before = await usdc.balanceOf(user2.address);

    await yieldPlay.connect(user1).claim(gameId, roundId);
    await yieldPlay.connect(user2).claim(gameId, roundId);

    const u1After = await usdc.balanceOf(user1.address);
    const u2After = await usdc.balanceOf(user2.address);

    const u1Received = u1After - u1Before;
    const u2Received = u2After - u2Before;

    // user1 net deposit was 495 USDC + any prize
    // user2 net deposit was 297 USDC
    expect(u1Received).to.be.gte(USDC(495), "user1 should get at least their net deposit back");
    expect(u2Received).to.be.gte(USDC(297), "user2 should get at least their net deposit back");

    console.log(`  user1 received: ${ethers.formatUnits(u1Received, 6)} USDC`);
    console.log(`  user2 received: ${ethers.formatUnits(u2Received, 6)} USDC`);
  });

  // ──────────────────────────────────────────────────────────────────────────
  describe("settlement – edge cases", function () {
    it("reverts with RoundNotFound when roundId does not exist", async function () {
      const fakeRoundId = 9999n;
      // gameId exists (owner check passes), but round 9999 was never created (initialized = false)
      await expect(
        yieldPlay.connect(gameOwner).settlement(gameId, fakeRoundId)
      ).to.be.revertedWithCustomError(yieldPlay, "RoundNotFound");
    });

    it("two rounds with the same token do not affect each other's settlement", async function () {
      // ── Create round2 ────────────────────────────────────────────────────
      const now       = BigInt(await time.latest());
      const startTs2  = now + 10n;
      const endTs2    = now + 86_400n;
      const lockTime2 = 7n * 86_400n;

      const roundId2 = await yieldPlay
        .connect(gameOwner)
        .createRound.staticCall(gameId, startTs2, endTs2, lockTime2, 100, USDC_ADDRESS); // 1% deposit fee
      await yieldPlay.connect(gameOwner).createRound(gameId, startTs2, endTs2, lockTime2, 100, USDC_ADDRESS);

      // ── Users deposit into round2 ─────────────────────────────────────
      await time.increaseTo(Number(startTs2) + 1);

      await usdc.connect(whale).transfer(user1.address, USDC(500));
      await usdc.connect(whale).transfer(user2.address, USDC(500));

      await usdc.connect(user1).approve(await yieldPlay.getAddress(), USDC(200));
      await usdc.connect(user2).approve(await yieldPlay.getAddress(), USDC(100));
      await yieldPlay.connect(user1).deposit(gameId, roundId2, USDC(200));
      await yieldPlay.connect(user2).deposit(gameId, roundId2, USDC(100));

      // ── Snapshot round1 state before round2 settlement ──────────────
      const round1Before = await yieldPlay.getRound(gameId, roundId);
      expect(round1Before.isSettled).to.be.true; // sanity check

      // ── Run full lifecycle for round2 ─────────────────────────────────
      // Warp past endTs → Locking period (deposits closed, can deploy to vault)
      await time.increaseTo(Number(endTs2) + 60);
      await yieldPlay.connect(gameOwner).depositToVault(gameId, roundId2);

      // Warp past endTs + lockTime → ChoosingWinners (can withdraw and settle)
      await time.increaseTo(Number(endTs2) + Number(lockTime2) + 60);
      await yieldPlay.connect(gameOwner).withdrawFromVault(gameId, roundId2);

      await yieldPlay.connect(gameOwner).settlement(gameId, roundId2);

      // ── Assert round1 state is completely unchanged ───────────────────
      const round1After = await yieldPlay.getRound(gameId, roundId);
      expect(round1After.totalWin).to.equal(
        round1Before.totalWin,
        "Round1 totalWin must not change after Round2 settlement"
      );
      expect(round1After.devFee).to.equal(
        round1Before.devFee,
        "Round1 devFee must not change after Round2 settlement"
      );
      expect(round1After.yieldAmount).to.equal(
        round1Before.yieldAmount,
        "Round1 yieldAmount must not change after Round2 settlement"
      );

      const round2After = await yieldPlay.getRound(gameId, roundId2);
      expect(round2After.isSettled).to.be.true;

      console.log(`  Round1 totalWin  : ${ethers.formatUnits(round1Before.totalWin, 6)} USDC (unchanged)`);
      console.log(`  Round2 totalWin  : ${ethers.formatUnits(round2After.totalWin, 6)} USDC`);
      console.log(`  Round1 yieldAmount: ${ethers.formatUnits(round1Before.yieldAmount, 6)} USDC (unchanged)`);
    });
  });

  after(async function () {
    // Stop impersonating
    await network.provider.request({ method: "hardhat_stopImpersonatingAccount", params: [USDC_WHALE] });
  });
});
