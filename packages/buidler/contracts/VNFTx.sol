pragma solidity ^0.6.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC1155/ERC1155Holder.sol";

import "@openzeppelin/contracts/utils/EnumerableSet.sol";

import "./interfaces/IMuseToken.sol";
import "./interfaces/IVNFT.sol";
// import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

// SPDX-License-Identifier: MIT

pragma solidity ^0.6.2;

import "@openzeppelin/contracts/introspection/IERC165.sol";

// Extending IERC1155 with mint and burn
interface IERC1155 is IERC165 {
    event TransferSingle(
        address indexed operator,
        address indexed from,
        address indexed to,
        uint256 id,
        uint256 value
    );

    event TransferBatch(
        address indexed operator,
        address indexed from,
        address indexed to,
        uint256[] ids,
        uint256[] values
    );

    event ApprovalForAll(
        address indexed account,
        address indexed operator,
        bool approved
    );

    event URI(string value, uint256 indexed id);

    function balanceOf(address account, uint256 id)
        external
        view
        returns (uint256);

    function balanceOfBatch(address[] calldata accounts, uint256[] calldata ids)
        external
        view
        returns (uint256[] memory);

    function setApprovalForAll(address operator, bool approved) external;

    function isApprovedForAll(address account, address operator)
        external
        view
        returns (bool);

    function safeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes calldata data
    ) external;

    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) external;

    function mint(
        address to,
        uint256 id,
        uint256 amount,
        bytes calldata data
    ) external;

    function mintBatch(
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) external;

    function burn(
        address account,
        uint256 id,
        uint256 value
    ) external;

    function burnBatch(
        address account,
        uint256[] calldata ids,
        uint256[] calldata values
    ) external;
}

// import "@nomiclabs/buidler/console.sol";

// @TODO add "health" system basde on a level time progression algorithm.
contract VNFTx is Ownable, ERC1155Holder {
    using SafeMath for uint256;

    bool paused = false;
    //for upgradability
    address public delegateContract;
    address[] public previousDelegates;
    uint256 public total = 1;

    IVNFT public vnft;
    IMuseToken public muse;
    IERC1155 public addons;

    uint256 public artistPct = 5;

    struct Addon {
        string _type;
        uint256 price;
        uint256 requiredhp;
        uint256 rarity;
        string artistName;
        address artistAddr;
        uint256 quantity;
        uint256 used;
    }

    using EnumerableSet for EnumerableSet.UintSet;

    mapping(uint256 => Addon) public addon;

    mapping(uint256 => EnumerableSet.UintSet) private addonsConsumed;

    //nftid to rarity points
    mapping(uint256 => uint256) public rarity;
    mapping(uint256 => uint256) public challengesUsed;

    //!important, decides which gem score hp is based of
    uint256 public healthGem = 100;
    uint256 public healthGemDays = 1;

    // premium hp is the min requirement for premium features.
    uint256 public premiumHp = 90;
    uint256 public hpMultiplier = 70;
    uint256 public rarityMultiplier = 15;
    uint256 public addonsMultiplier = 15;
    //expected addons to be used for max hp
    uint256 public expectedAddons = 10;

    using Counters for Counters.Counter;
    Counters.Counter private _addonId;

    event DelegateChanged(address oldAddress, address newAddress);
    event BuyAddon(uint256 nftId, uint256 addon, address player);
    event CreateAddon(
        uint256 addonId,
        string _type,
        uint256 rarity,
        uint256 quantity
    );
    event EditAddon(
        uint256 addonId,
        string _type,
        uint256 price,
        uint256 _quantity
    );
    event AttachAddon(uint256 addonId, uint256 nftId);
    event RemoveAddon(uint256 addonId, uint256 nftId);

    constructor(
        IVNFT _vnft,
        IMuseToken _muse,
        address _mainContract,
        IERC1155 _addons
    ) public {
        vnft = _vnft;
        muse = _muse;
        addons = _addons;
        delegateContract = _mainContract;
        previousDelegates.push(delegateContract);
    }

    modifier tokenOwner(uint256 _id) {
        require(
            vnft.ownerOf(_id) == msg.sender ||
                vnft.careTaker(_id, vnft.ownerOf(_id)) == msg.sender,
            "You must own the vNFT or be a care taker"
        );
        _;
    }

    modifier notPaused() {
        require(!paused, "Contract paused!");
        _;
    }

    // get how many addons a pet is using
    function addonsBalanceOf(uint256 _nftId) public view returns (uint256) {
        return addonsConsumed[_nftId].length();
    }

    // get a specific addon
    function addonsOfNftByIndex(uint256 _nftId, uint256 _index)
        public
        view
        returns (uint256)
    {
        return addonsConsumed[_nftId].at(_index);
    }

    function getHp(uint256 _nftId) public view returns (uint256) {
        // A vnft need to get at least x score every two days to be healthy
        uint256 currentScore = vnft.vnftScore(_nftId);
        uint256 timeBorn = vnft.timeVnftBorn(_nftId);
        uint256 daysLived = (now.sub(timeBorn)).div(1 days);

        // multiply by healthy gem divided by 2 (every 2 days)
        uint256 expectedScore = daysLived.mul(healthGem.div(healthGemDays));
        //@TODO calculate minimum expected rarity
        uint256 expectedRarity = 300;
        // get # of addons used
        uint256 addonsUsed = addonsBalanceOf(_nftId);

        // maybe give people 7 days chance to start calculation hp?
        if (
            !vnft.isVnftAlive(_nftId) || daysLived < 7 //not dead || min 7 day of life?
        ) {
            return 0;
        }

        if (currentScore >= expectedScore && rarity[_nftId] >= expectedRarity) {
            return 100;
        } else {
            // here we get the % they get from score, from rarity, from used and then return based on their multiplier
            uint256 fromScore = currentScore.mul(100).div(expectedScore);
            uint256 fromRarity = rarity[_nftId].mul(100).div(expectedRarity);
            uint256 fromUsed = addonsUsed.mul(100).div(expectedAddons);
            return
                (fromRarity.mul(rarityMultiplier))
                    .add(fromScore.mul(hpMultiplier))
                    .add(fromUsed.mul(addonsMultiplier))
                    .div(100);
        }
    }

    function getChallenges(uint256 _nftId) public view returns (uint256) {
        if (vnft.level(_nftId) <= challengesUsed[_nftId]) {
            return 0;
        }

        return vnft.level(_nftId).sub(challengesUsed[_nftId]);
    }

    function buyAddon(uint256 _nftId, uint256 addonId)
        public
        tokenOwner(_nftId)
        notPaused
    {
        Addon storage _addon = addon[addonId];

        require(
            getHp(_nftId) >= _addon.requiredhp,
            "Raise your HP to buy this addon"
        );
        require(
            _addon.used <= addons.balanceOf(address(this), addonId),
            "Addon not available"
        );

        _addon.used = _addon.used.add(1);

        addonsConsumed[_nftId].add(addonId);

        rarity[_nftId] = rarity[_nftId].add(_addon.rarity);

        uint256 artistCut = _addon.price.mul(artistPct).div(100);

        muse.transferFrom(msg.sender, _addon.artistAddr, artistCut);
        muse.burnFrom(msg.sender, _addon.price.sub(artistCut));
        emit BuyAddon(_nftId, addonId, msg.sender);
    }

    function useAddon(uint256 _nftId, uint256 _addonID)
        public
        tokenOwner(_nftId)
        notPaused
    {
        require(
            !addonsConsumed[_nftId].contains(_addonID),
            "Pet already has this addon"
        );
        require(
            addons.balanceOf(msg.sender, _addonID) >= 1,
            "!own the addon to use it"
        );
        emit AttachAddon(_addonID, _nftId);
        Addon storage _addon = addon[_addonID];

        require(
            getHp(_nftId) >= _addon.requiredhp,
            "Raise your HP to use this addon"
        );

        _addon.used = _addon.used.add(1);

        addonsConsumed[_nftId].add(_addonID);

        rarity[_nftId] = rarity[_nftId].add(_addon.rarity);

        addons.safeTransferFrom(msg.sender, address(this), _addonID, 1, "0x0");
    }

    function transferAddon(
        uint256 _nftId,
        uint256 _addonID,
        uint256 _toId
    ) external tokenOwner(_nftId) {
        // maybe don't let transfer cash addon, or maybe yes as accessory in low supply?
        require(_addonID != 1, "this addon is instransferible");
        Addon storage _addon = addon[_addonID];

        require(
            getHp(_toId) >= _addon.requiredhp,
            "Receiving vNFT with no enough HP"
        );
        emit RemoveAddon(_addonID, _nftId);
        emit AttachAddon(_addonID, _toId);

        addonsConsumed[_nftId].remove(_addonID);
        rarity[_nftId] = rarity[_nftId].sub(_addon.rarity);

        addonsConsumed[_toId].add(_addonID);
        rarity[_toId] = rarity[_toId].add(_addon.rarity);
    }

    function removeAddon(uint256 _nftId, uint256 _addonID)
        public
        tokenOwner(_nftId)
    {
        // maybe can take this out for gas and the .remove would throw if no addonid on user?
        require(
            addonsConsumed[_nftId].contains(_addonID),
            "Pet doesn't have this addon"
        );
        Addon storage _addon = addon[_addonID];
        rarity[_nftId] = rarity[_nftId].sub(_addon.rarity);

        addonsConsumed[_nftId].remove(_addonID);
        emit RemoveAddon(_addonID, _nftId);

        addons.safeTransferFrom(address(this), msg.sender, _addonID, 1, "0x0");
    }

    function removeMultiple(
        uint256[] calldata nftIds,
        uint256[] calldata addonIds
    ) external {
        for (uint256 i = 0; i < addonIds.length; i++) {
            removeAddon(nftIds[i], addonIds[i]);
        }
    }

    function useMultiple(uint256[] calldata nftIds, uint256[] calldata addonIds)
        external
    {
        require(addonIds.length == nftIds.length, "Should match 1 to 1");
        for (uint256 i = 0; i < addonIds.length; i++) {
            useAddon(nftIds[i], addonIds[i]);
        }
    }

    function buyMultiple(uint256[] calldata nftIds, uint256[] calldata addonIds)
        external
    {
        require(addonIds.length == nftIds.length, "Should match 1 to 1");
        for (uint256 i = 0; i < addonIds.length; i++) {
            useAddon(nftIds[i], addonIds[i]);
        }
    }

    //@TODO Find a way to pass an array of arguments and parse it on delegated contract
    function action(string memory _signature, bytes memory data)
        public
        notPaused
    {
        (bool success, ) = delegateContract.delegatecall(
            abi.encodeWithSignature(_signature, data)
        );

        require(success, "Action error");
    }

    function withdraw(uint256 _id, address _to) external onlyOwner {
        addons.safeTransferFrom(address(this), _to, _id, 1, "");
    }

    function changeDelegate(address _newDelegate) external onlyOwner {
        require(
            _newDelegate != delegateContract,
            "New delegate should be diff"
        );
        previousDelegates.push(delegateContract);
        address oldDelegate = delegateContract;
        delegateContract = _newDelegate;
        total = total++;
        DelegateChanged(oldDelegate, _newDelegate);
    }

    function createAddon(
        string calldata _type,
        uint256 price,
        uint256 _hp,
        uint256 _rarity,
        string calldata _artistName,
        address _artist,
        uint256 _quantity
    ) external onlyOwner {
        _addonId.increment();
        uint256 newAddonId = _addonId.current();

        addon[newAddonId] = Addon(
            _type,
            price,
            _hp,
            _rarity,
            _artistName,
            _artist,
            _quantity,
            0
        );
        addons.mint(address(this), newAddonId, _quantity, "");

        emit CreateAddon(newAddonId, _type, _rarity, _quantity);
    }

    function getVnftInfo(uint256 _nftId)
        public
        view
        returns (
            uint256 _vNFT,
            uint256 _rarity,
            uint256 _hp,
            uint256 _addonsCount,
            uint256[10] memory _addons
        )
    {
        _vNFT = _nftId;
        _rarity = rarity[_nftId];
        _hp = getHp(_nftId);
        _addonsCount = addonsBalanceOf(_nftId);
        uint256 index = 0; // NOT FOR @JULES THIS IS HIGHLY EXPERIMENTAL NEED TO TEST
        while (index < _addonsCount && index < 10) {
            _addons[index] = (addonsConsumed[_nftId].at(index));
            index = index + 1;
        }
    }

    function editAddon(
        uint256 _id,
        string calldata _type,
        uint256 price,
        uint256 _requiredhp,
        uint256 _rarity,
        string calldata _artistName,
        address _artist,
        uint256 _quantity,
        uint256 _used
    ) external onlyOwner {
        Addon storage _addon = addon[_id];
        _addon._type = _type;
        _addon.price = price * 10**18;
        _addon.requiredhp = _requiredhp;
        _addon.rarity = _rarity;
        _addon.artistName = _artistName;
        _addon.artistAddr = _artist;
        if (_quantity > _addon.quantity) {
            addons.mint(address(this), _id, _quantity - _addon.quantity, "");
        } else if (_quantity < _addon.quantity) {
            addons.burn(address(this), _id, _addon.quantity - _quantity);
        }
        _addon.quantity = _quantity;
        _addon.used = _used;
        emit EditAddon(_id, _type, price, _quantity);
    }

    function setArtistPct(uint256 _newPct) external onlyOwner {
        artistPct = _newPct;
    }

    function setHealthStrat(
        uint256 _score,
        uint256 _days,
        uint256 _hpMultiplier,
        uint256 _rarityMultiplier,
        uint256 _expectedAddos,
        uint256 _addonsMultiplier,
        uint256 _premiumHp
    ) external onlyOwner {
        healthGem = _score;
        healthGemDays = _days;
        hpMultiplier = _hpMultiplier;
        rarityMultiplier = _rarityMultiplier;
        expectedAddons = _expectedAddos;
        addonsMultiplier = _addonsMultiplier;
        premiumHp = _premiumHp;
    }

    function pause(bool _paused) public onlyOwner {
        paused = _paused;
    }
}
