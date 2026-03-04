// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ITeleporterReceiver} from "../interfaces/ITeleporterReceiver.sol";
import {ITeleporterMessenger, TeleporterMessageInput, TeleporterFeeInfo} from "../interfaces/ITeleporterMessenger.sol";

/**
 * @notice Minimal interface for calling depositOnBehalf / claimOnBehalf / confirm / rollback on YieldPlay
 */
interface IYieldPlayDeposit {
    function depositOnBehalf(
        bytes32 gameId,
        uint256 roundId,
        address user,
        uint256 amount
    ) external;

    function claimOnBehalf(
        bytes32 gameId,
        uint256 roundId,
        address user
    ) external returns (uint256 totalAmount);

    function confirmClaim(
        bytes32 gameId,
        uint256 roundId,
        address user
    ) external;

    function rollbackClaim(
        bytes32 gameId,
        uint256 roundId,
        address user,
        uint256 amount
    ) external;
}

/**
 * @title YieldPlayReceiver
 * @notice Deployed on the DESTINATION subnet (chainB) alongside YieldPlay.sol.
 *
 * The Teleporter relayer calls receiveTeleporterMessage() after the source chain
 * sends a message via YieldPlaySender. This contract:
 *   1. Verifies msg.sender is the Teleporter Messenger
 *   2. Verifies the message came from the trusted YieldPlaySender on chainA
 *   3. Decodes the payload and dispatches to YieldPlay
 *
 */
contract YieldPlayReceiver is ITeleporterReceiver, Ownable {
    using SafeERC20 for IERC20;

    // ─── Constants ────────────────────────────────────────────────────────────

    /// @notice Universal Teleporter Messenger address (same on all Avalanche chains)
    address public constant TELEPORTER_MESSENGER =
        0x253b2784c75e510dD0fF1da844684a1aC0aa5fcf;

    /// @notice Gas limit for execution on the destination chain
    uint256 public constant DEST_GAS_LIMIT = 300_000;

    /// @notice How long before a proposed trust-anchor change takes effect
    uint256 public constant TRUST_ROTATION_DELAY = 48 hours;

    // ─── Enums ────────────────────────────────────────────────────────────────

    enum MessageType { DEPOSIT, CLAIM_REQUEST, CLAIM_RESULT, REFUND }

    // ─── Immutables ───────────────────────────────────────────────────────────

    /// @notice Main YieldPlay contract on this chain
    IYieldPlayDeposit public immutable yieldPlay;

    /// @notice The ERC20 token used for deposits on this chain
    address public immutable paymentToken;

    // ─── State ────────────────────────────────────────────────────────────────

    /// @notice Trusted (active) senders: sourceChainID => YieldPlaySender address
    mapping(bytes32 => address) public trustedSenders;

    /**
     * @notice Pending trust-anchor proposals waiting for the timelock to expire.
     * @dev struct PendingTrust { address newSender; uint256 effectiveAt; }
     *      encoded as two storage slots for simplicity.
     */
    mapping(bytes32 => address) public pendingSenders;
    mapping(bytes32 => uint256) public pendingSenderEffectiveAt;

    // ─── Events ───────────────────────────────────────────────────────────────

    event CrossChainDepositReceived(
        bytes32 indexed sourceChainId,
        bytes32 indexed gameId,
        uint256 indexed roundId,
        address user,
        uint256 amount
    );

    event CrossChainRefundSent(
        bytes32 indexed destChainId,
        bytes32 indexed gameId,
        uint256 indexed roundId,
        address user,
        uint256 amount
    );

    event CrossChainClaimProcessed(
        bytes32 indexed destChainId,
        bytes32 indexed gameId,
        uint256 indexed roundId,
        address user,
        uint256 amount
    );

    event TrustedSenderSet(bytes32 indexed sourceChainId, address senderAddress);

    event TrustedSenderProposed(bytes32 indexed sourceChainId, address newSender, uint256 effectiveAt);
    event TrustedSenderExecuted(bytes32 indexed sourceChainId, address newSender);

    // ─── Errors ───────────────────────────────────────────────────────────────

    error OnlyTeleporter();
    error UntrustedSource(bytes32 sourceChainId, address originSenderAddress);
    error RotationTooEarly(uint256 effectiveAt);
    error NoPendingRotation();

    // ─── Constructor ──────────────────────────────────────────────────────────

    /**
     * @param _yieldPlay    Address of YieldPlay.sol on this chain
     * @param _paymentToken ERC20 token address on this chain
     */
    constructor(address _yieldPlay, address _paymentToken) Ownable(msg.sender) {
        require(_yieldPlay != address(0), "Zero yieldPlay");
        require(_paymentToken != address(0), "Zero token");
        yieldPlay = IYieldPlayDeposit(_yieldPlay);
        paymentToken = _paymentToken;
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    /**
     * @notice Register the INITIAL trusted sender for a source chain (first-time setup only).
     * @dev For subsequent changes use proposeTrustedSender + executeTrustedSender.
     * @param sourceChainId   Blockchain ID of the source subnet (chainA)
     * @param senderContract  Address of YieldPlaySender on chainA
     */
    function setTrustedSender(
        bytes32 sourceChainId,
        address senderContract
    ) external onlyOwner {
        require(trustedSenders[sourceChainId] == address(0), "Use propose/execute to rotate");
        trustedSenders[sourceChainId] = senderContract;
        emit TrustedSenderSet(sourceChainId, senderContract);
    }

    /**
     * @notice Propose a trust-anchor rotation. Takes effect after TRUST_ROTATION_DELAY.
     * @dev During the delay both the old and proposed sender are accepted so in-flight messages
     *      from the old sender are not orphaned.
     * @param sourceChainId   Blockchain ID of the source subnet
     * @param newSender       New YieldPlaySender address to trust
     */
    function proposeTrustedSender(
        bytes32 sourceChainId,
        address newSender
    ) external onlyOwner {
        uint256 effectiveAt = block.timestamp + TRUST_ROTATION_DELAY;
        pendingSenders[sourceChainId] = newSender;
        pendingSenderEffectiveAt[sourceChainId] = effectiveAt;
        emit TrustedSenderProposed(sourceChainId, newSender, effectiveAt);
    }

    /**
     * @notice Execute a previously proposed trust-anchor rotation.
     * @dev Can only be called after TRUST_ROTATION_DELAY has elapsed.
     *      Clears the pending entry and activates the new sender.
     * @param sourceChainId Blockchain ID of the source subnet
     */
    function executeTrustedSender(bytes32 sourceChainId) external onlyOwner {
        uint256 effectiveAt = pendingSenderEffectiveAt[sourceChainId];
        if (effectiveAt == 0) revert NoPendingRotation();
        if (block.timestamp < effectiveAt) revert RotationTooEarly(effectiveAt);

        address newSender = pendingSenders[sourceChainId];
        trustedSenders[sourceChainId] = newSender;
        delete pendingSenders[sourceChainId];
        delete pendingSenderEffectiveAt[sourceChainId];

        emit TrustedSenderExecuted(sourceChainId, newSender);
    }

    // ─── ITeleporterReceiver ──────────────────────────────────────────────────

    /**
     * @notice Called by TeleporterMessenger when a message arrives from chainA.
     * @param sourceBlockchainID Blockchain ID of the origin chain
     * @param originSenderAddress Address of YieldPlaySender on chainA
     * @param message ABI-encoded payload
     */
    function receiveTeleporterMessage(
        bytes32 sourceBlockchainID,
        address originSenderAddress,
        bytes calldata message
    ) external override {
        // 1. Only TeleporterMessenger can call this
        if (msg.sender != TELEPORTER_MESSENGER) revert OnlyTeleporter();

        // 2. Verify trust — accept both active sender AND pending (overlap window)
        address activeSender = trustedSenders[sourceBlockchainID];
        address pendingSender = pendingSenders[sourceBlockchainID];

        bool fromActiveSender  = activeSender  != address(0) && originSenderAddress == activeSender;
        bool fromPendingSender = pendingSender  != address(0) && originSenderAddress == pendingSender;

        if (!fromActiveSender && !fromPendingSender) {
            revert UntrustedSource(sourceBlockchainID, originSenderAddress);
        }

        // Use whichever matching sender address to reply
        address replySender = fromActiveSender ? activeSender : pendingSender;

        // 3. Decode payload type
        MessageType messageType = abi.decode(message, (MessageType));

        if (messageType == MessageType.DEPOSIT) {
            (, bytes32 gameId, uint256 roundId, address user, uint256 amount) =
                abi.decode(message, (MessageType, bytes32, uint256, address, uint256));

            // Approve YieldPlay to pull funds from this contract, then deposit
            IERC20(paymentToken).safeIncreaseAllowance(address(yieldPlay), amount);
            
            try yieldPlay.depositOnBehalf(gameId, roundId, user, amount) {
                emit CrossChainDepositReceived(sourceBlockchainID, gameId, roundId, user, amount);
            } catch {
                // Deposit failed (e.g. round expired). Send refund message back.
                IERC20(paymentToken).safeDecreaseAllowance(address(yieldPlay), amount);
                bytes memory refundPayload = abi.encode(MessageType.REFUND, gameId, roundId, user, amount);
                _sendTeleporterMessage(sourceBlockchainID, replySender, refundPayload);
                emit CrossChainRefundSent(sourceBlockchainID, gameId, roundId, user, amount);
            }

        } else if (messageType == MessageType.CLAIM_REQUEST) {
            (, bytes32 gameId, uint256 roundId, address user) =
                abi.decode(message, (MessageType, bytes32, uint256, address));

            // Measure actual tokens received via balance delta
            // so the CLAIM_RESULT message reports the real delivered amount, not nominal.
            uint256 preBal = IERC20(paymentToken).balanceOf(address(this));
            uint256 claimedAmount = yieldPlay.claimOnBehalf(gameId, roundId, user);
            uint256 actualReceived = IERC20(paymentToken).balanceOf(address(this)) - preBal;

            // Send CLAIM_RESULT with actualReceived (what the source chain will pay out)
            bytes memory claimPayload = abi.encode(
                MessageType.CLAIM_RESULT,
                gameId,
                roundId,
                user,
                actualReceived
            );
            _sendTeleporterMessage(sourceBlockchainID, replySender, claimPayload);
            emit CrossChainClaimProcessed(sourceBlockchainID, gameId, roundId, user, actualReceived);

            // If Teleporter message sending fails (or is never delivered),
            // the Receiver can call rollbackClaim() on YieldPlay. For now we confirm
            // optimistically after sending — a more robust design would wait for a
            // CLAIM_RESULT_ACK from the source, but that requires a 3rd message leg.
            // At minimum: confirmClaim is called here so isClaimed is eventually finalized.
            yieldPlay.confirmClaim(gameId, roundId, user);

            // Suppress unused variable warning; claimedAmount and actualReceived may differ
            // for fee-on-transfer tokens — actualReceived is the correct value to report.
            claimedAmount;
        }
    }

    function _sendTeleporterMessage(bytes32 destinationBlockchainID, address destinationAddress, bytes memory payload) internal {
        TeleporterMessageInput memory messageInput = TeleporterMessageInput({
            destinationBlockchainID: destinationBlockchainID,
            destinationAddress: destinationAddress,
            feeInfo: TeleporterFeeInfo({feeTokenAddress: address(0), amount: 0}),
            requiredGasLimit: DEST_GAS_LIMIT,
            allowedRelayerAddresses: new address[](0),
            message: payload
        });
        ITeleporterMessenger(TELEPORTER_MESSENGER).sendCrossChainMessage(messageInput);
    }

    // ─── Fund Management ─────────────────────────────────────────────────────

    /**
     * @notice Withdraw tokens from this contract (admin only, for recovery).
     */
    function withdrawTokens(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(msg.sender, amount);
    }
}
