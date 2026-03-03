import type { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import * as dotenv from "dotenv";

dotenv.config();

const PRIVATE_KEY = process.env.PRIVATE_KEY || "0x0000000000000000000000000000000000000000000000000000000000000001";

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.20",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
      viaIR: true,
    },
  },
  networks: {
    hardhat: {
      forking: {
        url: "https://avalanche.gateway.tenderly.co/5dn7B5iomBLt5oW6FMLllJ",
        blockNumber: 79094077,
      },
    },
    localhost: {
      url: "https://avalanche.gateway.tenderly.co/5dn7B5iomBLt5oW6FMLllJ",
      chainId: 43114,
    },
    sepolia: {
      url: process.env.SEPOLIA_RPC_URL || "",
      accounts: [PRIVATE_KEY],
      chainId: 11155111,
    },
    baseSepolia: {
      url: process.env.BASE_SEPOLIA_RPC_URL || "https://sepolia.base.org",
      accounts: [PRIVATE_KEY],
      chainId: 84532,
    },
    arbitrumSepolia: {
      url: process.env.ARBITRUM_SEPOLIA_RPC_URL || "https://sepolia-rollup.arbitrum.io/rpc",
      accounts: [PRIVATE_KEY],
      chainId: 421614,
    },
    avalancheCChainFork: {
      url: process.env.AVALANCHE_C_CHAIN_RPC_URL || "https://avalanche.gateway.tenderly.co/5dn7B5iomBLt5oW6FMLllJ",
      accounts: [PRIVATE_KEY],
      chainId: 43114,
    },
    fuji: {
      url: "https://api.avax-test.network/ext/bc/C/rpc",
      chainId: 43113,
      accounts: process.env.MNEMONIC ? { mnemonic: process.env.MNEMONIC } : [PRIVATE_KEY],
    },
    chainA: {
      url: "http://127.0.0.1:9654/ext/bc/27Kd7ibmo2HWSYG4gnoZ164hQQ8CuCgeunan7qpd3TfqRivKiy/rpc",
      chainId: 1112,
      accounts: ["0x56289e99c94b6912bfc12adc093c9b51124f0dc54ac7a766b2bc5ccf558d8027"],
    },
    chainC: {
      url: "http://127.0.0.1:9658/ext/bc/QPbg4eCHLkjnbw6U9PgD7vzX8EEcCD8C347osKjoLmvT13MWn/rpc",
      chainId: 11113,
      accounts: ["0x56289e99c94b6912bfc12adc093c9b51124f0dc54ac7a766b2bc5ccf558d8027"],
    },
  },
  etherscan: {
    apiKey: {
      sepolia: process.env.ETHERSCAN_API_KEY || "",
      baseSepolia: process.env.BASESCAN_API_KEY || "",
      arbitrumSepolia: process.env.ARBISCAN_API_KEY || "",
    },
    customChains: [
      {
        network: "baseSepolia",
        chainId: 84532,
        urls: {
          apiURL: "https://api-sepolia.basescan.org/api",
          browserURL: "https://sepolia.basescan.org",
        },
      },
    ],
  },
  gasReporter: {
    enabled: process.env.REPORT_GAS === "true",
    currency: "USD",
    coinmarketcap: process.env.COINMARKETCAP_API_KEY,
  },
  paths: {
    sources: "./contracts",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts",
  },
};

export default config;
