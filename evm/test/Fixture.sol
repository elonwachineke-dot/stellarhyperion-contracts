// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {HyperionRouter} from "../src/HyperionRouter.sol";
import {ActionKind, AdminAction, Destination, OutboundRequest, RouteKind} from "../src/HyperionTypes.sol";
import {ITokenRecoveryManager} from "../src/interfaces/ITokenRecoveryManager.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockRailAdapter} from "./mocks/MockRailAdapter.sol";

/// @title The world every router test starts from
/// @notice One router, one token, one adapter per rail, and a set of real Stellar addresses.
/// @dev Two things here are worth knowing before reading any test that inherits it.
/// The test pins the router's configured outbound adapters separately from its inbound rail
/// receiver. Provider authentication belongs to each rail adapter; the router trusts only the
/// configured receiver address for the inbound pull.
///
/// The strkeys are real. They carry genuine CRC16 checksums, and they were generated rather than
/// typed, because a made up one fails the checksum and every test that touched it would fail for
/// a reason that has nothing to do with what it was testing. `G_KEY` and `MUXED_KEY` are the same
/// thirty two bytes on purpose: a muxed address is a base account plus an integer, and a codec
/// that quietly loses the integer would otherwise look correct.
///
/// Every privileged change goes through the timelock, so `_run` exists. Writing the queue, the
/// warp and the execute out longhand in forty tests would bury the one line each test is actually
/// about.
contract Fixture is Test {
    uint8 internal constant PROVIDER_STAGE_DISPATCH = 0;
    uint8 internal constant PROVIDER_STAGE_INBOUND = 1;

    struct ProviderFaultSchedule {
        uint64 seed;
        uint64 dispatchMask;
        uint64 inboundMask;
        uint64 dispatchAttempts;
        uint64 inboundAttempts;
    }

    ProviderFaultSchedule internal providerFaults;

    // Real addresses, checksums and all. The muxed one wraps the account one with id 2^53 + 1,
    // which is past what a double can count to, so a codec that ever round trips through a float
    // fails here rather than in production.
    string internal constant G_ADDR = "GA5ZYIIVYDX5GRF2BKEQD2Y47ZCPG3HX3PUUNPVQ5ZECB57MJG7RLVNR";
    string internal constant C_ADDR = "CAGR5KFYMZYI7WWQ6TWYYZ346T7GNZLKER4DOJTAG3SOB46QLR5RAPSN";
    string internal constant M_ADDR = "MA5ZYIIVYDX5GRF2BKEQD2Y47ZCPG3HX3PUUNPVQ5ZECB57MJG7RKABAAAAAAAAAAFLXQ";

    bytes32 internal constant G_KEY = 0x3b9c2115c0efd344ba0a8901eb1cfe44f36cf7dbe946beb0ee4820f7ec49bf15;
    bytes32 internal constant C_KEY = 0x0d1ea8b866708fdad0f4ed8c677cf4fe66e56a247837266036e4e0f3d05c7b10;
    uint64 internal constant MUXED_ID = 9_007_199_254_740_993;

    string internal constant STELLAR = "stellar";

    uint16 internal constant FEE_BPS = 10;
    uint64 internal constant TIMELOCK = 2 days;
    uint64 internal constant FLOW_WINDOW = 1 hours;

    uint8 internal constant USDC_DECIMALS = 6;
    uint8 internal constant STELLAR_DECIMALS = 7;
    uint256 internal constant FLOW_LIMIT = 1_000_000e6;

    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");
    address internal railReceiver = makeAddr("railReceiver");

    HyperionRouter internal router;
    ITokenRecoveryManager internal recoveryManager;
    MockERC20 internal usdc;

    /// @dev Read once, here, rather than in each test that names a role. `expectRevert` watches
    /// the next external call, and `router.DEFAULT_ADMIN_ROLE()` sitting inside the arguments of
    /// an expected error is an external call, so it quietly becomes the call being watched and
    /// the test passes for the wrong reason.
    bytes32 internal adminRole;
    bytes32 internal guardianRole;
    MockRailAdapter internal cctpRail;
    MockRailAdapter internal itsRail;
    MockRailAdapter internal gmpRail;
    MockRailAdapter internal allbridgeRail;

    function setUp() public virtual {
        _configureProviderFaults(156);
        router = new HyperionRouter(admin, guardian, treasury, FEE_BPS, TIMELOCK, FLOW_WINDOW);
        address recoveryAddress =
            address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", address(router), hex"02")))));
        recoveryManager = ITokenRecoveryManager(recoveryAddress);
        assertEq(recoveryManager.ROUTER(), address(router));
        usdc = new MockERC20("USD Coin", "USDC", USDC_DECIMALS);

        adminRole = router.DEFAULT_ADMIN_ROLE();
        guardianRole = router.GUARDIAN_ROLE();

        cctpRail = new MockRailAdapter(RouteKind.Cctp, address(router));
        itsRail = new MockRailAdapter(RouteKind.AxelarIts, address(router));
        gmpRail = new MockRailAdapter(RouteKind.AxelarGmp, address(router));
        allbridgeRail = new MockRailAdapter(RouteKind.Allbridge, address(router));

        cctpRail.setSupported(STELLAR, true);
        itsRail.setSupported(STELLAR, true);
        gmpRail.setSupported(STELLAR, true);
        allbridgeRail.setSupported(STELLAR, true);

        _setAdapter(RouteKind.Cctp, address(cctpRail));
        _setAdapter(RouteKind.AxelarIts, address(itsRail));
        _setAdapter(RouteKind.AxelarGmp, address(gmpRail));
        _setAdapter(RouteKind.Allbridge, address(allbridgeRail));

        _enableRoute(RouteKind.Cctp, true);
        _enableRoute(RouteKind.AxelarIts, true);
        _enableRoute(RouteKind.AxelarGmp, true);
        _enableRoute(RouteKind.Allbridge, true);

        _registerToken(address(usdc), USDC_DECIMALS, FLOW_LIMIT);
        _setRailReceiver(RouteKind.Cctp, railReceiver);
        assertEq(router.adapter(RouteKind.Cctp), address(cctpRail));
        assertEq(router.railReceiver(RouteKind.Cctp), railReceiver);

        usdc.mint(alice, 10_000_000e6);
        vm.prank(alice);
        usdc.approve(address(router), type(uint256).max);
    }

    /// @dev A compact, seed-backed controller for local provider-failure rehearsals. The masks
    /// are recorded with the seed so a failed run can be replayed without relying on block time.
    function _configureProviderFaults(uint64 seed) internal {
        providerFaults = ProviderFaultSchedule({
            seed: seed,
            dispatchMask: _mixFaultSeed(seed ^ 0x4453504154434848),
            inboundMask: _mixFaultSeed(seed ^ 0x494e424f554e4448),
            dispatchAttempts: 0,
            inboundAttempts: 0
        });
    }

    function _mixFaultSeed(uint64 value) internal pure returns (uint64) {
        unchecked {
            value ^= value >> 30;
            value *= 0xbf58476d1ce4e5b9;
            value ^= value >> 27;
            value *= 0x94d049bb133111eb;
            return value ^ (value >> 31);
        }
    }

    function _nextProviderFault(uint8 stage) internal returns (bool) {
        uint64 attempt;
        uint64 mask;
        if (stage == PROVIDER_STAGE_DISPATCH) {
            attempt = providerFaults.dispatchAttempts++;
            mask = providerFaults.dispatchMask;
        } else {
            require(stage == PROVIDER_STAGE_INBOUND, "unknown provider stage");
            attempt = providerFaults.inboundAttempts++;
            mask = providerFaults.inboundMask;
        }
        return (mask & (uint64(1) << (attempt % 64))) != 0;
    }

    // -------------------------------------------------------------------------------------
    // Timelock shorthand
    // -------------------------------------------------------------------------------------

    /// @dev Queue a change, wait it out, execute it. Returns the id in case a test wants it.
    function _run(AdminAction memory action) internal returns (uint64 id) {
        return _runOn(router, action);
    }

    /// @dev The same, against some other router. A test that wants a half configured deployment
    /// needs one the fixture has not already finished wiring.
    function _runOn(HyperionRouter target, AdminAction memory action) internal returns (uint64 id) {
        vm.prank(admin);
        id = target.queueAction(action);
        vm.warp(block.timestamp + TIMELOCK + 1);
        vm.prank(admin);
        target.executeAction(id);
    }

    /// @dev Queue a change and let the clock run out, without executing it. For a test that
    /// wants to watch what the execution emits, which `_run` would bury under the queue event.
    function _mature(AdminAction memory action) internal returns (uint64 id) {
        vm.prank(admin);
        id = router.queueAction(action);
        vm.warp(block.timestamp + TIMELOCK + 1);
    }

    function _empty(ActionKind kind) internal pure returns (AdminAction memory) {
        return AdminAction({kind: kind, route: RouteKind.Cctp, subject: address(0), amount: 0, decimals: 0});
    }

    function _setAdapter(RouteKind route, address adapterAddress) internal {
        AdminAction memory action = _empty(ActionKind.SetAdapter);
        action.route = route;
        action.subject = adapterAddress;
        _run(action);
    }

    function _setRailReceiver(RouteKind route, address receiver) internal {
        AdminAction memory action = _empty(ActionKind.SetRailReceiver);
        action.route = route;
        action.subject = receiver;
        _run(action);
    }

    function _enableRoute(RouteKind route, bool on) internal {
        AdminAction memory action = _empty(ActionKind.EnableRoute);
        action.route = route;
        action.amount = on ? 1 : 0;
        _run(action);
    }

    function _registerToken(address token, uint8 decimals_, uint256 flowLimit) internal {
        AdminAction memory action = _empty(ActionKind.RegisterToken);
        action.subject = token;
        action.amount = flowLimit;
        action.decimals = decimals_;
        _run(action);
    }

    function _setRouteFlowLimit(address token, RouteKind route, uint256 limit) internal {
        AdminAction memory action = _empty(ActionKind.SetRouteFlowLimit);
        action.route = route;
        action.subject = token;
        action.amount = limit;
        _run(action);
    }

    function _setTokenEnabled(address token, bool on) internal {
        AdminAction memory action = _empty(ActionKind.SetTokenEnabled);
        action.subject = token;
        action.amount = on ? 1 : 0;
        _run(action);
    }

    function _setFeeBps(uint16 bps) internal {
        AdminAction memory action = _empty(ActionKind.SetFeeBps);
        action.amount = bps;
        _run(action);
    }

    // -------------------------------------------------------------------------------------
    // Request shorthand
    // -------------------------------------------------------------------------------------

    function _dest(string memory strkey) internal pure returns (Destination memory) {
        return Destination({chain: STELLAR, strkey: strkey});
    }

    function _request(uint256 amount, RouteKind route) internal pure returns (OutboundRequest memory) {
        return OutboundRequest({
            token: address(0),
            amount: amount,
            route: route,
            destination: _dest(G_ADDR),
            destinationDecimals: STELLAR_DECIMALS,
            minDestinationAmount: 0
        });
    }

    /// @dev A router with nothing wired to it. For tests about a half finished deployment,
    /// which the fixture's own `setUp` has already moved past.
    function _freshRouter() internal returns (HyperionRouter) {
        return new HyperionRouter(admin, guardian, treasury, FEE_BPS, TIMELOCK, FLOW_WINDOW);
    }

    /// @dev Some other asset, over CCTP, to a classic account. For the decimal pairs USDC does
    /// not exercise.
    function _tokenRequest(address token, uint256 amount, uint8 destinationDecimals)
        internal
        pure
        returns (OutboundRequest memory request)
    {
        request = _request(amount, RouteKind.Cctp);
        request.token = token;
        request.destinationDecimals = destinationDecimals;
    }

    /// @dev The common case: USDC, over CCTP, to a classic account, no slippage floor.
    function _usdcRequest(uint256 amount) internal view returns (OutboundRequest memory request) {
        request = _request(amount, RouteKind.Cctp);
        request.token = address(usdc);
    }

    /// @dev Snapshot every account that can hold the test token during a local transfer.
    /// Keeping the rail receiver and both mock rails in the set catches accidental parking or
    /// double-crediting that a router/treasury/sender-only check would miss.
    struct BalanceSnapshot {
        uint256 router;
        uint256 treasury;
        uint256 sender;
        uint256 recipient;
        uint256 railReceiver;
        uint256 cctpRail;
        uint256 itsRail;
        uint256 total;
        uint256 senderNative;
        uint256 recipientNative;
        uint256 routerNative;
        uint256 cctpRailNative;
        uint256 itsRailNative;
        uint256 totalNative;
    }

    function _snapshot(address sender, address recipient) internal view returns (BalanceSnapshot memory s) {
        s.router = usdc.balanceOf(address(router));
        s.treasury = usdc.balanceOf(treasury);
        s.sender = usdc.balanceOf(sender);
        s.recipient = usdc.balanceOf(recipient);
        s.railReceiver = usdc.balanceOf(railReceiver);
        s.cctpRail = usdc.balanceOf(address(cctpRail));
        s.itsRail = usdc.balanceOf(address(itsRail));

        s.senderNative = sender.balance;
        s.recipientNative = recipient.balance;
        s.routerNative = address(router).balance;
        s.cctpRailNative = address(cctpRail).balance;
        s.itsRailNative = address(itsRail).balance;
        address[7] memory accounts =
            [address(router), treasury, sender, recipient, railReceiver, address(cctpRail), address(itsRail)];
        for (uint256 i; i < accounts.length; ++i) {
            bool duplicate;
            for (uint256 j; j < i; ++j) {
                if (accounts[j] == accounts[i]) duplicate = true;
            }
            if (!duplicate) {
                s.total += usdc.balanceOf(accounts[i]);
                s.totalNative += accounts[i].balance;
            }
        }
    }

    /// @dev Assert conservation with an operation name that identifies the failing path.
    function _assertConserved(
        BalanceSnapshot memory before_,
        BalanceSnapshot memory after_,
        string memory operation
    ) internal pure {
        assertEq(after_.total, before_.total, string.concat(operation, ": token balance delta is non-zero"));
        assertEq(
            after_.totalNative,
            before_.totalNative,
            string.concat(operation, ": relay currency balance delta is non-zero")
        );
    }
}
