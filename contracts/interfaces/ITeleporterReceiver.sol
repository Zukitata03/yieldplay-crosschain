// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ITeleporterReceiver
 * @notice Interface that cross-chain destination contracts must implement.
 *         TeleporterMessenger calls receiveTeleporterMessage() on the destination
 *         contract after the relayer delivers the message.
 *
 * Source: https://github.com/ava-labs/teleporter
 */
interface ITeleporterReceiver {
    /**
     * @notice Called by TeleporterMessenger on the receiving chain.
     * @param sourceBlockchainID Blockchain ID of the origin chain (bytes32 Avalanche chain ID).
     * @param originSenderAddress Address of the contract that called sendCrossChainMessage on origin.
     * @param message ABI-encoded payload set by the sender.
     */
    function receiveTeleporterMessage(
        bytes32 sourceBlockchainID,
        address originSenderAddress,
        bytes calldata message
    ) external;
}
