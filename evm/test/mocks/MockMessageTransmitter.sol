// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IMessageTransmitterV2} from "../../src/interfaces/ICctpV2.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice Local attestation boundary fixture for CctpAdapter receive tests.
contract MockMessageTransmitter is IMessageTransmitterV2 {
    uint32 public localDomain = 1;
    address public immutable USDC;
    mapping(bytes32 id => bool seen) public processed;
    bool public shouldRevert;
    uint8 public fault;
    uint256 public calls;
    bool public reentryRejected;
    bytes4 public reentryError;

    constructor(address usdc, uint32 domain) {
        USDC = usdc;
        localDomain = domain;
    }

    function setFault(uint8 value) external {
        fault = value;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function setLocalDomain(uint32 domain) external {
        localDomain = domain;
    }

    function receiveMessage(bytes calldata message, bytes calldata) external override returns (bool) {
        if (shouldRevert) revert("MockMessageTransmitter: invalid attestation");
        if (message.length < 148 + 228) revert("MockMessageTransmitter: malformed");

        bytes32 replayId = bytes32(message[12:44]);
        if (processed[replayId]) revert("MockMessageTransmitter: replay");

        uint256 amount = 0;
        for (uint256 i; i < 32; ++i) {
            amount = (amount << 8) | uint8(message[216 + i]);
        }
        processed[replayId] = true;
        ++calls;

        address recipient = address(bytes20(bytes32(message[184:216]) << 96));
        if (fault == 3) --amount;
        if (fault == 4) ++amount;
        if (fault != 5) MockERC20(USDC).mint(recipient, amount);
        if (fault == 1) revert("provider failed after mint");
        if (fault == 2) return false;
        if (fault == 6 || fault == 7) {
            (bool ok, bytes memory reason) =
                msg.sender.call(abi.encodeWithSignature("receiveMessage(bytes,bytes)", message, hex"51"));
            reentryRejected = !ok;
            // Intentionally keep only the first four revert bytes: the ABI error selector.
            // forge-lint: disable-next-line(unsafe-typecast)
            reentryError = bytes4(reason);
            if (fault == 7) require(ok, "nested receive rejected");
        }
        if (fault == 8) _malformedReturn();
        return true;
    }

    function _malformedReturn() private pure {
        // Intentionally return a noncanonical bool from the hostile provider fixture.
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            mstore(0, 2)
            return(0, 32)
        }
    }
}
