// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title Errors
 * @notice Custom errors for the YieldPlay protocol
 */
library Errors {
    /// @notice Thrown when dev fee exceeds maximum (10000 bps)
    error InvalidDevFeeBps();
    
    /// @notice Thrown when payment token address is invalid
    error InvalidPaymentToken();
    
    /// @notice Thrown when round time parameters are invalid
    error InvalidRoundTime();
    
    /// @notice Thrown when caller is not authorized
    error Unauthorized();
    
    /// @notice Thrown when round is not in the expected status
    error RoundNotActive();
    
    /// @notice Thrown when arithmetic overflow occurs
    error Overflow();
    
    /// @notice Thrown when user has no deposits in the round
    error NoDepositsFound();
    
    /// @notice Thrown when round has not completed
    error RoundNotCompleted();
    
    /// @notice Thrown when user has already claimed
    error AlreadyClaimed();
    
    /// @notice Thrown when deposit/claim amount is invalid
    error InvalidAmount();
    
    /// @notice Thrown when external yield strategy call fails
    error StrategyCallFailed();
    
    /// @notice Thrown when round has not ended yet
    error RoundNotEnded();
    
    /// @notice Thrown when there's no yield to distribute
    error NoFarmedAmount();
    
    /// @notice Thrown when round is already settled
    error RoundAlreadySettled();
    
    /// @notice Thrown when round is not settled
    error RoundNotSettled();
    
    /// @notice Thrown when game already exists
    error GameAlreadyExists();
    
    /// @notice Thrown when game does not exist
    error GameNotFound();
    
    /// @notice Thrown when round does not exist
    error RoundNotFound();
    
    /// @notice Thrown when funds have already been withdrawn from vault
    error FundsAlreadyWithdrawn();
    
    /// @notice Thrown when funds have not been deployed to vault yet
    error FundsNotDeployed();
    
    /// @notice Thrown when funds must be withdrawn from vault before settling
    error FundsNotWithdrawn();
    
    /// @notice Thrown when strategy is not set
    error StrategyNotSet();
    
    /// @notice Thrown when trying to set zero address
    error ZeroAddress();
    
    /// @notice Thrown when winner amount exceeds available pool
    error InsufficientPrizePool();

    /// @notice Thrown when depositOnBehalf is called by an untrusted address
    error UnauthorizedCrossChainCaller();

    /// @notice Thrown when a cross-chain claim is already in-flight for this user/round
    error ClaimPending();

    /// @notice Thrown when a CLAIM_RESULT amount exceeds what the user originally locked
    error ExceedsLockedFunds();

    /// @notice Thrown when the reclaim timeout has not yet elapsed
    error TimeoutNotReached();

    /// @notice Thrown when there is nothing to reclaim
    error NothingToReclaim();

    /// @notice Thrown when trying to rollback a claim that is not pending
    error NoPendingClaim();
}
