import {
  ethers,
  Contract,
  Signer,
  Provider,
  TransactionReceipt,
  ContractTransactionResponse,
} from "ethers";

// ============ Types ============

export interface SDKConfig {
  /** YieldPlay contract address */
  yieldPlayAddress: string;
  /** Ethers signer for transactions */
  signer: Signer;
  /** Optional provider (defaults to signer's provider) */
  provider?: Provider;
}

export interface DepositParams {
  /** Game identifier (bytes32) */
  gameId: string;
  /** Round identifier */
  roundId: bigint | number;
  /** Amount to deposit (in token's smallest unit) */
  amount: bigint | string;
}

export interface ClaimParams {
  /** Game identifier (bytes32) */
  gameId: string;
  /** Round identifier */
  roundId: bigint | number;
}

export interface CreateGameParams {
  /** Unique name for the game */
  gameName: string;
  /** Developer fee in basis points (max 10000) */
  devFeeBps: number;
  /** Address to receive developer fees */
  treasury: string;
}

export interface CreateRoundParams {
  /** Game identifier (bytes32) */
  gameId: string;
  /** Round start timestamp (unix seconds) */
  startTs: bigint | number;
  /** Round end timestamp (unix seconds) */
  endTs: bigint | number;
  /** Additional lock period in seconds */
  lockTime: bigint | number;
  /** Deposit fee in basis points (max 1000 = 10%) */
  depositFeeBps: number;
  /** ERC20 token address for deposits */
  paymentToken: string;
}

export interface ChooseWinnerParams {
  /** Game identifier (bytes32) */
  gameId: string;
  /** Round identifier */
  roundId: bigint | number;
  /** Winner address */
  winner: string;
  /** Prize amount to assign */
  amount: bigint | string;
}

export interface GameInfo {
  owner: string;
  gameName: string;
  devFeeBps: bigint;
  treasury: string;
  roundCounter: bigint;
  initialized: boolean;
}

export interface RoundInfo {
  gameId: string;
  roundId: bigint;
  totalDeposit: bigint;
  bonusPrizePool: bigint;
  devFee: bigint;
  totalWin: bigint;
  yieldAmount: bigint;
  paymentToken: string;
  vault: string;
  depositFeeBps: bigint;
  startTs: bigint;
  endTs: bigint;
  lockTime: bigint;
  initialized: boolean;
  isSettled: boolean;
  status: bigint;
  isWithdrawn: boolean;
}

export interface UserDepositInfo {
  depositAmount: bigint;
  amountToClaim: bigint;
  isClaimed: boolean;
  exists: boolean;
}

export enum RoundStatus {
  NotStarted = 0,
  InProgress = 1,
  Locking = 2,
  ChoosingWinners = 3,
  DistributingRewards = 4,
}

export interface TransactionResult {
  hash: string;
  receipt: TransactionReceipt | null;
}

// ============ ABI ============

const YIELD_PLAY_ABI = [
  // Read functions
  "function games(bytes32) view returns (address owner, string gameName, uint16 devFeeBps, address treasury, uint256 roundCounter, bool initialized)",
  "function rounds(bytes32, uint256) view returns (bytes32 gameId, uint256 roundId, uint256 totalDeposit, uint256 bonusPrizePool, uint256 devFee, uint256 totalWin, uint256 yieldAmount, address paymentToken, address vault, uint16 depositFeeBps, uint64 startTs, uint64 endTs, uint64 lockTime, bool initialized, bool isSettled, uint8 status, bool isWithdrawn)",
  "function userDeposits(bytes32, uint256, address) view returns (uint256 depositAmount, uint256 amountToClaim, bool isClaimed, bool exists)",
  "function vaults(address) view returns (address)",
  "function getGame(bytes32 gameId) view returns (tuple(address owner, string gameName, uint16 devFeeBps, address treasury, uint256 roundCounter, bool initialized))",
  "function getRound(bytes32 gameId, uint256 roundId) view returns (tuple(bytes32 gameId, uint256 roundId, uint256 totalDeposit, uint256 bonusPrizePool, uint256 devFee, uint256 totalWin, uint256 yieldAmount, address paymentToken, address vault, uint16 depositFeeBps, uint64 startTs, uint64 endTs, uint64 lockTime, bool initialized, bool isSettled, uint8 status, bool isWithdrawn))",
  "function getUserDeposit(bytes32 gameId, uint256 roundId, address user) view returns (tuple(uint256 depositAmount, uint256 amountToClaim, bool isClaimed, bool exists))",
  "function getCurrentStatus(bytes32 gameId, uint256 roundId) view returns (uint8)",
  "function calculateGameId(address owner, string gameName) pure returns (bytes32)",
  "function protocolTreasury() view returns (address)",
  "function owner() view returns (address)",
  "function paused() view returns (bool)",
  "function deployedAmounts(bytes32, uint256) view returns (uint256)",
  "function deployedShares(bytes32, uint256) view returns (uint256)",
  "function PERFORMANCE_FEE_BPS() view returns (uint256)",
  "function BPS_DENOMINATOR() view returns (uint256)",
  // Write functions
  "function deposit(bytes32 gameId, uint256 roundId, uint256 amount)",
  "function claim(bytes32 gameId, uint256 roundId)",
  "function createGame(string gameName, uint16 devFeeBps, address treasury) returns (bytes32)",
  "function createRound(bytes32 gameId, uint64 startTs, uint64 endTs, uint64 lockTime, uint16 depositFeeBps, address paymentToken) returns (uint256)",
  "function depositToVault(bytes32 gameId, uint256 roundId)",
  "function withdrawFromVault(bytes32 gameId, uint256 roundId)",
  "function settlement(bytes32 gameId, uint256 roundId)",
  "function chooseWinner(bytes32 gameId, uint256 roundId, address winner, uint256 amount)",
  "function finalizeRound(bytes32 gameId, uint256 roundId)",
  "function updateRoundStatus(bytes32 gameId, uint256 roundId)",
  // Events
  "event Deposited(bytes32 indexed gameId, uint256 indexed roundId, address indexed user, uint256 amount, uint256 depositFee)",
  "event Claimed(bytes32 indexed gameId, uint256 indexed roundId, address indexed user, uint256 principal, uint256 prize)",
  "event GameCreated(bytes32 indexed gameId, address indexed owner, string gameName, uint16 devFeeBps)",
  "event RoundCreated(bytes32 indexed gameId, uint256 indexed roundId, uint64 startTs, uint64 endTs, uint64 lockTime, uint16 depositFeeBps, address paymentToken, address vault)",
  "event FundsDeployed(bytes32 indexed gameId, uint256 indexed roundId, uint256 amount, uint256 shares)",
  "event FundsWithdrawn(bytes32 indexed gameId, uint256 indexed roundId, uint256 principal, uint256 yield)",
  "event RoundSettled(bytes32 indexed gameId, uint256 indexed roundId, uint256 totalYield, uint256 performanceFee, uint256 devFee, uint256 prizePool)",
  "event WinnerChosen(bytes32 indexed gameId, uint256 indexed roundId, address indexed winner, uint256 amount)",
];

const ERC20_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function decimals() view returns (uint8)",
  "function symbol() view returns (string)",
  "function name() view returns (string)",
];

// ============ SDK Class ============

/**
 * YieldPlay SDK - Simplified interface for backend integration
 * 
 * @example
 * ```typescript
 * import { YieldPlaySDK } from './sdk';
 * import { ethers } from 'ethers';
 * 
 * const provider = new ethers.JsonRpcProvider('https://rpc.example.com');
 * const signer = new ethers.Wallet(privateKey, provider);
 * 
 * const sdk = new YieldPlaySDK({
 *   yieldPlayAddress: '0x...',
 *   signer,
 * });
 * 
 * // Deposit tokens
 * await sdk.deposit({
 *   gameId: '0x...',
 *   roundId: 1,
 *   amount: ethers.parseUnits('100', 18),
 * });
 * ```
 */
export class YieldPlaySDK {
  private contract: Contract;
  private signer: Signer;
  private provider: Provider;
  public readonly yieldPlayAddress: string;

  constructor(config: SDKConfig) {
    this.yieldPlayAddress = config.yieldPlayAddress;
    this.signer = config.signer;
    
    const signerProvider = config.signer.provider;
    if (!signerProvider && !config.provider) {
      throw new Error("Provider is required. Either pass a provider or use a signer with a provider.");
    }
    this.provider = config.provider || signerProvider!;
    
    this.contract = new Contract(
      config.yieldPlayAddress,
      YIELD_PLAY_ABI,
      config.signer
    );
  }

  // ============ User Actions ============

  /**
   * Deposit tokens into a round
   * Automatically handles ERC20 approval if needed
   * 
   * @param params - Deposit parameters
   * @returns Transaction result with hash and receipt
   */
  async deposit(params: DepositParams): Promise<TransactionResult> {
    const { gameId, roundId, amount } = params;
    const amountBigInt = BigInt(amount);

    // Get round info to find payment token
    const round = await this.getRound(gameId, BigInt(roundId));
    if (!round.initialized) {
      throw new Error("Round not found");
    }

    // Check and approve token if needed
    await this.ensureAllowance(round.paymentToken, amountBigInt);

    // Execute deposit
    const tx: ContractTransactionResponse = await this.contract.deposit(
      gameId,
      roundId,
      amountBigInt
    );
    const receipt = await tx.wait();

    return {
      hash: tx.hash,
      receipt,
    };
  }

  /**
   * Claim principal and any winnings after round completion
   * 
   * @param params - Claim parameters
   * @returns Transaction result with hash and receipt
   */
  async claim(params: ClaimParams): Promise<TransactionResult> {
    const { gameId, roundId } = params;

    const tx: ContractTransactionResponse = await this.contract.claim(
      gameId,
      roundId
    );
    const receipt = await tx.wait();

    return {
      hash: tx.hash,
      receipt,
    };
  }

  // ============ Game Management ============

  /**
   * Create a new game
   * 
   * @param params - Game creation parameters
   * @returns Transaction result and the created gameId
   */
  async createGame(params: CreateGameParams): Promise<TransactionResult & { gameId: string }> {
    const { gameName, devFeeBps, treasury } = params;

    const tx: ContractTransactionResponse = await this.contract.createGame(
      gameName,
      devFeeBps,
      treasury
    );
    const receipt = await tx.wait();

    // Extract gameId from event
    let gameId = "";
    if (receipt) {
      const event = receipt.logs.find((log) => {
        try {
          const parsed = this.contract.interface.parseLog(log);
          return parsed?.name === "GameCreated";
        } catch {
          return false;
        }
      });
      if (event) {
        const parsed = this.contract.interface.parseLog(event);
        gameId = parsed?.args?.gameId || "";
      }
    }

    // Fallback: calculate gameId
    if (!gameId) {
      const signerAddress = await this.signer.getAddress();
      gameId = await this.calculateGameId(signerAddress, gameName);
    }

    return {
      hash: tx.hash,
      receipt,
      gameId,
    };
  }

  /**
   * Create a new round for a game
   * 
   * @param params - Round creation parameters
   * @returns Transaction result and the created roundId
   */
  async createRound(params: CreateRoundParams): Promise<TransactionResult & { roundId: bigint }> {
    const { gameId, startTs, endTs, lockTime, depositFeeBps, paymentToken } = params;

    const tx: ContractTransactionResponse = await this.contract.createRound(
      gameId,
      startTs,
      endTs,
      lockTime,
      depositFeeBps,
      paymentToken
    );
    const receipt = await tx.wait();

    // Extract roundId from event
    let roundId = 0n;
    if (receipt) {
      const event = receipt.logs.find((log) => {
        try {
          const parsed = this.contract.interface.parseLog(log);
          return parsed?.name === "RoundCreated";
        } catch {
          return false;
        }
      });
      if (event) {
        const parsed = this.contract.interface.parseLog(event);
        roundId = parsed?.args?.roundId || 0n;
      }
    }

    return {
      hash: tx.hash,
      receipt,
      roundId,
    };
  }

  // ============ Game Owner Actions ============

  /**
   * Deploy round funds to ERC4626 vault
   * 
   * @param gameId - Game identifier
   * @param roundId - Round identifier
   * @returns Transaction result
   */
  async depositToVault(gameId: string, roundId: bigint | number): Promise<TransactionResult> {
    const tx: ContractTransactionResponse = await this.contract.depositToVault(
      gameId,
      roundId
    );
    const receipt = await tx.wait();

    return {
      hash: tx.hash,
      receipt,
    };
  }

  /**
   * Withdraw funds from ERC4626 vault
   * 
   * @param gameId - Game identifier
   * @param roundId - Round identifier
   * @returns Transaction result
   */
  async withdrawFromVault(gameId: string, roundId: bigint | number): Promise<TransactionResult> {
    const tx: ContractTransactionResponse = await this.contract.withdrawFromVault(
      gameId,
      roundId
    );
    const receipt = await tx.wait();

    return {
      hash: tx.hash,
      receipt,
    };
  }

  /**
   * Settle the round - calculate and distribute fees
   * 
   * @param gameId - Game identifier
   * @param roundId - Round identifier
   * @returns Transaction result
   */
  async settlement(gameId: string, roundId: bigint | number): Promise<TransactionResult> {
    const tx: ContractTransactionResponse = await this.contract.settlement(
      gameId,
      roundId
    );
    const receipt = await tx.wait();

    return {
      hash: tx.hash,
      receipt,
    };
  }

  /**
   * Choose a winner and assign prize amount
   * 
   * @param params - Winner selection parameters
   * @returns Transaction result
   */
  async chooseWinner(params: ChooseWinnerParams): Promise<TransactionResult> {
    const { gameId, roundId, winner, amount } = params;

    const tx: ContractTransactionResponse = await this.contract.chooseWinner(
      gameId,
      roundId,
      winner,
      amount
    );
    const receipt = await tx.wait();

    return {
      hash: tx.hash,
      receipt,
    };
  }

  /**
   * Finalize round and allow claims
   * 
   * @param gameId - Game identifier
   * @param roundId - Round identifier
   * @returns Transaction result
   */
  async finalizeRound(gameId: string, roundId: bigint | number): Promise<TransactionResult> {
    const tx: ContractTransactionResponse = await this.contract.finalizeRound(
      gameId,
      roundId
    );
    const receipt = await tx.wait();

    return {
      hash: tx.hash,
      receipt,
    };
  }

  // ============ View Functions ============

  /**
   * Get game details
   * 
   * @param gameId - Game identifier
   * @returns Game information
   */
  async getGame(gameId: string): Promise<GameInfo> {
    const result = await this.contract.getGame(gameId);
    return {
      owner: result.owner,
      gameName: result.gameName,
      devFeeBps: result.devFeeBps,
      treasury: result.treasury,
      roundCounter: result.roundCounter,
      initialized: result.initialized,
    };
  }

  /**
   * Get round details
   * 
   * @param gameId - Game identifier
   * @param roundId - Round identifier
   * @returns Round information
   */
  async getRound(gameId: string, roundId: bigint | number): Promise<RoundInfo> {
    const result = await this.contract.getRound(gameId, roundId);
    return {
      gameId: result.gameId,
      roundId: result.roundId,
      totalDeposit: result.totalDeposit,
      bonusPrizePool: result.bonusPrizePool,
      devFee: result.devFee,
      totalWin: result.totalWin,
      yieldAmount: result.yieldAmount,
      paymentToken: result.paymentToken,
      vault: result.vault,
      depositFeeBps: result.depositFeeBps,
      startTs: result.startTs,
      endTs: result.endTs,
      lockTime: result.lockTime,
      initialized: result.initialized,
      isSettled: result.isSettled,
      status: result.status,
      isWithdrawn: result.isWithdrawn,
    };
  }

  /**
   * Get user deposit details
   * 
   * @param gameId - Game identifier
   * @param roundId - Round identifier
   * @param user - User address
   * @returns User deposit information
   */
  async getUserDeposit(
    gameId: string,
    roundId: bigint | number,
    user: string
  ): Promise<UserDepositInfo> {
    const result = await this.contract.getUserDeposit(gameId, roundId, user);
    return {
      depositAmount: result.depositAmount,
      amountToClaim: result.amountToClaim,
      isClaimed: result.isClaimed,
      exists: result.exists,
    };
  }

  /**
   * Get current round status
   * 
   * @param gameId - Game identifier
   * @param roundId - Round identifier  
   * @returns Current round status
   */
  async getCurrentStatus(gameId: string, roundId: bigint | number): Promise<RoundStatus> {
    const status = await this.contract.getCurrentStatus(gameId, roundId);
    return Number(status) as RoundStatus;
  }

  /**
   * Calculate game ID from owner and name
   * 
   * @param owner - Game owner address
   * @param gameName - Game name
   * @returns Calculated game ID (bytes32)
   */
  async calculateGameId(owner: string, gameName: string): Promise<string> {
    return await this.contract.calculateGameId(owner, gameName);
  }

  /**
   * Get vault address for a payment token
   * 
   * @param token - Payment token address
   * @returns Vault address (or zero address if not set)
   */
  async getVault(token: string): Promise<string> {
    return await this.contract.vaults(token);
  }

  /**
   * Check if the contract is paused
   * 
   * @returns True if paused
   */
  async isPaused(): Promise<boolean> {
    return await this.contract.paused();
  }

  /**
   * Get protocol treasury address
   * 
   * @returns Treasury address
   */
  async getProtocolTreasury(): Promise<string> {
    return await this.contract.protocolTreasury();
  }

  /**
   * Get deployed amounts for a round
   * 
   * @param gameId - Game identifier
   * @param roundId - Round identifier
   * @returns Amount deployed to vault
   */
  async getDeployedAmounts(gameId: string, roundId: bigint | number): Promise<bigint> {
    return await this.contract.deployedAmounts(gameId, roundId);
  }

  /**
   * Get deployed shares for a round
   * 
   * @param gameId - Game identifier
   * @param roundId - Round identifier
   * @returns Shares received from vault
   */
  async getDeployedShares(gameId: string, roundId: bigint | number): Promise<bigint> {
    return await this.contract.deployedShares(gameId, roundId);
  }

  // ============ Token Utilities ============

  /**
   * Get ERC20 token balance for an address
   * 
   * @param tokenAddress - Token contract address
   * @param userAddress - User address (defaults to signer)
   * @returns Token balance
   */
  async getTokenBalance(tokenAddress: string, userAddress?: string): Promise<bigint> {
    const address = userAddress || (await this.signer.getAddress());
    const token = new Contract(tokenAddress, ERC20_ABI, this.provider);
    return await token.balanceOf(address);
  }

  /**
   * Get ERC20 token allowance
   * 
   * @param tokenAddress - Token contract address
   * @param ownerAddress - Token owner address (defaults to signer)
   * @returns Allowance amount for YieldPlay contract
   */
  async getTokenAllowance(tokenAddress: string, ownerAddress?: string): Promise<bigint> {
    const address = ownerAddress || (await this.signer.getAddress());
    const token = new Contract(tokenAddress, ERC20_ABI, this.provider);
    return await token.allowance(address, this.yieldPlayAddress);
  }

  /**
   * Approve token spending for YieldPlay contract
   * 
   * @param tokenAddress - Token contract address
   * @param amount - Amount to approve (use MaxUint256 for unlimited)
   * @returns Transaction result
   */
  async approveToken(
    tokenAddress: string,
    amount: bigint | string = ethers.MaxUint256
  ): Promise<TransactionResult> {
    const token = new Contract(tokenAddress, ERC20_ABI, this.signer);
    const tx: ContractTransactionResponse = await token.approve(
      this.yieldPlayAddress,
      amount
    );
    const receipt = await tx.wait();

    return {
      hash: tx.hash,
      receipt,
    };
  }

  // ============ Helper Methods ============

  /**
   * Ensure sufficient allowance for deposit
   * Approves max uint256 if current allowance is insufficient
   * 
   * @param tokenAddress - Token contract address
   * @param amount - Required amount
   */
  private async ensureAllowance(tokenAddress: string, amount: bigint): Promise<void> {
    const currentAllowance = await this.getTokenAllowance(tokenAddress);
    
    if (currentAllowance < amount) {
      // Approve max uint256 for convenience
      await this.approveToken(tokenAddress, ethers.MaxUint256);
    }
  }

  /**
   * Get the underlying contract instance for advanced usage
   * 
   * @returns Ethers Contract instance
   */
  getContract(): Contract {
    return this.contract;
  }

  /**
   * Update signer (e.g., when user changes account)
   * 
   * @param newSigner - New signer instance
   */
  updateSigner(newSigner: Signer): void {
    this.signer = newSigner;
    this.contract = new Contract(
      this.yieldPlayAddress,
      YIELD_PLAY_ABI,
      newSigner
    );
    
    const signerProvider = newSigner.provider;
    if (signerProvider) {
      this.provider = signerProvider;
    }
  }
}

// ============ Factory Function ============

/**
 * Create a new YieldPlaySDK instance
 * 
 * @param config - SDK configuration
 * @returns Configured SDK instance
 * 
 * @example
 * ```typescript
 * const sdk = createYieldPlaySDK({
 *   yieldPlayAddress: '0x...',
 *   signer: wallet,
 * });
 * ```
 */
export function createYieldPlaySDK(config: SDKConfig): YieldPlaySDK {
  return new YieldPlaySDK(config);
}

// ============ Default Export ============

export default YieldPlaySDK;
