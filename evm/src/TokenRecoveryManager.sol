// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAccessControl} from "openzeppelin/access/IAccessControl.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "openzeppelin/utils/ReentrancyGuard.sol";

import {
    ClaimLiabilityInsufficient,
    InvalidAmount,
    RecoveryExceedsSurplus,
    TimelockAlreadyExecuted,
    TimelockExpired,
    TimelockNotQueued,
    TimelockNotReady,
    TokenRecoveryForbidden,
    Unauthorized,
    ZeroAddress
} from "./HyperionErrors.sol";
import {QueuedTokenRecovery, TokenConfig} from "./HyperionTypes.sol";
import {IHyperionRouter} from "./interfaces/IHyperionRouter.sol";
import {ITokenRecoveryManager} from "./interfaces/ITokenRecoveryManager.sol";

/// @title Recovery of accidental router tokens
/// @notice Timelocked controller for returning only unencumbered accidental router custody.
/// @dev The router remains the token holder and performs the guarded exact transfer.
contract TokenRecoveryManager is ITokenRecoveryManager, ReentrancyGuard {
    bytes32 private constant DEFAULT_ADMIN_ROLE = bytes32(0);
    bytes32 private constant GUARDIAN_ROLE = keccak256("hyperion.guardian");

    /// @notice The immutable router whose custody and roles this manager reads.
    address public immutable override ROUTER;
    /// @notice Exact unsettled claim custody reserved for each token.
    mapping(address token => uint256 amount) public override claimLiability;
    mapping(uint64 recoveryId => QueuedTokenRecovery recovery) private _recoveries;
    uint64 private _recoveryCount;

    /// @notice Bind this manager permanently to the router that retains custody and authority.
    /// @param router The creating router, which retains custody and governance authority.
    constructor(address router) {
        if (router == address(0)) revert ZeroAddress();
        ROUTER = router;
    }

    /// @inheritdoc ITokenRecoveryManager
    function recordClaim(address token, uint256 amount) external override onlyRouter {
        claimLiability[token] += amount;
    }

    /// @inheritdoc ITokenRecoveryManager
    function releaseClaim(address token, uint256 amount) external override onlyRouter {
        uint256 liability = claimLiability[token];
        if (liability < amount) revert ClaimLiabilityInsufficient();
        claimLiability[token] = liability - amount;
    }

    /// @inheritdoc ITokenRecoveryManager
    function queueTokenRecovery(address token, address recipient, uint256 amount)
        external
        override
        nonReentrant
        returns (uint64 id)
    {
        _requireAdmin();
        if (recipient == address(0) || recipient == ROUTER) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();
        if (amount > _surplus(token)) revert RecoveryExceedsSurplus();

        id = ++_recoveryCount;
        uint64 eta = uint64(block.timestamp) + IHyperionRouter(ROUTER).timelockDelay();
        uint64 expiresAt = eta + IHyperionRouter(ROUTER).GRACE_PERIOD();
        _recoveries[id] = QueuedTokenRecovery({
            id: id,
            token: token,
            recipient: recipient,
            amount: amount,
            queuedAt: uint64(block.timestamp),
            eta: eta,
            expiresAt: expiresAt,
            executed: false,
            cancelled: false
        });
        emit TokenRecoveryQueued(id, token, recipient, amount, eta, expiresAt);
    }

    /// @inheritdoc ITokenRecoveryManager
    function cancelTokenRecovery(uint64 id) external override nonReentrant {
        if (!_hasRole(DEFAULT_ADMIN_ROLE, msg.sender) && !_hasRole(GUARDIAN_ROLE, msg.sender)) {
            revert Unauthorized();
        }
        QueuedTokenRecovery storage recovery = _recoveries[id];
        if (recovery.id == 0 || recovery.cancelled) revert TimelockNotQueued();
        if (recovery.executed) revert TimelockAlreadyExecuted();
        recovery.cancelled = true;
        emit TokenRecoveryCancelled(id, msg.sender);
    }

    /// @inheritdoc ITokenRecoveryManager
    function executeTokenRecovery(uint64 id) external override nonReentrant {
        _requireAdmin();
        QueuedTokenRecovery storage recovery = _recoveries[id];
        if (recovery.id == 0 || recovery.cancelled) revert TimelockNotQueued();
        if (recovery.executed) revert TimelockAlreadyExecuted();
        if (block.timestamp < recovery.eta) revert TimelockNotReady(recovery.eta);
        if (block.timestamp > recovery.expiresAt) revert TimelockExpired(recovery.expiresAt);
        if (recovery.amount > _surplus(recovery.token)) revert RecoveryExceedsSurplus();

        IERC20 token = IERC20(recovery.token);
        uint256 routerBefore = token.balanceOf(ROUTER);
        uint256 liability = claimLiability[recovery.token];
        if (routerBefore < liability || recovery.amount > routerBefore - liability) {
            revert RecoveryExceedsSurplus();
        }
        uint256 recipientBefore = token.balanceOf(recovery.recipient);

        recovery.executed = true;
        IHyperionRouter(ROUTER).completeTokenRecovery(recovery.token, recovery.recipient, recovery.amount);
        _requireExactDelta(token.balanceOf(ROUTER), routerBefore, recovery.amount);
        _requireExactDelta(recipientBefore, token.balanceOf(recovery.recipient), recovery.amount);
        emit TokenRecovered(id, recovery.token, recovery.recipient, recovery.amount);
    }

    /// @inheritdoc ITokenRecoveryManager
    function queuedTokenRecovery(uint64 id) external view override returns (QueuedTokenRecovery memory) {
        return _recoveries[id];
    }

    /// @inheritdoc ITokenRecoveryManager
    function tokenRecoveryCount() external view override returns (uint64) {
        return _recoveryCount;
    }

    function _surplus(address token) private view returns (uint256) {
        if (token.code.length == 0) revert TokenRecoveryForbidden();
        TokenConfig memory config = IHyperionRouter(ROUTER).tokenConfig(token);
        if (config.registered) revert TokenRecoveryForbidden();

        uint256 balance = IERC20(token).balanceOf(ROUTER);
        uint256 liability = claimLiability[token];
        if (balance < liability) revert RecoveryExceedsSurplus();
        return balance - liability;
    }

    function _requireExactDelta(uint256 lowBalance, uint256 highBalance, uint256 amount) private pure {
        if (highBalance < lowBalance || highBalance - lowBalance != amount) revert InvalidAmount();
    }

    function _requireAdmin() private view {
        if (!_hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert Unauthorized();
    }

    function _hasRole(bytes32 role, address account) private view returns (bool) {
        return IAccessControl(ROUTER).hasRole(role, account);
    }

    modifier onlyRouter() {
        if (msg.sender != ROUTER) revert Unauthorized();
        _;
    }
}
