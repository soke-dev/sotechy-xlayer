// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ITapeoutBeacon, ITapeoutProcessor} from "./interfaces/ITapeout.sol";
import {SotechyOrderReceipts} from "./SotechyOrderReceipts.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice EIP-2612: approving by signature, so the buyer needs no OKB for gas
interface IERC20Permit {
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external;
}

interface ISotechyTokens {
    function mint(uint256 id, address to, uint256 amount, bytes32 ref) external;
}

/// @title Sotechy escrow on X Layer
/// @notice A buyer pays for an order in USDT and the money waits here. TapeOut circuits decide what happens to
/// it, and this contract does exactly what they answer:
///   - Order Verdict: release to the store, refund the buyer, or neither, from the order's facts;
///   - New-Store Limit: a new store's bigger orders wait for a Sotechy review before release;
///   - Store Breaker: a dispute trips the store's breaker, pausing its releases until Sotechy clears it.
/// Anyone can call `settle`. Nobody, Sotechy included, can send the money anywhere else; Sotechy's only
/// emergency power is to send a paid order's money back to its buyer.
contract SotechyEscrow {
    // ------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------

    enum Stage {
        None,
        Open, // terms set by Sotechy, waiting for the buyer to pay
        Paid, // the money is here
        Released, // paid to the store
        Refunded // paid back to the buyer
    }

    struct Order {
        // Terms, set by Sotechy when the buyer chooses to pay on X Layer
        address payTo; // the store's payout address
        uint96 amount; // USDT, in its base units
        uint32 storeId;
        uint40 payBy; // the buyer pays before this
        uint40 shipBy; // the store ships before this, or the buyer gets the money back
        uint16 feeBps; // Sotechy's fee on release, fixed when the order opens
        uint32 tokenId; // the store's token on SotechyTokens
        uint96 tokens; // the store tokens the buyer earns when the money is released
        // What happened
        Stage stage;
        address buyer;
        uint40 paidAt;
        uint40 shippedAt;
        bool delivered;
        bool disputeOpen;
        bool buyerWon;
        bool cancelled;
        bool reviewed; // Sotechy reviewed an order above a new store's limit
    }

    struct Store {
        bool verified; // passed Sotechy's checks and isn't suspended
        bool established; // past the new-store limit
        uint8 limit; // the largest order a new store gets released automatically, in `limitUnit` steps
        bytes1 breaker; // the Store Breaker circuit's memory (bit 0: tripped)
    }

    // ------------------------------------------------------------------
    // State
    // ------------------------------------------------------------------

    IERC20 public immutable usdt;
    ITapeoutProcessor public immutable processor;
    ITapeoutBeacon public immutable beacon;

    /// @notice The processor code and circuit implementation this escrow trusts. If TapeOut upgrades either,
    /// nothing is decided until the owner has reviewed the change and trusts it again.
    bytes32 public processorCodehash;
    address public processorImplementation;

    uint256 public verdictCircuit;
    uint256 public limitCircuit;
    uint256 public breakerCircuit;

    address public owner;
    address public pendingOwner;
    mapping(address => bool) public isOperator;
    /// @notice Paused: no new orders or payments. Settling, and refunds, still work.
    bool public paused;

    SotechyOrderReceipts public receipts;
    ISotechyTokens public rewards;
    address public treasury;
    uint16 public feeBps;
    /// @notice After shipping, how long the buyer has to complain before the money can be released anyway
    uint40 public confirmWindow = 3 days;
    /// @notice One step of a new store's limit, in USDT base units (default $10 with 6 decimals)
    uint96 public limitUnit = 10e6;

    mapping(uint256 => Order) private _orders;
    mapping(uint32 => Store) public stores;

    uint256 private constant MAX_FEE_BPS = 1500;
    /// @dev Gas for one circuit call: about 2,400 gas a gate, and these circuits have under 50
    uint256 private constant CIRCUIT_GAS = 1_000_000;
    uint256 private _lock = 1;

    // ------------------------------------------------------------------
    // Events and errors
    // ------------------------------------------------------------------

    event OrderOpened(uint256 indexed orderId, uint32 indexed storeId, address payTo, uint256 amount, uint40 payBy, uint40 shipBy);
    event OrderWithdrawn(uint256 indexed orderId);
    event Paid(uint256 indexed orderId, address indexed buyer, uint256 amount);
    event Shipped(uint256 indexed orderId);
    event Delivered(uint256 indexed orderId);
    event DisputeOpened(uint256 indexed orderId);
    event DisputeResolved(uint256 indexed orderId, bool buyerWon);
    event Cancelled(uint256 indexed orderId);
    event Reviewed(uint256 indexed orderId);
    /// @notice What the circuits were asked and what they answered
    event Verdict(uint256 indexed orderId, bytes inputs, bytes outputs, bool limitOk, bool breakerOk);
    event Released(uint256 indexed orderId, address indexed payTo, uint256 toStore, uint256 fee);
    event Refunded(uint256 indexed orderId, address indexed buyer, uint256 amount);
    event EmergencyRefund(uint256 indexed orderId, address indexed buyer, uint256 amount);
    event TokensEarned(uint256 indexed orderId, uint256 tokenId, uint256 amount, bool minted);
    event StoreSet(uint32 indexed storeId, bool verified, bool established, uint8 limit);
    event BreakerChanged(uint32 indexed storeId, bool tripped);
    event CircuitsSet(uint256 verdict, uint256 limit, uint256 breaker);
    event ProcessorTrusted(bytes32 codehash, address implementation);
    event OperatorSet(address indexed operator, bool allowed);
    event SettingsChanged();
    event PausedSet(bool paused);
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);

    error NotOwner();
    error NotOperator();
    error NotAllowed();
    error IsPaused();
    error ZeroAddress();
    error BadTerms();
    error WrongStage(uint256 orderId, Stage stage);
    error PaymentWindowClosed(uint256 orderId);
    error AlreadyDone();
    error NothingToDo(uint256 orderId);
    error CircuitsNotSet();
    error CircuitFailed(uint256 circuitId);
    error CircuitMismatch(uint256 circuitId);
    error ProcessorChanged();
    error TransferFailed();
    error TooHigh();
    error Reentered();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyOperator() {
        if (!isOperator[msg.sender]) revert NotOperator();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert IsPaused();
        _;
    }

    modifier nonReentrant() {
        if (_lock != 1) revert Reentered();
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(address owner_, address operator_, IERC20 usdt_, ITapeoutProcessor processor_, ITapeoutBeacon beacon_) {
        if (owner_ == address(0) || operator_ == address(0)) revert ZeroAddress();
        if (address(usdt_) == address(0) || address(processor_) == address(0) || address(beacon_) == address(0)) {
            revert ZeroAddress();
        }
        owner = owner_;
        isOperator[operator_] = true;
        usdt = usdt_;
        processor = processor_;
        beacon = beacon_;
        treasury = owner_;
        // Trust the processor as it is today
        processorCodehash = address(processor_).codehash;
        processorImplementation = beacon_.implementation();
        emit OwnershipTransferred(address(0), owner_);
        emit OperatorSet(operator_, true);
        emit ProcessorTrusted(processorCodehash, processorImplementation);
    }

    // ------------------------------------------------------------------
    // The order's life
    // ------------------------------------------------------------------

    /// @notice Sotechy sets an order's terms when the buyer picks "Pay with USDT on X Layer"
    function open(
        uint256 orderId,
        address payTo,
        uint32 storeId,
        uint96 amount,
        uint40 payBy,
        uint40 shipBy,
        uint32 tokenId,
        uint96 tokens
    ) external onlyOperator whenNotPaused {
        if (payTo == address(0)) revert ZeroAddress();
        if (amount == 0 || payBy <= block.timestamp || shipBy <= block.timestamp) revert BadTerms();
        Order storage o = _orders[orderId];
        if (o.stage != Stage.None) revert WrongStage(orderId, o.stage);
        o.payTo = payTo;
        o.amount = amount;
        o.storeId = storeId;
        o.payBy = payBy;
        o.shipBy = shipBy;
        o.feeBps = feeBps;
        o.tokenId = tokenId;
        o.tokens = tokens;
        o.stage = Stage.Open;
        emit OrderOpened(orderId, storeId, payTo, amount, payBy, shipBy);
    }

    /// @notice Sotechy takes back terms nobody paid (the order was cancelled in the app, or they expired)
    function withdraw(uint256 orderId) external onlyOperator {
        Order storage o = _orders[orderId];
        if (o.stage != Stage.Open) revert WrongStage(orderId, o.stage);
        delete _orders[orderId];
        emit OrderWithdrawn(orderId);
    }

    /// @notice The buyer pays the exact amount (after approving it). The receipt NFT is minted to them.
    function pay(uint256 orderId) external nonReentrant whenNotPaused {
        _payFrom(orderId, msg.sender);
    }

    /// @notice Sotechy pays the gas: the buyer signs a USDT permit for the order's exact amount, and Sotechy's
    /// operator sends it. Only the operator can, so a permit can't be used for an order the buyer didn't choose.
    function payFor(uint256 orderId, address buyer, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        onlyOperator
        nonReentrant
        whenNotPaused
    {
        if (buyer == address(0)) revert ZeroAddress();
        // If someone sends the permit first, the allowance is already there and the payment still goes through
        try IERC20Permit(address(usdt)).permit(buyer, address(this), _orders[orderId].amount, deadline, v, r, s) {} catch {}
        _payFrom(orderId, buyer);
    }

    function _payFrom(uint256 orderId, address buyer) internal {
        Order storage o = _orders[orderId];
        if (o.stage != Stage.Open) revert WrongStage(orderId, o.stage);
        if (block.timestamp > o.payBy) revert PaymentWindowClosed(orderId);
        o.stage = Stage.Paid;
        o.buyer = buyer;
        o.paidAt = uint40(block.timestamp);
        _pull(buyer, o.amount);
        if (address(receipts) != address(0)) receipts.issue(orderId, buyer, o.storeId);
        emit Paid(orderId, buyer, o.amount);
    }

    /// @notice The store (or Sotechy, from the store's dashboard) marks the order sent
    function markShipped(uint256 orderId) external {
        Order storage o = _paid(orderId);
        if (msg.sender != o.payTo && !isOperator[msg.sender]) revert NotAllowed();
        if (o.shippedAt != 0 || o.cancelled) revert AlreadyDone();
        o.shippedAt = uint40(block.timestamp);
        if (!o.disputeOpen) _receipt(orderId, SotechyOrderReceipts.Status.Shipped);
        emit Shipped(orderId);
    }

    /// @notice The buyer (or Sotechy, relaying "I got it" from the app) confirms delivery. Settles at once if the circuits release.
    function confirmDelivered(uint256 orderId) external nonReentrant {
        Order storage o = _paid(orderId);
        if (msg.sender != o.buyer && !isOperator[msg.sender]) revert NotAllowed();
        if (o.delivered) revert AlreadyDone();
        o.delivered = true;
        emit Delivered(orderId);
        _settle(orderId, false);
    }

    /// @notice The buyer (or Sotechy, for them) reports a problem: the money stays put, and the store's breaker trips
    function openDispute(uint256 orderId) external nonReentrant {
        Order storage o = _paid(orderId);
        if (msg.sender != o.buyer && !isOperator[msg.sender]) revert NotAllowed();
        if (o.disputeOpen) revert AlreadyDone();
        o.disputeOpen = true;
        _stepBreaker(o.storeId, true, false);
        _receipt(orderId, SotechyOrderReceipts.Status.OnHold);
        emit DisputeOpened(orderId);
    }

    /// @notice Sotechy resolves a dispute. Settles at once if the circuits now decide.
    function resolveDispute(uint256 orderId, bool buyerWins) external onlyOperator nonReentrant {
        Order storage o = _paid(orderId);
        if (!o.disputeOpen) revert AlreadyDone();
        o.disputeOpen = false;
        o.buyerWon = buyerWins;
        if (!buyerWins) {
            _receipt(orderId, o.shippedAt != 0 ? SotechyOrderReceipts.Status.Shipped : SotechyOrderReceipts.Status.Held);
        }
        emit DisputeResolved(orderId, buyerWins);
        _settle(orderId, false);
    }

    /// @notice The store (or Sotechy) cancels a paid order that wasn't delivered: the buyer is refunded
    function cancel(uint256 orderId) external nonReentrant {
        Order storage o = _paid(orderId);
        if (msg.sender != o.payTo && !isOperator[msg.sender]) revert NotAllowed();
        if (o.cancelled || o.delivered) revert AlreadyDone();
        o.cancelled = true;
        emit Cancelled(orderId);
        _settle(orderId, false);
    }

    /// @notice Sotechy reviewed an order above a new store's limit; it can be released like any other
    function approveReview(uint256 orderId) external onlyOperator nonReentrant {
        Order storage o = _paid(orderId);
        if (o.reviewed) revert AlreadyDone();
        o.reviewed = true;
        emit Reviewed(orderId);
        _settle(orderId, false);
    }

    /// @notice Anyone can ask the circuits about an order, and the escrow does what they answer
    function settle(uint256 orderId) external nonReentrant {
        _settle(orderId, true);
    }

    // ------------------------------------------------------------------
    // Asking the circuits
    // ------------------------------------------------------------------

    /// @notice What the circuits would decide for this order now, for apps and the public order checker.
    /// `verdictRelease` is the Order Verdict circuit's own answer; `release` also needs the limit and the breaker.
    function verdictOf(uint256 orderId)
        external
        view
        returns (bool release, bool refund, bool limitOk, bool breakerOk, bool verdictRelease)
    {
        Order storage o = _orders[orderId];
        if (o.stage != Stage.Paid) return (false, false, false, false, false);
        (,, verdictRelease, refund, limitOk, breakerOk) = _decide(o);
        release = verdictRelease && limitOk && breakerOk;
    }

    function order(uint256 orderId) external view returns (Order memory) {
        return _orders[orderId];
    }

    /// @notice Is this store's breaker tripped?
    function breakerTripped(uint32 storeId) external view returns (bool) {
        return stores[storeId].breaker & 0x01 != 0;
    }

    function _settle(uint256 orderId, bool mustDecide) internal {
        Order storage o = _orders[orderId];
        if (o.stage != Stage.Paid) {
            if (mustDecide) revert WrongStage(orderId, o.stage);
            return;
        }
        (bytes memory inputs, bytes memory outputs, bool verdictRelease, bool refund, bool limitOk, bool breakerOk) = _decide(o);
        // A release also needs the store within its limit (or reviewed) and its breaker clear; a refund never waits
        bool release = verdictRelease && limitOk && breakerOk;
        if (!release && !refund) {
            if (mustDecide) revert NothingToDo(orderId);
            return;
        }
        emit Verdict(orderId, inputs, outputs, limitOk, breakerOk);
        if (release) _release(orderId, o);
        else _refund(orderId, o);
    }

    /// @dev Builds the order's facts as input bits and asks all three circuits. `release` here is the Order Verdict's
    /// own answer; callers combine it with `limitOk` and `breakerOk`.
    function _decide(Order storage o)
        internal
        view
        returns (bytes memory inputs, bytes memory outputs, bool release, bool refund, bool limitOk, bool breakerOk)
    {
        if (verdictCircuit == 0) revert CircuitsNotSet();
        _checkProcessor();
        Store storage s = stores[o.storeId];
        bool shipped = o.shippedAt != 0;
        // Order Verdict pins, least significant bit first (circuits/src/circuits.ts):
        // paid, storeVerified, shipped, delivered, confirmWindowOver, shipDeadlinePassed, disputeOpen, buyerWonDispute, storeCancelled
        uint256 bits = 1
            | _bit(s.verified, 1)
            | _bit(shipped, 2)
            | _bit(o.delivered, 3)
            | _bit(shipped && block.timestamp >= uint256(o.shippedAt) + confirmWindow, 4)
            | _bit(block.timestamp > o.shipBy, 5)
            | _bit(o.disputeOpen, 6)
            | _bit(o.buyerWon, 7)
            | _bit(o.cancelled, 8);
        inputs = abi.encodePacked(bytes1(uint8(bits)), bytes1(uint8(bits >> 8)));
        outputs = _eval(verdictCircuit, inputs, 1);
        release = uint8(outputs[0]) & 1 != 0;
        refund = uint8(outputs[0]) & 2 != 0;

        // New-Store Limit pins: amount (8 bits), limit (8 bits), established
        uint256 units = (uint256(o.amount) + limitUnit - 1) / limitUnit;
        if (units > 255) units = 255;
        bytes memory limitIn = abi.encodePacked(bytes1(uint8(units)), bytes1(s.limit), bytes1(s.established || o.reviewed ? 0x01 : 0x00));
        limitOk = uint8(_eval(limitCircuit, limitIn, 1)[0]) & 1 != 0;

        // Store Breaker: a beat with nothing new reads whether the store is clear
        (, bytes memory breakerOut) = _step(breakerCircuit, abi.encodePacked(s.breaker), hex"00");
        breakerOk = uint8(breakerOut[0]) & 1 != 0;
    }

    function _stepBreaker(uint32 storeId, bool opened, bool cleared) internal {
        if (breakerCircuit == 0) revert CircuitsNotSet();
        _checkProcessor();
        Store storage s = stores[storeId];
        bytes1 before = s.breaker;
        (bytes memory newState,) = _step(breakerCircuit, abi.encodePacked(before), abi.encodePacked(bytes1(uint8(_bit(opened, 0) | _bit(cleared, 1)))));
        s.breaker = newState[0] & 0x01;
        if (s.breaker != before) emit BreakerChanged(storeId, s.breaker != 0);
    }

    function _eval(uint256 id, bytes memory inputs, uint256 outBytes) internal view returns (bytes memory out) {
        try processor.eval{gas: CIRCUIT_GAS}(id, inputs) returns (bytes memory o) {
            out = o;
        } catch {
            revert CircuitFailed(id);
        }
        if (out.length != outBytes) revert CircuitFailed(id);
    }

    function _step(uint256 id, bytes memory state, bytes memory inputs) internal view returns (bytes memory newState, bytes memory out) {
        try processor.step{gas: CIRCUIT_GAS}(id, state, inputs) returns (bytes memory s, bytes memory o) {
            (newState, out) = (s, o);
        } catch {
            revert CircuitFailed(id);
        }
        if (newState.length != 1 || out.length != 1) revert CircuitFailed(id);
    }

    function _checkProcessor() internal view {
        if (address(processor).codehash != processorCodehash || beacon.implementation() != processorImplementation) {
            revert ProcessorChanged();
        }
    }

    // ------------------------------------------------------------------
    // Moving money
    // ------------------------------------------------------------------

    function _release(uint256 orderId, Order storage o) internal {
        o.stage = Stage.Released;
        uint256 fee = (uint256(o.amount) * o.feeBps) / 10_000;
        uint256 toStore = uint256(o.amount) - fee;
        _receipt(orderId, SotechyOrderReceipts.Status.Delivered);
        _push(o.payTo, toStore);
        if (fee != 0) _push(treasury, fee);
        emit Released(orderId, o.payTo, toStore, fee);
        // Tokens are earned only now, when the money is released. A failed mint never holds up the store's money.
        if (o.tokens != 0 && address(rewards) != address(0)) {
            bool minted;
            try rewards.mint(o.tokenId, o.buyer, o.tokens, bytes32(orderId)) {
                minted = true;
            } catch {}
            emit TokensEarned(orderId, o.tokenId, o.tokens, minted);
        }
    }

    function _refund(uint256 orderId, Order storage o) internal {
        o.stage = Stage.Refunded;
        _receipt(orderId, SotechyOrderReceipts.Status.Refunded);
        _push(o.buyer, o.amount);
        emit Refunded(orderId, o.buyer, o.amount);
    }

    function _pull(address from, uint256 amount) internal {
        (bool ok, bytes memory ret) = address(usdt).call(abi.encodeCall(IERC20.transferFrom, (from, address(this), amount)));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }

    function _push(address to, uint256 amount) internal {
        (bool ok, bytes memory ret) = address(usdt).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }

    function _receipt(uint256 orderId, SotechyOrderReceipts.Status status) internal {
        if (address(receipts) != address(0)) receipts.setStatus(orderId, status);
    }

    function _paid(uint256 orderId) internal view returns (Order storage o) {
        o = _orders[orderId];
        if (o.stage != Stage.Paid) revert WrongStage(orderId, o.stage);
    }

    function _bit(bool on, uint256 i) internal pure returns (uint256) {
        return on ? 1 << i : 0;
    }

    // ------------------------------------------------------------------
    // Sotechy's operator: stores
    // ------------------------------------------------------------------

    function setStore(uint32 storeId, bool verified, bool established, uint8 limit) external onlyOperator {
        Store storage s = stores[storeId];
        (s.verified, s.established, s.limit) = (verified, established, limit);
        emit StoreSet(storeId, verified, established, limit);
    }

    /// @notice After looking into a store's dispute, Sotechy clears its breaker (through the circuit)
    function clearBreaker(uint32 storeId) external onlyOperator {
        _stepBreaker(storeId, false, true);
    }

    // ------------------------------------------------------------------
    // Owner: the rules
    // ------------------------------------------------------------------

    /// @notice Points the escrow at its three circuits, checking each one's shape and exact bytes
    function setCircuits(uint256 verdict, uint256 limit, uint256 breaker, bytes32[3] calldata netlistHashes) external onlyOwner {
        _checkCircuit(verdict, 9, 2, 0, netlistHashes[0]);
        _checkCircuit(limit, 17, 1, 0, netlistHashes[1]);
        _checkCircuit(breaker, 2, 1, 1, netlistHashes[2]);
        (verdictCircuit, limitCircuit, breakerCircuit) = (verdict, limit, breaker);
        emit CircuitsSet(verdict, limit, breaker);
    }

    function _checkCircuit(uint256 id, uint32 nIn, uint32 nOut, uint32 nState, bytes32 netlistHash) internal view {
        (uint32 i, uint32 o, uint32 s,) = processor.circuitInfo(id);
        if (i != nIn || o != nOut || s != nState || keccak256(processor.netlist(id)) != netlistHash) revert CircuitMismatch(id);
    }

    /// @notice After reviewing a TapeOut upgrade, trust the processor as it is now
    function trustProcessor() external onlyOwner {
        processorCodehash = address(processor).codehash;
        processorImplementation = beacon.implementation();
        emit ProcessorTrusted(processorCodehash, processorImplementation);
    }

    /// @notice The one thing Sotechy can do with a paid order's money: send it back to the buyer. Only while paused.
    function emergencyRefund(uint256 orderId) external onlyOwner nonReentrant {
        if (!paused) revert NotAllowed();
        Order storage o = _paid(orderId);
        o.stage = Stage.Refunded;
        _receipt(orderId, SotechyOrderReceipts.Status.Refunded);
        _push(o.buyer, o.amount);
        emit EmergencyRefund(orderId, o.buyer, o.amount);
    }

    function setReceipts(SotechyOrderReceipts receipts_) external onlyOwner {
        receipts = receipts_;
        emit SettingsChanged();
    }

    function setRewards(ISotechyTokens rewards_) external onlyOwner {
        rewards = rewards_;
        emit SettingsChanged();
    }

    function setFee(uint16 feeBps_, address treasury_) external onlyOwner {
        if (feeBps_ > MAX_FEE_BPS) revert TooHigh();
        if (treasury_ == address(0)) revert ZeroAddress();
        (feeBps, treasury) = (feeBps_, treasury_);
        emit SettingsChanged();
    }

    function setConfirmWindow(uint40 window) external onlyOwner {
        if (window < 1 hours || window > 30 days) revert TooHigh();
        confirmWindow = window;
        emit SettingsChanged();
    }

    function setLimitUnit(uint96 unit) external onlyOwner {
        if (unit == 0) revert BadTerms();
        limitUnit = unit;
        emit SettingsChanged();
    }

    function setOperator(address operator, bool allowed) external onlyOwner {
        if (operator == address(0)) revert ZeroAddress();
        isOperator[operator] = allowed;
        emit OperatorSet(operator, allowed);
    }

    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    function transferOwnership(address to) external onlyOwner {
        pendingOwner = to;
        emit OwnershipTransferStarted(owner, to);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }
}
