import { ethers } from "hardhat";

/**
 * Deploy YieldPlay to Sepolia testnet
 * 
 * Prerequisites:
 * 1. Create .env file with:
 *    - PRIVATE_KEY=your_private_key
 *    - SEPOLIA_RPC_URL=https://ethereum-sepolia-rpc.publicnode.com
 * 
 * 2. Sepolia ETH for gas
 * 
 * Run: npx hardhat run scripts/deploySepolia.ts --network sepolia
 */

// Vault: Aave USDC vault on Sepolia
const VAULT_ADDRESS = "0xf323aEa80bF9962e26A3499a4Ffd70205590F54d";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("=".repeat(60));
  console.log("Deploying YieldPlay to Sepolia Testnet");
  console.log("=".repeat(60));
  console.log("\nDeployer address:", deployer.address);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("Account balance:", ethers.formatEther(balance), "ETH");

  if (balance === 0n) {
    throw new Error("No ETH balance! Please fund your account with Sepolia ETH from a faucet.");
  }

  // Get vault's underlying asset
  console.log("\n--- Checking Vault ---");
  const vault = await ethers.getContractAt("IERC4626", VAULT_ADDRESS);
  
  let underlyingToken: string;
  try {
    underlyingToken = await vault.asset();
    console.log("Vault address:", VAULT_ADDRESS);
    console.log("Underlying token:", underlyingToken);
  } catch (error) {
    console.log("Warning: Could not read vault asset. Proceeding anyway...");
    // Default to common USDC on Sepolia
    underlyingToken = "0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8"; // USDC on Sepolia
  }

  // Deploy YieldPlay
  console.log("\n--- Deploying YieldPlay ---");
  const protocolTreasury = deployer.address;
  
  const YieldPlay = await ethers.getContractFactory("YieldPlay");
  console.log("Deploying...");
  
  const yieldPlay = await YieldPlay.deploy(protocolTreasury);
  await yieldPlay.waitForDeployment();
  
  const yieldPlayAddress = await yieldPlay.getAddress();
  console.log("YieldPlay deployed to:", yieldPlayAddress);

  // Configure vault for the token
  console.log("\n--- Configuring Vault ---");
  console.log(`Setting vault ${VAULT_ADDRESS} for token ${underlyingToken}...`);
  
  const tx = await yieldPlay.setVault(underlyingToken, VAULT_ADDRESS);
  console.log("Transaction hash:", tx.hash);
  await tx.wait();
  console.log("Vault configured successfully!");

  // Print summary
  console.log("\n" + "=".repeat(60));
  console.log("DEPLOYMENT COMPLETE");
  console.log("=".repeat(60));
  console.log("\nContract Addresses:");
  console.log("  YieldPlay:", yieldPlayAddress);
  console.log("  Vault:", VAULT_ADDRESS);
  console.log("  Token:", underlyingToken);
  console.log("  Treasury:", protocolTreasury);

  console.log("\n--- Verification Command ---");
  console.log(`npx hardhat verify --network sepolia ${yieldPlayAddress} ${protocolTreasury}`);

  console.log("\n--- SDK Configuration ---");
  console.log(`const YIELD_PLAY_ADDRESS = "${yieldPlayAddress}";`);
  console.log(`const RPC_URL = "https://ethereum-sepolia-rpc.publicnode.com";`);

  console.log("\n--- Etherscan Link ---");
  console.log(`https://sepolia.etherscan.io/address/${yieldPlayAddress}`);

  return {
    yieldPlay: yieldPlayAddress,
    vault: VAULT_ADDRESS,
    token: underlyingToken,
    treasury: protocolTreasury,
  };
}

main()
  .then((result) => {
    console.log("\n✅ Deployment successful!");
    process.exit(0);
  })
  .catch((error) => {
    console.error("\n❌ Deployment failed:", error);
    process.exit(1);
  });
