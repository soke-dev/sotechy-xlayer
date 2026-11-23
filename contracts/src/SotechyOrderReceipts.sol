// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Sotechy order receipts on X Layer
/// @notice One soulbound NFT per order, minted to the buyer when they pay. The escrow moves its status as the
/// TapeOut circuits decide: held, shipped, on hold, delivered (store paid) or refunded. The picture is drawn on
/// chain from that status. A receipt holds no amounts and no personal details.
contract SotechyOrderReceipts {
    enum Status {
        None,
        Held, // paid; the money waits in the escrow
        Shipped, // the store sent it
        OnHold, // a dispute is open
        Delivered, // the circuits released the money to the store
        Refunded // the circuits sent the money back to the buyer
    }

    struct Receipt {
        address holder;
        uint32 storeId;
        Status status;
        uint40 issuedAt;
        uint40 updatedAt;
    }

    string public constant name = "Sotechy Order Receipts";
    string public constant symbol = "SORDER";

    address public owner;
    address public pendingOwner;
    /// @notice Contracts allowed to issue receipts and move their status (the escrow)
    mapping(address => bool) public isIssuer;

    mapping(uint256 => Receipt) private _receipts;
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    /// @notice ERC-4906: tells explorers and wallets to refresh the picture
    event MetadataUpdate(uint256 tokenId);
    event StatusChanged(uint256 indexed orderId, Status status);
    event IssuerSet(address indexed issuer, bool allowed);
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);

    error NotOwner();
    error NotIssuer();
    error ZeroAddress();
    error ReceiptExists(uint256 orderId);
    error UnknownReceipt(uint256 orderId);
    error BadStatus();
    error Soulbound();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyIssuer() {
        if (!isIssuer[msg.sender]) revert NotIssuer();
        _;
    }

    constructor(address owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
    }

    // ------------------------------------------------------------------
    // Issuer: the escrow
    // ------------------------------------------------------------------

    /// @notice The order's receipt, minted to the buyer when they pay. Its token id is the order id.
    function issue(uint256 orderId, address to, uint32 storeId) external onlyIssuer {
        if (to == address(0)) revert ZeroAddress();
        if (_receipts[orderId].holder != address(0)) revert ReceiptExists(orderId);
        _receipts[orderId] = Receipt(to, storeId, Status.Held, uint40(block.timestamp), uint40(block.timestamp));
        balanceOf[to] += 1;
        totalSupply += 1;
        emit Transfer(address(0), to, orderId);
        emit StatusChanged(orderId, Status.Held);
    }

    function setStatus(uint256 orderId, Status status) external onlyIssuer {
        Receipt storage r = _receipts[orderId];
        if (r.holder == address(0)) revert UnknownReceipt(orderId);
        if (status == Status.None) revert BadStatus();
        if (r.status == status) return;
        r.status = status;
        r.updatedAt = uint40(block.timestamp);
        emit StatusChanged(orderId, status);
        emit MetadataUpdate(orderId);
    }

    // ------------------------------------------------------------------
    // Owner
    // ------------------------------------------------------------------

    function setIssuer(address issuer, bool allowed) external onlyOwner {
        if (issuer == address(0)) revert ZeroAddress();
        isIssuer[issuer] = allowed;
        emit IssuerSet(issuer, allowed);
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

    // ------------------------------------------------------------------
    // Reading
    // ------------------------------------------------------------------

    function receipt(uint256 orderId) external view returns (Receipt memory) {
        return _receipts[orderId];
    }

    function ownerOf(uint256 orderId) public view returns (address holder) {
        holder = _receipts[orderId].holder;
        if (holder == address(0)) revert UnknownReceipt(orderId);
    }

    function tokenURI(uint256 orderId) external view returns (string memory) {
        Receipt memory r = _receipts[orderId];
        if (r.holder == address(0)) revert UnknownReceipt(orderId);
        string memory id = _toString(orderId);
        string memory json = string.concat(
            '{"name":"Sotechy receipt #',
            id,
            '","description":"Order ',
            id,
            " at Sotechy store ",
            _toString(r.storeId),
            ": ",
            _label(r.status),
            '. The money moves only as TapeOut circuits on X Layer decide.","image":"data:image/svg+xml;base64,',
            _base64(bytes(_picture(id, r))),
            '","attributes":[{"trait_type":"Status","value":"',
            _label(r.status),
            '"},{"trait_type":"Store","value":"',
            _toString(r.storeId),
            '"},{"display_type":"date","trait_type":"Issued","value":',
            _toString(r.issuedAt),
            '},{"display_type":"date","trait_type":"Updated","value":',
            _toString(r.updatedAt),
            "}]}"
        );
        return string.concat("data:application/json;base64,", _base64(bytes(json)));
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        // ERC-165, ERC-721, ERC-721 metadata, ERC-4906
        return id == 0x01ffc9a7 || id == 0x80ac58cd || id == 0x5b5e139f || id == 0x49064906;
    }

    // Soulbound: a receipt stays with the buyer
    function getApproved(uint256) external pure returns (address) {
        return address(0);
    }

    function isApprovedForAll(address, address) external pure returns (bool) {
        return false;
    }

    function approve(address, uint256) external pure {
        revert Soulbound();
    }

    function setApprovalForAll(address, bool) external pure {
        revert Soulbound();
    }

    function transferFrom(address, address, uint256) external pure {
        revert Soulbound();
    }

    function safeTransferFrom(address, address, uint256) external pure {
        revert Soulbound();
    }

    function safeTransferFrom(address, address, uint256, bytes calldata) external pure {
        revert Soulbound();
    }

    // ------------------------------------------------------------------
    // The picture
    // ------------------------------------------------------------------

    function _label(Status s) internal pure returns (string memory) {
        if (s == Status.Held) return "Paid, money held";
        if (s == Status.Shipped) return "On its way";
        if (s == Status.OnHold) return "On hold";
        if (s == Status.Delivered) return "Delivered, store paid";
        return "Refunded";
    }

    function _colour(Status s) internal pure returns (string memory) {
        if (s == Status.Held) return "#FDB913";
        if (s == Status.Shipped) return "#F7931E";
        if (s == Status.OnHold) return "#F26B5E";
        if (s == Status.Delivered) return "#22C55E";
        return "#A8A29E";
    }

    /// @dev How far along the bar is, out of 400
    function _progress(Status s) internal pure returns (string memory) {
        if (s == Status.Held) return "130";
        if (s == Status.Shipped || s == Status.OnHold) return "260";
        return "400";
    }

    function _picture(string memory id, Receipt memory r) internal pure returns (string memory) {
        string memory colour = _colour(r.status);
        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 500 500" font-family="Helvetica,Arial,sans-serif">',
            '<rect width="500" height="500" rx="36" fill="#17120E"/>',
            '<circle cx="250" cy="150" r="96" fill="',
            colour,
            '"/><rect x="154" y="150" width="192" height="100" fill="#17120E"/>',
            '<text x="50" y="300" fill="#FFF1DF" font-size="34" font-weight="700">Sotechy receipt</text>',
            '<text x="50" y="338" fill="#FDB913" font-size="20">#',
            id,
            " \xc2\xb7 store ",
            _toString(r.storeId),
            '</text><rect x="50" y="372" width="400" height="16" rx="8" fill="#3A322C"/>',
            '<rect x="50" y="372" width="',
            _progress(r.status),
            '" height="16" rx="8" fill="',
            colour,
            '"/><text x="50" y="436" fill="',
            colour,
            '" font-size="30" font-weight="700">',
            _label(r.status),
            '</text><text x="50" y="470" fill="#8C8178" font-size="15">X Layer \xc2\xb7 decided by TapeOut circuits</text></svg>'
        );
    }

    function _toString(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 len;
        for (uint256 t = v; t != 0; t /= 10) len++;
        bytes memory out = new bytes(len);
        for (; v != 0; v /= 10) out[--len] = bytes1(uint8(48 + (v % 10)));
        return string(out);
    }

    function _base64(bytes memory data) internal pure returns (string memory) {
        if (data.length == 0) return "";
        bytes memory table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        bytes memory out = new bytes(4 * ((data.length + 2) / 3));
        uint256 j;
        for (uint256 i = 0; i < data.length; i += 3) {
            uint256 a = uint8(data[i]);
            uint256 b = i + 1 < data.length ? uint8(data[i + 1]) : 0;
            uint256 c = i + 2 < data.length ? uint8(data[i + 2]) : 0;
            uint256 n = (a << 16) | (b << 8) | c;
            out[j++] = table[(n >> 18) & 63];
            out[j++] = table[(n >> 12) & 63];
            out[j++] = i + 1 < data.length ? table[(n >> 6) & 63] : bytes1("=");
            out[j++] = i + 2 < data.length ? table[n & 63] : bytes1("=");
        }
        return string(out);
    }
}
