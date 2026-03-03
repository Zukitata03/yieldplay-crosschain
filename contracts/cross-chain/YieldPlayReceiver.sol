// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ITeleporterReceiver} from "../interfaces/ITeleporterReceiver.sol";
import {ITeleporterMessenger, TeleporterMessageInput, TeleporterFeeInfo} from "../interfaces/ITeleporterMessenger.sol";

/**
 * @notice Minimal interface for calling depositOnBehalf on YieldPlay
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
}

/**
 * @title YieldPlayReceiver
 * @notice Deployed on the DESTINATION subnet (chainB) alongside YieldPlay.sol.
 *
 * The Teleporter relayer calls receiveTeleporterMessage() after the source chain
 * sends a message via YieldPlaySender. This contract:
 *   1. Verifies msg.sender is the Teleporter Messenger (trust the protocol, not individuals)
 *   2. Verifies the message came from the trusted YieldPlaySender on chainA
 *   3. Decodes the payload and calls YieldPlay.depositOnBehalf()
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

    // ─── Enums ────────────────────────────────────────────────────────────────

    enum MessageType { DEPOSIT, CLAIM_REQUEST, CLAIM_RESULT, REFUND }

    // ─── Immutables ───────────────────────────────────────────────────────────

    /// @notice Main YieldPlay contract on this chain
    IYieldPlayDeposit public immutable yieldPlay;

    /// @notice The ERC20 token used for deposits on this chain
    address public immutable paymentToken;

    // ─── State ────────────────────────────────────────────────────────────────

    /// @notice Trusted senders: sourceChainID => YieldPlaySender address
    mapping(bytes32 => address) public trustedSenders;

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

    // ─── Errors ───────────────────────────────────────────────────────────────

    error OnlyTeleporter();
    error UntrustedSource(bytes32 sourceChainId, address originSenderAddress);

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
     * @notice Register a trusted sender on a source chain.
     * @param sourceChainId   Blockchain ID of the source subnet (chainA)
     * @param senderContract  Address of YieldPlaySender on chainA
     */
    function setTrustedSender(
        bytes32 sourceChainId,
        address senderContract
    ) external onlyOwner {
        trustedSenders[sourceChainId] = senderContract;
        emit TrustedSenderSet(sourceChainId, senderContract);
    }

    // ─── ITeleporterReceiver ──────────────────────────────────────────────────

    /**
     * @notice Called by TeleporterMessenger when a message arrives from chainA.
     * @param sourceBlockchainID Blockchain ID of the origin chain
     * @param originSenderAddress Address of YieldPlaySender on chainA
     * @param message ABI-encoded (gameId, roundId, user, amount)
     */
    function receiveTeleporterMessage(
        bytes32 sourceBlockchainID,
        address originSenderAddress,
        bytes calldata message
    ) external override {
        // 1. Only TeleporterMessenger can call this
        if (msg.sender != TELEPORTER_MESSENGER) revert OnlyTeleporter();

        // 2. Verify the message came from our trusted YieldPlaySender
        address expectedSender = trustedSenders[sourceBlockchainID];
        if (expectedSender == address(0) || originSenderAddress != expectedSender) {
            revert UntrustedSource(sourceBlockchainID, originSenderAddress);
        }

        // 3. Decode payload type
        MessageType messageType = abi.decode(message, (MessageType));

        if (messageType == MessageType.DEPOSIT) {
            (, bytes32 gameId, uint256 roundId, address user, uint256 amount) =
                abi.decode(message, (MessageType, bytes32, uint256, address, uint256));

            // 4. Approve YieldPlay to pull funds from this contract, then deposit
            IERC20(paymentToken).safeIncreaseAllowance(address(yieldPlay), amount);
            
            try yieldPlay.depositOnBehalf(gameId, roundId, user, amount) {
                emit CrossChainDepositReceived(sourceBlockchainID, gameId, roundId, user, amount);
            } catch {
                // Deposit failed (e.g. round expired). Send refund message back.
                IERC20(paymentToken).safeDecreaseAllowance(address(yieldPlay), amount);
                bytes memory refundPayload = abi.encode(MessageType.REFUND, gameId, roundId, user, amount);
                _sendTeleporterMessage(sourceBlockchainID, expectedSender, refundPayload);
                emit CrossChainRefundSent(sourceBlockchainID, gameId, roundId, user, amount);
            }
        } else if (messageType == MessageType.CLAIM_REQUEST) {
            (, bytes32 gameId, uint256 roundId, address user) =
                abi.decode(message, (MessageType, bytes32, uint256, address));
            
            // Assuming claimOnBehalf sends funds to THIS receiver contract
            uint256 claimedAmount = yieldPlay.claimOnBehalf(gameId, roundId, user);
            
            bytes memory claimPayload = abi.encode(MessageType.CLAIM_RESULT, gameId, roundId, user, claimedAmount);
            _sendTeleporterMessage(sourceBlockchainID, expectedSender, claimPayload);
            emit CrossChainClaimProcessed(sourceBlockchainID, gameId, roundId, user, claimedAmount);
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
