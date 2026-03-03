// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ITeleporterMessenger, TeleporterMessageInput, TeleporterFeeInfo} from "../interfaces/ITeleporterMessenger.sol";
import {ITeleporterReceiver} from "../interfaces/ITeleporterReceiver.sol";

/**
 * @title YieldPlaySender
 * @notice Deployed on the SOURCE subnet (chainA).
 *
 * A user approves this contract for `amount` of the source token, then calls
 * crossChainDeposit(). The contract:
 *   1. Locks their tokens here
 *   2. Sends a Teleporter message to YieldPlayReceiver on the destination chain
 *
 * The avalanche-cli relayer picks up the message and calls
 * YieldPlayReceiver.receiveTeleporterMessage() on chainB.
 *
 * @dev TeleporterMessenger is pre-deployed by avalanche-cli at the universal
 *      address 0x253b2784c75e510dD0fF1da844684a1aC0aa5fcf on all local subnets.
 */
contract YieldPlaySender is ITeleporterReceiver {
    using SafeERC20 for IERC20;

    // ─── Constants ────────────────────────────────────────────────────────────

    /// @notice Universal Teleporter Messenger address (same on all Avalanche chains)
    address public constant TELEPORTER_MESSENGER =
        0x253b2784c75e510dD0fF1da844684a1aC0aa5fcf;

    /// @notice Gas limit for execution on the destination chain
    uint256 public constant DEST_GAS_LIMIT = 300_000;

    // ─── Immutables ───────────────────────────────────────────────────────────

    /// @notice Blockchain ID of the destination chain (chainB), set at deploy time
    bytes32 public immutable destinationBlockchainID;

    /// @notice Address of YieldPlayReceiver deployed on chainB
    address public immutable destinationReceiver;

    /// @notice ERC20 token accepted for deposits on this subnet
    address public immutable sourceToken;

    // ─── Enums ────────────────────────────────────────────────────────────────

    enum MessageType { DEPOSIT, CLAIM_REQUEST, CLAIM_RESULT, REFUND }

    // ─── State ────────────────────────────────────────────────────────────────

    /// @notice Locked funds per user per game per round (for potential refund logic)
    mapping(bytes32 => mapping(uint256 => mapping(address => uint256))) public lockedFunds;

    // ─── Events ───────────────────────────────────────────────────────────────

    event CrossChainDepositSent(
        bytes32 indexed gameId,
        uint256 indexed roundId,
        address indexed user,
        uint256 amount,
        bytes32 teleporterMessageId
    );

    event CrossChainClaimSent(
        bytes32 indexed gameId,
        uint256 indexed roundId,
        address indexed user,
        bytes32 teleporterMessageId
    );

    event ClaimReceived(
        bytes32 indexed gameId,
        uint256 indexed roundId,
        address indexed user,
        uint256 amount
    );

    event RefundReceived(
        bytes32 indexed gameId,
        uint256 indexed roundId,
        address indexed user,
        uint256 amount
    );

    // ─── Errors ───────────────────────────────────────────────────────────────

    error OnlyTeleporter();
    error UntrustedSource(bytes32 sourceChainId, address originSenderAddress);

    // ─── Constructor ──────────────────────────────────────────────────────────

    /**
     * @param _destinationBlockchainID  Chain ID of chainB (from `avalanche blockchain describe chainB`)
     * @param _destinationReceiver      Address of YieldPlayReceiver on chainB
     * @param _sourceToken              ERC20 token address on this subnet
     */
    constructor(
        bytes32 _destinationBlockchainID,
        address _destinationReceiver,
        address _sourceToken
    ) {
        require(_destinationReceiver != address(0), "Zero receiver");
        require(_sourceToken != address(0), "Zero token");
        destinationBlockchainID = _destinationBlockchainID;
        destinationReceiver = _destinationReceiver;
        sourceToken = _sourceToken;
    }

    // ─── External ─────────────────────────────────────────────────────────────

    /**
     * @notice Initiate a cross-chain deposit into a YieldPlay round on chainB.
     * @param gameId  The target game ID on chainB
     * @param roundId The target round ID on chainB
     * @param amount  Amount of sourceToken to deposit
     * @return teleporterMessageId The Teleporter message ID (for tracking)
     */
    function crossChainDeposit(
        bytes32 gameId,
        uint256 roundId,
        uint256 amount
    ) external returns (bytes32 teleporterMessageId) {
        require(amount > 0, "Amount must be > 0");

        // 1. Lock tokens from user into this contract
        IERC20(sourceToken).safeTransferFrom(msg.sender, address(this), amount);
        lockedFunds[gameId][roundId][msg.sender] += amount;

        // 2. Encode deposit intent as the message payload
        bytes memory payload = abi.encode(MessageType.DEPOSIT, gameId, roundId, msg.sender, amount);

        // 3. Send via Teleporter (fee = 0 for local relayer)
        TeleporterMessageInput memory messageInput = TeleporterMessageInput({
            destinationBlockchainID: destinationBlockchainID,
            destinationAddress: destinationReceiver,
            feeInfo: TeleporterFeeInfo({feeTokenAddress: address(0), amount: 0}),
            requiredGasLimit: DEST_GAS_LIMIT,
            allowedRelayerAddresses: new address[](0), // any relayer
            message: payload
        });

        teleporterMessageId = ITeleporterMessenger(TELEPORTER_MESSENGER)
            .sendCrossChainMessage(messageInput);

        emit CrossChainDepositSent(gameId, roundId, msg.sender, amount, teleporterMessageId);
    }

    /**
     * @notice Initiate a cross-chain claim for a completed YieldPlay round on chainB.
     * @param gameId  The target game ID on chainB
     * @param roundId The target round ID on chainB
     * @return teleporterMessageId The Teleporter message ID (for tracking)
     */
    function crossChainClaim(bytes32 gameId, uint256 roundId) external returns (bytes32 teleporterMessageId) {
        // Encode claim intent as the message payload
        bytes memory payload = abi.encode(MessageType.CLAIM_REQUEST, gameId, roundId, msg.sender);

        TeleporterMessageInput memory messageInput = TeleporterMessageInput({
            destinationBlockchainID: destinationBlockchainID,
            destinationAddress: destinationReceiver,
            feeInfo: TeleporterFeeInfo({feeTokenAddress: address(0), amount: 0}),
            requiredGasLimit: DEST_GAS_LIMIT,
            allowedRelayerAddresses: new address[](0),
            message: payload
        });

        teleporterMessageId = ITeleporterMessenger(TELEPORTER_MESSENGER).sendCrossChainMessage(messageInput);

        emit CrossChainClaimSent(gameId, roundId, msg.sender, teleporterMessageId);
    }

    // ─── ITeleporterReceiver ──────────────────────────────────────────────────

    /**
     * @notice Called by TeleporterMessenger when a message arrives from chainB.
     */
    function receiveTeleporterMessage(
        bytes32 sourceBlockchainID,
        address originSenderAddress,
        bytes calldata message
    ) external override {
        // 1. Only TeleporterMessenger can call this
        if (msg.sender != TELEPORTER_MESSENGER) revert OnlyTeleporter();

        // 2. Verify the message came from the destination chain & receiver
        if (sourceBlockchainID != destinationBlockchainID || originSenderAddress != destinationReceiver) {
            revert UntrustedSource(sourceBlockchainID, originSenderAddress);
        }

        // 3. Decode payload type
        MessageType messageType = abi.decode(message, (MessageType));

        if (messageType == MessageType.CLAIM_RESULT) {
            (, bytes32 gameId, uint256 roundId, address user, uint256 amount) =
                abi.decode(message, (MessageType, bytes32, uint256, address, uint256));
            
            // Unlock/transfer claimed tokens to user
            if (amount > 0) {
                IERC20(sourceToken).safeTransfer(user, amount);
            }
            emit ClaimReceived(gameId, roundId, user, amount);
            
        } else if (messageType == MessageType.REFUND) {
            (, bytes32 gameId, uint256 roundId, address user, uint256 amount) =
                abi.decode(message, (MessageType, bytes32, uint256, address, uint256));
            
            // Decrement locked funds and refund user
            lockedFunds[gameId][roundId][user] -= amount;
            IERC20(sourceToken).safeTransfer(user, amount);
            emit RefundReceived(gameId, roundId, user, amount);
        }
    }
}
