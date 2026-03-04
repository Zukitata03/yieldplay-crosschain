// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {Game, Round, UserDeposit, RoundStatus} from "./libraries/DataTypes.sol";
import {Errors} from "./libraries/Errors.sol";

/**
 * @title YieldPlay
 * @author No-Loss Protocol Team
 * @notice A no-loss prize game protocol where depositors' funds generate yield
 *         that is distributed to selected winners while principals are returned.
 * @dev This contract manages multiple games, each with multiple rounds.
 *      Funds are deployed to ERC4626 vaults to generate yield during the lock period.
 */
contract YieldPlay is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    // ============ Constants ============
    
    /// @notice Performance fee rate (20% = 2000 bps)
    uint256 public constant PERFORMANCE_FEE_BPS = 2000;
    
    /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10000;

    // ============ State Variables ============
    
    /// @notice Protocol admin treasury for performance fees
    address public protocolTreasury;
    
    /// @notice Mapping from gameId to Game struct
    mapping(bytes32 => Game) public games;
    
    /// @notice Mapping from gameId => roundId => Round struct
    mapping(bytes32 => mapping(uint256 => Round)) public rounds;
    
    /// @notice Mapping from gameId => roundId => user => UserDeposit
    mapping(bytes32 => mapping(uint256 => mapping(address => UserDeposit))) public userDeposits;
    
    /// @notice Mapping from payment token => ERC4626 vault
    mapping(address => address) public vaults;
    
    /// @notice Mapping from gameId => roundId => deposited amount to vault
    mapping(bytes32 => mapping(uint256 => uint256)) public deployedAmounts;
    
    /// @notice Mapping from gameId => roundId => vault shares received
    mapping(bytes32 => mapping(uint256 => uint256)) public deployedShares;

    /// @notice Address of YieldPlayReceiver allowed to call depositOnBehalf / claimOnBehalf.
 
    address public immutable crossChainReceiver;



    /// @notice Per-round token reserves.  Tracks tokens actually held for each round so
    ///         one round's shortfall cannot consume another round's principal.
    /// @dev Keyed by gameId => roundId => reserved token balance
    mapping(bytes32 => mapping(uint256 => uint256)) public roundReserves;



    /// @notice Accrued protocol performance fees per token, redeemable by protocolTreasury.
    mapping(address => uint256) public accruedProtocolFees;

    /// @notice Accrued dev fees per game, redeemable by the game owner's treasury.
    mapping(bytes32 => uint256) public accruedDevFees;

    // ============ Events ============
    
    event GameCreated(
        bytes32 indexed gameId,
        address indexed owner,
        string gameName,
        uint16 devFeeBps
    );
    
    event RoundCreated(
        bytes32 indexed gameId,
        uint256 indexed roundId,
        uint64 startTs,
        uint64 endTs,
        uint64 lockTime,
        uint16 depositFeeBps,
        address paymentToken,
        address vault
    );
    
    event Deposited(
        bytes32 indexed gameId,
        uint256 indexed roundId,
        address indexed user,
        uint256 amount,
        uint256 depositFee
    );
    
    event FundsDeployed(
        bytes32 indexed gameId,
        uint256 indexed roundId,
        uint256 amount,
        uint256 shares
    );
    
    event FundsWithdrawn(
        bytes32 indexed gameId,
        uint256 indexed roundId,
        uint256 principal,
        uint256 yield
    );
    
    event RoundSettled(
        bytes32 indexed gameId,
        uint256 indexed roundId,
        uint256 totalYield,
        uint256 performanceFee,
        uint256 devFee,
        uint256 prizePool
    );
    
    event WinnerChosen(
        bytes32 indexed gameId,
        uint256 indexed roundId,
        address indexed winner,
        uint256 amount
    );
    
    event Claimed(
        bytes32 indexed gameId,
        uint256 indexed roundId,
        address indexed user,
        uint256 principal,
        uint256 prize
    );

    event ClaimConfirmed(
        bytes32 indexed gameId,
        uint256 indexed roundId,
        address indexed user
    );

    event ClaimRolledBack(
        bytes32 indexed gameId,
        uint256 indexed roundId,
        address indexed user
    );

    event ProtocolFeesWithdrawn(address indexed token, uint256 amount);
    event DevFeesWithdrawn(bytes32 indexed gameId, uint256 amount);
    
    event VaultUpdated(address indexed token, address indexed vault);
    event ProtocolTreasuryUpdated(address indexed newTreasury);

    // ============ Constructor ============
    
    /**
     * @notice Initialize the YieldPlay protocol
     * @param _protocolTreasury  Address to receive protocol performance fees
     * @param _crossChainReceiver Address of YieldPlayReceiver on this chain (immutable)
     */
    constructor(address _protocolTreasury, address _crossChainReceiver) Ownable(msg.sender) {
        if (_protocolTreasury == address(0)) revert Errors.ZeroAddress();
        if (_crossChainReceiver == address(0)) revert Errors.ZeroAddress();
        protocolTreasury = _protocolTreasury;
        crossChainReceiver = _crossChainReceiver;
    }

    // ============ Admin Functions ============
    
    /**
     * @notice Set the ERC4626 vault for a specific token
     * @param token ERC20 token address (underlying asset)
     * @param vault ERC4626 vault address
     */
    function setVault(address token, address vault) external onlyOwner {
        if (token == address(0)) revert Errors.ZeroAddress();
        if (vault != address(0)) {
            // Verify vault's underlying asset matches token
            if (IERC4626(vault).asset() != token) revert Errors.InvalidPaymentToken();
        }
        vaults[token] = vault;
        emit VaultUpdated(token, vault);
    }
    
    /**
     * @notice Update the protocol treasury address
     * @param newTreasury New treasury address
     */
    function setProtocolTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert Errors.ZeroAddress();
        protocolTreasury = newTreasury;
        emit ProtocolTreasuryUpdated(newTreasury);
    }
    
    /**
     * @notice Pause the protocol
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    /**
     * @notice Unpause the protocol
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // ============ Pull-based fee withdrawal ============

    /**
     * @notice Withdraw accrued protocol performance fees for a given token.
     * @dev Only callable by anyone — sends to protocolTreasury directly.
     *      Pull-based model removes the DoS vector from settlement().
     * @param token The payment token whose fees to withdraw
     */
    function withdrawProtocolFees(address token) external nonReentrant {
        uint256 amount = accruedProtocolFees[token];
        if (amount == 0) revert Errors.InvalidAmount();
        accruedProtocolFees[token] = 0;
        IERC20(token).safeTransfer(protocolTreasury, amount);
        emit ProtocolFeesWithdrawn(token, amount);
    }

    /**
     * @notice Withdraw accrued dev fees for a game.
     * @dev Only callable by the game owner. Pull-based to avoid settlement DoS.
     * @param gameId The game whose dev fees to withdraw
     */
    function withdrawDevFees(bytes32 gameId) external nonReentrant {
        Game storage game = games[gameId];
        if (!game.initialized) revert Errors.GameNotFound();
        if (msg.sender != game.owner) revert Errors.Unauthorized();

        uint256 amount = accruedDevFees[gameId];
        if (amount == 0) revert Errors.InvalidAmount();

        // Determine token from the most recent round
        address token = _latestPaymentToken(gameId, game.roundCounter);
        accruedDevFees[gameId] = 0;
        IERC20(token).safeTransfer(game.treasury, amount);
        emit DevFeesWithdrawn(gameId, amount);
    }

    /**
     * @notice Deposit on behalf of a user who initiated a cross-chain deposit.
     * @dev Called exclusively by YieldPlayReceiver after verifying the Teleporter message.
     *      Tokens must already be in this contract (transferred by YieldPlayReceiver).
     * @param gameId  Target game
     * @param roundId Target round
     * @param user    Original depositor address on the source chain
     * @param amount  Nominal amount (actual received is measured via balance delta)
     */
    function depositOnBehalf(
        bytes32 gameId,
        uint256 roundId,
        address user,
        uint256 amount
    ) external nonReentrant whenNotPaused {
        if (msg.sender != crossChainReceiver) revert Errors.UnauthorizedCrossChainCaller();
        if (amount == 0) revert Errors.InvalidAmount();

        Game storage game = games[gameId];
        Round storage round = rounds[gameId][roundId];

        if (!game.initialized) revert Errors.GameNotFound();

        updateRoundStatus(gameId, roundId);
        if (round.status != RoundStatus.InProgress) revert Errors.RoundNotActive();

        // Measure actual tokens received (handles fee-on-transfer tokens)
        uint256 preBal = IERC20(round.paymentToken).balanceOf(address(this));
        IERC20(round.paymentToken).safeTransferFrom(msg.sender, address(this), amount);
        uint256 actualAmount = IERC20(round.paymentToken).balanceOf(address(this)) - preBal;

        // Calculate deposit fee (goes to bonus prize pool)
        uint256 depositFee = (actualAmount * round.depositFeeBps) / BPS_DENOMINATOR;
        uint256 netDeposit = actualAmount - depositFee;

        round.totalDeposit += netDeposit;
        round.bonusPrizePool += depositFee;

        // Track per-round reserves
        roundReserves[gameId][roundId] += actualAmount;

        UserDeposit storage userDep = userDeposits[gameId][roundId][user];
        userDep.depositAmount += netDeposit;
        userDep.exists = true;

        emit Deposited(gameId, roundId, user, netDeposit, depositFee);
    }

    // ============ Two-phase cross-chain claim confirmation ============

    /**
     * @notice Called by YieldPlayReceiver to confirm that the source-chain payout
     *         succeeded. Transitions claimPending -> isClaimed.
     * @param gameId  Game of the claim
     * @param roundId Round of the claim
     * @param user    Claimer address
     */
    function confirmClaim(
        bytes32 gameId,
        uint256 roundId,
        address user
    ) external nonReentrant whenNotPaused {
        if (msg.sender != crossChainReceiver) revert Errors.UnauthorizedCrossChainCaller();
        UserDeposit storage userDep = userDeposits[gameId][roundId][user];
        if (!userDep.claimPending) revert Errors.NoPendingClaim();
        userDep.claimPending = false;
        userDep.isClaimed = true;
        emit ClaimConfirmed(gameId, roundId, user);
    }

    /**
     * @notice Called by YieldPlayReceiver to roll back a pending claim if the
     *         source-chain payout fails. Clears claimPending and returns funds.
     * @dev The Receiver holds the tokens between claimOnBehalf() and this call.
     *      Tokens are returned to this contract via safeTransferFrom.
     * @param gameId  Game of the claim
     * @param roundId Round of the claim
     * @param user    Claimer address
     * @param amount  Amount to return (must match what was transferred to Receiver)
     */
    function rollbackClaim(
        bytes32 gameId,
        uint256 roundId,
        address user,
        uint256 amount
    ) external nonReentrant whenNotPaused {
        if (msg.sender != crossChainReceiver) revert Errors.UnauthorizedCrossChainCaller();
        UserDeposit storage userDep = userDeposits[gameId][roundId][user];
        if (!userDep.claimPending) revert Errors.NoPendingClaim();

        // Receiver returns the tokens here
        IERC20(rounds[gameId][roundId].paymentToken).safeTransferFrom(
            msg.sender, address(this), amount
        );

        userDep.claimPending = false;
        // isClaimed stays false — user can retry
        roundReserves[gameId][roundId] += amount;
        emit ClaimRolledBack(gameId, roundId, user);
    }


    // ============ Game Management ============
    
    /**
     * @notice Create a new game
     * @param gameName Unique name for the game
     * @param devFeeBps Developer fee in basis points (max 10000)
     * @param treasury Address to receive developer fees
     * @return gameId The unique identifier for the created game
     */
    function createGame(
        string calldata gameName,
        uint16 devFeeBps,
        address treasury
    ) external whenNotPaused returns (bytes32 gameId) {
        if (devFeeBps > BPS_DENOMINATOR) revert Errors.InvalidDevFeeBps();
        if (treasury == address(0)) revert Errors.ZeroAddress();
        
        gameId = keccak256(abi.encodePacked(msg.sender, gameName));
        
        if (games[gameId].initialized) revert Errors.GameAlreadyExists();
        
        games[gameId] = Game({
            owner: msg.sender,
            gameName: gameName,
            devFeeBps: devFeeBps,
            treasury: treasury,
            roundCounter: 0,
            initialized: true
        });
        
        emit GameCreated(gameId, msg.sender, gameName, devFeeBps);
    }

    // ============ Round Management ============
    
    /**
     * @notice Create a new round for a game
     * @param gameId The game identifier
     * @param startTs Round start timestamp
     * @param endTs Round end timestamp (deposits close)
     * @param lockTime Additional lock period in seconds
     * @param depositFeeBps Deposit fee in basis points
     * @param paymentToken ERC20 token accepted for deposits in this round
     * @return roundId The created round's ID
     */
    function createRound(
        bytes32 gameId,
        uint64 startTs,
        uint64 endTs,
        uint64 lockTime,
        uint16 depositFeeBps,
        address paymentToken
    ) external whenNotPaused returns (uint256 roundId) {
        Game storage game = games[gameId];
        
        if (!game.initialized) revert Errors.GameNotFound();
        if (msg.sender != game.owner) revert Errors.Unauthorized();
        if (endTs <= startTs) revert Errors.InvalidRoundTime();
        if (depositFeeBps > 1000) revert Errors.InvalidDevFeeBps(); // Max 10% deposit fee
        if (paymentToken == address(0)) revert Errors.InvalidPaymentToken();
        
        address vault = vaults[paymentToken];
        if (vault == address(0)) revert Errors.StrategyNotSet();
        
        roundId = game.roundCounter;
        
        rounds[gameId][roundId] = Round({
            gameId: gameId,
            roundId: roundId,
            totalDeposit: 0,
            bonusPrizePool: 0,
            devFee: 0,
            totalWin: 0,
            yieldAmount: 0,
            paymentToken: paymentToken,
            vault: vault,
            depositFeeBps: depositFeeBps,
            startTs: startTs,
            endTs: endTs,
            lockTime: lockTime,
            initialized: true,
            isSettled: false,
            status: RoundStatus.NotStarted,
            isWithdrawn: false
        });
        
        game.roundCounter++;
        
        emit RoundCreated(gameId, roundId, startTs, endTs, lockTime, depositFeeBps, paymentToken, vault);
    }
    
    /**
     * @notice Update round status based on current timestamp
     * @param gameId The game identifier
     * @param roundId The round identifier
     */
    function updateRoundStatus(bytes32 gameId, uint256 roundId) public {
        Round storage round = rounds[gameId][roundId];
        
        // Don't change status if already distributing
        if (round.status == RoundStatus.DistributingRewards) return;
        
        uint256 nowTs = block.timestamp;
        
        if (nowTs < round.startTs) {
            round.status = RoundStatus.NotStarted;
        } else if (nowTs >= round.startTs && nowTs <= round.endTs) {
            round.status = RoundStatus.InProgress;
        } else if (nowTs > round.endTs && nowTs <= round.endTs + round.lockTime) {
            round.status = RoundStatus.Locking;
        } else if (nowTs > round.endTs + round.lockTime) {
            round.status = RoundStatus.ChoosingWinners;
        }
    }

    // ============ User Actions ============
    
    /**
     * @notice Deposit tokens into a round
     * @param gameId The game identifier
     * @param roundId The round identifier
     * @param amount Amount of tokens to deposit
     */
    function deposit(
        bytes32 gameId,
        uint256 roundId,
        uint256 amount
    ) external nonReentrant whenNotPaused {
        if (amount == 0) revert Errors.InvalidAmount();
        
        Game storage game = games[gameId];
        Round storage round = rounds[gameId][roundId];
        
        if (!game.initialized) revert Errors.GameNotFound();
        
        // Update and verify status
        updateRoundStatus(gameId, roundId);
        if (round.status != RoundStatus.InProgress) revert Errors.RoundNotActive();
        
        // Transfer tokens from user (balance-delta for fee-on-transfer safety)
        uint256 preBalance = IERC20(round.paymentToken).balanceOf(address(this));
        IERC20(round.paymentToken).safeTransferFrom(msg.sender, address(this), amount);
        uint256 postBalance = IERC20(round.paymentToken).balanceOf(address(this));
        uint256 actualAmount = postBalance - preBalance;
        
        // Calculate deposit fee (goes to bonus prize pool)
        uint256 depositFee = (actualAmount * round.depositFeeBps) / BPS_DENOMINATOR;
        uint256 netDeposit = actualAmount - depositFee;
        
        // Update round state
        round.totalDeposit += netDeposit;
        round.bonusPrizePool += depositFee;

        // Track per-round reserves
        roundReserves[gameId][roundId] += actualAmount;
        
        // Update user state (user gets credit for net deposit)
        UserDeposit storage userDep = userDeposits[gameId][roundId][msg.sender];
        userDep.depositAmount += netDeposit;
        userDep.exists = true;
        
        emit Deposited(gameId, roundId, msg.sender, netDeposit, depositFee);
    }
    
    /**
     * @notice Claim principal and any winnings after round completion
     * @param gameId The game identifier
     * @param roundId The round identifier
     */
    function claim(
        bytes32 gameId,
        uint256 roundId
    ) external nonReentrant whenNotPaused {
        Round storage round = rounds[gameId][roundId];
        UserDeposit storage userDep = userDeposits[gameId][roundId][msg.sender];
        
        if (round.status != RoundStatus.DistributingRewards) {
            revert Errors.RoundNotCompleted();
        }
        if (userDep.isClaimed || userDep.claimPending) revert Errors.AlreadyClaimed();
        if (!userDep.exists || userDep.depositAmount == 0) {
            revert Errors.NoDepositsFound();
        }
        
        uint256 totalAmount = userDep.depositAmount + userDep.amountToClaim;

        // Verify per-round solvency before transfer
        if (totalAmount > roundReserves[gameId][roundId]) revert Errors.InvalidAmount();
        
        // CEI: update state before transfer
        userDep.isClaimed = true;
        roundReserves[gameId][roundId] -= totalAmount;
        
        if (totalAmount > 0) {
            IERC20(round.paymentToken).safeTransfer(msg.sender, totalAmount);
        }
        
        emit Claimed(gameId, roundId, msg.sender, userDep.depositAmount, userDep.amountToClaim);
    }
    /**
     * @notice Cross-chain claims for users from another chain.
     * @param gameId The game identifier
     * @param roundId The round identifier
     * @param user The original depositor's address
     * @return totalAmount The amount transferred to the Receiver for cross-chain payout
     */
    function claimOnBehalf(
        bytes32 gameId,
        uint256 roundId,
        address user
    ) external nonReentrant whenNotPaused returns (uint256 totalAmount) {
        if (msg.sender != crossChainReceiver) revert Errors.UnauthorizedCrossChainCaller();

        Round storage round = rounds[gameId][roundId];
        UserDeposit storage userDep = userDeposits[gameId][roundId][user];
        
        if (round.status != RoundStatus.DistributingRewards) {
            revert Errors.RoundNotCompleted();
        }
        // Block if claim is already finalized OR still in-flight
        if (userDep.isClaimed || userDep.claimPending) revert Errors.AlreadyClaimed();
        if (!userDep.exists || userDep.depositAmount == 0) {
            revert Errors.NoDepositsFound();
        }
        
        totalAmount = userDep.depositAmount + userDep.amountToClaim;

        // Verify per-round solvency
        if (totalAmount > roundReserves[gameId][roundId]) revert Errors.InvalidAmount();

        // Mark as pending (NOT finalized) until source-chain confirms
        userDep.claimPending = true;
        roundReserves[gameId][roundId] -= totalAmount;
        
        if (totalAmount > 0) {
            // Transfer to Receiver, which holds funds until CLAIM_RESULT is ACKed
            IERC20(round.paymentToken).safeTransfer(msg.sender, totalAmount);
        }
        
        emit Claimed(gameId, roundId, user, userDep.depositAmount, userDep.amountToClaim);
    }

    // ============ Game Owner Actions ============
    
    /**
     * @notice Deploy round funds to ERC4626 vault
     * @param gameId The game identifier
     * @param roundId The round identifier
     */
    function depositToVault(
        bytes32 gameId,
        uint256 roundId
    ) external nonReentrant whenNotPaused {
        Game storage game = games[gameId];
        Round storage round = rounds[gameId][roundId];
        
        if (msg.sender != game.owner) revert Errors.Unauthorized();
        
        updateRoundStatus(gameId, roundId);
        
        // Can deploy during Locking or InProgress (if owner wants early deployment)
        if (round.status == RoundStatus.NotStarted || 
            round.status == RoundStatus.ChoosingWinners ||
            round.status == RoundStatus.DistributingRewards) {
            revert Errors.RoundNotActive();
        }
        
        if (round.totalDeposit == 0) revert Errors.InvalidAmount();
        if (round.vault == address(0)) revert Errors.StrategyNotSet();
        
        // Only deploy the portion that hasn't been deployed yet
        uint256 totalFunds = round.totalDeposit + round.bonusPrizePool;
        uint256 alreadyDeployed = deployedAmounts[gameId][roundId];
        uint256 amount = totalFunds - alreadyDeployed;
        
        if (amount == 0) revert Errors.InvalidAmount();

        deployedAmounts[gameId][roundId] += amount;
        
        // Approve vault and deposit
        IERC20(round.paymentToken).safeIncreaseAllowance(round.vault, amount);
        uint256 shares = IERC4626(round.vault).deposit(amount, address(this));
        
        deployedShares[gameId][roundId] += shares;

        emit FundsDeployed(gameId, roundId, amount, shares);
    }
    
    /**
     * @notice Withdraw funds from ERC4626 vault
     * @param gameId The game identifier
     * @param roundId The round identifier
     */
    function withdrawFromVault(
        bytes32 gameId,
        uint256 roundId
    ) external nonReentrant whenNotPaused {
        Game storage game = games[gameId];
        Round storage round = rounds[gameId][roundId];
        
        if (msg.sender != game.owner) revert Errors.Unauthorized();
        
        updateRoundStatus(gameId, roundId);
        
        if (round.status != RoundStatus.ChoosingWinners) {
            revert Errors.RoundNotEnded();
        }
        if (round.isWithdrawn) revert Errors.FundsAlreadyWithdrawn();
        
        uint256 shares = deployedShares[gameId][roundId];

        // Zero-shares escape path — nothing was deployed, allow settlement to proceed
        if (shares == 0) {
            round.isWithdrawn = true;
            emit FundsWithdrawn(gameId, roundId, 0, 0);
            return;
        }

        if (round.vault == address(0)) revert Errors.StrategyNotSet();
        
        uint256 principal = deployedAmounts[gameId][roundId];
        
        // Redeem all shares for underlying assets
        uint256 withdrawn = IERC4626(round.vault).redeem(shares, address(this), address(this));
        
        uint256 yieldAmount = withdrawn > principal ? withdrawn - principal : 0;
        
        round.yieldAmount = yieldAmount;
        round.isWithdrawn = true;
        deployedShares[gameId][roundId] = 0;

        // Restore per-round reserves with the withdrawn amount
        roundReserves[gameId][roundId] += withdrawn;
        
        emit FundsWithdrawn(gameId, roundId, principal, yieldAmount);
    }
    
    /**
     * @notice Settle the round — calculate fees (accrued, not pushed).
     * @param gameId The game identifier
     * @param roundId The round identifier
     */
    function settlement(
        bytes32 gameId,
        uint256 roundId
    ) external nonReentrant whenNotPaused {
        Game storage game = games[gameId];
        Round storage round = rounds[gameId][roundId];
        
        if (msg.sender != game.owner) revert Errors.Unauthorized();
        if (round.initialized == false) revert Errors.RoundNotFound();

        updateRoundStatus(gameId, roundId);
        
        if (round.status != RoundStatus.ChoosingWinners) {
            revert Errors.RoundNotEnded();
        }
        if (round.isSettled) revert Errors.RoundAlreadySettled();
        if (!round.isWithdrawn) revert Errors.FundsNotWithdrawn(); // Must withdraw first

        uint256 yieldAmount = round.yieldAmount;
        
        uint256 performanceFee = 0;
        uint256 devFee = 0;
        uint256 yieldPrize = 0;
        
        if (yieldAmount > 0) {
            // Calculate performance fee (20%) on yield only
            performanceFee = (yieldAmount * PERFORMANCE_FEE_BPS) / BPS_DENOMINATOR;
            uint256 afterPerformance = yieldAmount - performanceFee;
            
            // Calculate dev fee on remaining yield
            devFee = (afterPerformance * game.devFeeBps) / BPS_DENOMINATOR;
            yieldPrize = afterPerformance - devFee;

            // Accrue fees (pull-based) instead of pushing to treasury addresses
            if (performanceFee > 0) {
                accruedProtocolFees[round.paymentToken] += performanceFee;
                // Remove fee amount from per-round reserves
                roundReserves[gameId][roundId] -= performanceFee;
            }
            if (devFee > 0) {
                accruedDevFees[gameId] += devFee;
                roundReserves[gameId][roundId] -= devFee;
            }
        }
        
        // Total prize = yield prize + bonus prize pool (from deposit fees)
        uint256 totalPrize = yieldPrize + round.bonusPrizePool;
        
        round.isSettled = true;
        round.totalWin = totalPrize;
        round.devFee = devFee;
        
        emit RoundSettled(gameId, roundId, yieldAmount, performanceFee, devFee, totalPrize);
    }
    
    /**
     * @notice Choose a winner and assign prize amount
     * @param gameId The game identifier
     * @param roundId The round identifier
     * @param winner Winner address
     * @param amount Prize amount to assign
     */
    function chooseWinner(
        bytes32 gameId,
        uint256 roundId,
        address winner,
        uint256 amount
    ) external whenNotPaused {
        Game storage game = games[gameId];
        Round storage round = rounds[gameId][roundId];
        UserDeposit storage winnerDep = userDeposits[gameId][roundId][winner];
        
        if (msg.sender != game.owner) revert Errors.Unauthorized();
        if (round.status != RoundStatus.ChoosingWinners) {
            revert Errors.RoundNotCompleted();
        }
        if (!round.isSettled) revert Errors.RoundNotSettled();
        if (amount > round.totalWin) revert Errors.InsufficientPrizePool();
        if (!winnerDep.exists || winnerDep.depositAmount == 0) {
            revert Errors.NoDepositsFound();
        }
        
        winnerDep.amountToClaim += amount;
        round.totalWin -= amount;
        
        // Transition to distributing when all prizes allocated
        if (round.totalWin == 0) {
            round.status = RoundStatus.DistributingRewards;
        }
        
        emit WinnerChosen(gameId, roundId, winner, amount);
    }
    
    /**
     * @notice Finalize round and allow claims (if prizes not fully allocated)

     * @param gameId The game identifier
     * @param roundId The round identifier
     */
    function finalizeRound(
        bytes32 gameId,
        uint256 roundId
    ) external whenNotPaused {
        Game storage game = games[gameId];
        Round storage round = rounds[gameId][roundId];
        
        if (msg.sender != game.owner) revert Errors.Unauthorized();
        if (round.status != RoundStatus.ChoosingWinners) {
            revert Errors.RoundNotCompleted();
        }
        if (!round.isSettled) revert Errors.RoundNotSettled();

        if (round.totalWin > 0) {
            uint256 remaining = round.totalWin;
            // Update state BEFORE external call (Checks-Effects-Interactions)
            round.totalWin = 0;
            roundReserves[gameId][roundId] -= remaining;
            // Return remaining unallocated prize to game treasury
            IERC20(round.paymentToken).safeTransfer(game.treasury, remaining);
        }
        
        // Allow finalization even if not all prizes distributed
        round.status = RoundStatus.DistributingRewards;
    }

    // ============ View Functions ============
    
    /**
     * @notice Get game details
     * @param gameId The game identifier
     * @return Game struct
     */
    function getGame(bytes32 gameId) external view returns (Game memory) {
        return games[gameId];
    }
    
    /**
     * @notice Get round details
     * @param gameId The game identifier
     * @param roundId The round identifier
     * @return Round struct
     */
    function getRound(bytes32 gameId, uint256 roundId) external view returns (Round memory) {
        return rounds[gameId][roundId];
    }
    
    /**
     * @notice Get user deposit details
     * @param gameId The game identifier
     * @param roundId The round identifier
     * @param user User address
     * @return UserDeposit struct
     */
    function getUserDeposit(
        bytes32 gameId,
        uint256 roundId,
        address user
    ) external view returns (UserDeposit memory) {
        return userDeposits[gameId][roundId][user];
    }
    
    /**
     * @notice Calculate game ID from owner and name
     * @param owner Game owner address
     * @param gameName Game name
     * @return gameId The calculated game identifier
     */
    function calculateGameId(
        address owner,
        string calldata gameName
    ) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(owner, gameName));
    }
    
    /**
     * @notice Get current round status
     * @param gameId The game identifier
     * @param roundId The round identifier
     * @return Current RoundStatus
     */
    function getCurrentStatus(
        bytes32 gameId,
        uint256 roundId
    ) external view returns (RoundStatus) {
        Round storage round = rounds[gameId][roundId];
        
        if (round.status == RoundStatus.DistributingRewards) {
            return RoundStatus.DistributingRewards;
        }
        
        uint256 nowTs = block.timestamp;
        
        if (nowTs < round.startTs) {
            return RoundStatus.NotStarted;
        } else if (nowTs >= round.startTs && nowTs <= round.endTs) {
            return RoundStatus.InProgress;
        } else if (nowTs > round.endTs && nowTs <= round.endTs + round.lockTime) {
            return RoundStatus.Locking;
        } else {
            return RoundStatus.ChoosingWinners;
        }
    }

    // ============ Internal Helpers ============

    /**
     * @dev Returns the payment token of the most recently created round for a game.
     *      Used by withdrawDevFees to determine which token to transfer.
     */
    function _latestPaymentToken(bytes32 gameId, uint256 roundCounter) internal view returns (address) {
        if (roundCounter == 0) revert Errors.RoundNotFound();
        return rounds[gameId][roundCounter - 1].paymentToken;
    }
}
