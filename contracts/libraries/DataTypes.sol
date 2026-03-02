// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title RoundStatus
 * @notice Enum defining the lifecycle states of a game round
 */
enum RoundStatus {
    NotStarted,          // 0: Round created but not yet active
    InProgress,          // 1: Deposits are accepted
    Locking,             // 2: Deposits closed, funds in yield strategy
    ChoosingWinners,     // 3: Yield withdrawn, ready for winner selection
    DistributingRewards  // 4: Winners chosen, claims open
}

/**
 * @title Game
 * @notice Struct representing a game configuration
 */
struct Game {
    address owner;           // Game creator/admin
    string gameName;         // Unique identifier
    uint16 devFeeBps;        // Developer fee in basis points (max 10000)
    address treasury;        // Treasury address for dev fees
    uint256 roundCounter;    // Auto-incrementing round ID
    bool initialized;        // Initialization flag
}

/**
 * @title Round
 * @notice Struct representing a game round
 */
struct Round {
    bytes32 gameId;          // Parent game identifier
    uint256 roundId;         // Unique round identifier
    uint256 totalDeposit;    // Sum of all deposits (after fee deduction)
    uint256 bonusPrizePool;  // Accumulated deposit fees for prize pool
    uint256 devFee;          // Accumulated dev fees
    uint256 totalWin;        // Remaining prize pool to distribute
    uint256 yieldAmount;     // Total yield generated from vault
    address paymentToken;    // Accepted ERC20 token for this round
    address vault;           // ERC4626 vault for this round
    uint16 depositFeeBps;    // Deposit fee in basis points - goes to prize pool
    uint64 startTs;          // Round start timestamp
    uint64 endTs;            // Round end timestamp (deposits close)
    uint64 lockTime;         // Additional lock period after end
    bool initialized;        // Whether the round has been initialized
    bool isSettled;          // Settlement completed flag
    RoundStatus status;      // Current round status
    bool isWithdrawn;        // Whether funds have been withdrawn from vault
}

/**
 * @title UserDeposit
 * @notice Struct tracking a user's deposit in a round
 */
struct UserDeposit {
    uint256 depositAmount;   // User's total deposit
    uint256 amountToClaim;   // Prize winnings assigned
    bool isClaimed;          // Whether user has claimed
    bool exists;             // Existence flag for mapping checks
}
