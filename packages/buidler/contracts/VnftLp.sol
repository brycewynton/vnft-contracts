pragma solidity ^0.6.0;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "./interfaces/IVNFT.sol";

interface IMigratorChef {
    // Perform LP token migration from legacy UniswapV2 to SushiSwap.
    // Take the current LP token address and return the new LP token address.
    // Migrator should have full access to the caller's LP token.
    // Return the new LP token address.
    //
    // XXX Migrator must have allowance access to UniswapV2 LP tokens.
    // SushiSwap must mint EXACTLY the same amount of SushiSwap LP tokens or
    // else something bad will happen. Traditional UniswapV2 does not
    // do that so be careful!
    function migrate(IERC20 token) external returns (IERC20);
}

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract VnftLp is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of Muse
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accMusePerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accMusePerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
        uint256 vnftId; //he needs to provide a pet id that will have to stay alive for him to keep getting reward
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. MUSE to distribute per block.
        uint256 lastRewardBlock; // Last block number that MUSE distribution occurs.
        uint256 accPointsPerShare; // Accumulated points per share, times 1e12. See below.
    }

    // The vNFTs
    IVNFT public vnft;

    // Dev address.
    address public devaddr;
    // Block number when bonus MUSE period ends.
    uint256 public bonusEndBlock;
    // MUSE tokens created per block.
    uint256 public pointsPerBlock;
    // points needed to withdraw vnft
    uint256 public vnftPrice = 400;
    // Bonus muliplier for early MUSE makers.
    uint256 public constant BONUS_MULTIPLIER = 10;
    // The migrator contract. It has a lot of power. Can only be set through governance (owner).
    IMigratorChef public migrator;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation poitns. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when MUSE mining starts.
    uint256 public startBlock;

    // pending balance for each user, updates after new deposit
    mapping(uint256 => mapping(address => uint256)) public balance;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );

    constructor(uint256 _pointsPerBlock, address _vnft) public {
        devaddr = msg.sender;
        pointsPerBlock = _pointsPerBlock;
        vnft = IVNFT(_vnft);
        // bonusEndBlock = block.number.add(46523);
        bonusEndBlock = 2;
        // startBlock = block.number;
        startBlock = 1;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(
        uint256 _allocPoint,
        IERC20 _lpToken,
        bool _withUpdate
    ) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock
            ? block.number
            : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(
            PoolInfo({
                lpToken: _lpToken,
                allocPoint: _allocPoint,
                lastRewardBlock: lastRewardBlock,
                accPointsPerShare: 0
            })
        );
    }

    // Update the given pool's MUSE allocation point. Can only be called by the owner.
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        bool _withUpdate
    ) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(
            _allocPoint
        );
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    // Set the migrator contract. Can only be called by the owner.
    function setMigrator(IMigratorChef _migrator) public onlyOwner {
        migrator = _migrator;
    }

    // Migrate lp token to another lp contract. Can be called by anyone. We trust that migrator contract is good.
    function migrate(uint256 _pid) public {
        require(address(migrator) != address(0), "migrate: no migrator");
        PoolInfo storage pool = poolInfo[_pid];
        IERC20 lpToken = pool.lpToken;
        uint256 bal = lpToken.balanceOf(address(this));
        lpToken.safeApprove(address(migrator), bal);
        IERC20 newLpToken = migrator.migrate(lpToken);
        require(bal == newLpToken.balanceOf(address(this)), "migrate: bad");
        pool.lpToken = newLpToken;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to)
        public
        view
        returns (uint256)
    {
        if (_to <= bonusEndBlock) {
            return _to.sub(_from).mul(BONUS_MULTIPLIER);
        } else if (_from >= bonusEndBlock) {
            return _to.sub(_from);
        } else {
            return
                bonusEndBlock.sub(_from).mul(BONUS_MULTIPLIER).add(
                    _to.sub(bonusEndBlock)
                );
        }
    }

    // View function to see pending Muse on frontend.
    function pendingPoints(uint256 _pid, address _user)
        external
        view
        returns (uint256)
    {
        // if the staker doesn't own an nft then return 0 reward.
        if (vnft.balanceOf(_user) == 0) {
            return 0;
        } else {
            PoolInfo storage pool = poolInfo[_pid];
            UserInfo storage user = userInfo[_pid][_user];
            uint256 accPointsPerShare = pool.accPointsPerShare;
            uint256 lpSupply = pool.lpToken.balanceOf(address(this));
            if (block.number > pool.lastRewardBlock && lpSupply != 0) {
                uint256 multiplier = getMultiplier(
                    pool.lastRewardBlock,
                    block.number
                );
                uint256 museReward = multiplier
                    .mul(pointsPerBlock)
                    .mul(pool.allocPoint)
                    .div(totalAllocPoint);
                accPointsPerShare = accPointsPerShare.add(
                    museReward.mul(1e12).div(lpSupply)
                );
            }
            return
                user
                    .amount
                    .mul(accPointsPerShare)
                    .div(1e12)
                    .sub(user.rewardDebt)
                    .sub(balance[_pid][_user]);
        }
    }

    // Update reward vairables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 pointsReward = multiplier
            .mul(pointsPerBlock)
            .mul(pool.allocPoint)
            .div(totalAllocPoint);
        pool.accPointsPerShare = pool.accPointsPerShare.add(
            pointsReward.mul(1e12).div(lpSupply)
        );
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to MasterChef for points allocation.
    function deposit(uint256 _pid, uint256 _amount) public {
        // require to own at least one vNFT
        require(
            vnft.balanceOf(msg.sender) > 0,
            "You must own at least 1 vNFT to stake"
        );
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending = user
                .amount
                .mul(pool.accPointsPerShare)
                .div(1e12)
                .sub(user.rewardDebt);
            balance[_pid][msg.sender] = balance[_pid][msg.sender].add(pending);
        }
        pool.lpToken.safeTransferFrom(
            address(msg.sender),
            address(this),
            _amount
        );
        user.amount = user.amount.add(_amount);
        user.rewardDebt = user.amount.mul(pool.accPointsPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // // Withdraw LP tokens from MasterChef.
    // function withdraw(uint256 _pid, uint256 _amount) public {
    //     // if he doesn't own a vNFT when withdrawing, send him stake without rewards
    //     if (vnft.balanceOf(msg.sender) == 0) {
    //         emergencyWithdraw(_pid);
    //     } else {
    //         PoolInfo storage pool = poolInfo[_pid];
    //         UserInfo storage user = userInfo[_pid][msg.sender];
    //         require(user.amount >= _amount, "withdraw: not good");
    //         updatePool(_pid);
    //         uint256 pending = user
    //             .amount
    //             .mul(pool.accPointsPerShare)
    //             .div(1e12)
    //             .sub(user.rewardDebt);

    //         if (pending >= vnftPrice) {
    //             vnft.mint(msg.sender);
    //         }
    //         // here mints nft
    //         balance[_pid][msg.sender] = balance[_pid][msg.sender].add(pending);

    //         user.amount = user.amount.sub(_amount);
    //         user.rewardDebt = user.amount.mul(pool.accPointsPerShare).div(1e12);
    //         pool.lpToken.safeTransfer(address(msg.sender), _amount);
    //         emit Withdraw(msg.sender, _pid, _amount);
    //     }
    // }

    function redeem(uint256 _pid, uint256 _amount) public {
        // if he doesn't own a vNFT when withdrawing, send him stake without rewards
        if (vnft.balanceOf(msg.sender) == 0) {
            emergencyWithdraw(_pid);
        } else {
            PoolInfo storage pool = poolInfo[_pid];
            UserInfo storage user = userInfo[_pid][msg.sender];
            updatePool(_pid);
            uint256 pending = user
                .amount
                .mul(pool.accPointsPerShare)
                .div(1e12)
                .sub(user.rewardDebt);

            // here mints nft
            if (pending >= vnftPrice) {
                vnft.mint(msg.sender);
            }
            balance[_pid][msg.sender] = balance[_pid][msg.sender].add(pending);
            emit Withdraw(msg.sender, _pid, _amount);
        }
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        pool.lpToken.safeTransfer(address(msg.sender), user.amount);
        emit EmergencyWithdraw(msg.sender, _pid, user.amount);
        user.amount = 0;
        user.rewardDebt = 0;
        balance[_pid][msg.sender] = 0;
    }

    // Update dev address by the previous dev.
    function dev(address _devaddr) public {
        require(msg.sender == devaddr, "dev: wut?");
        devaddr = _devaddr;
    }

    function setPointsPerBlock(uint256 _pointsPerBlock) public {
        require(msg.sender == devaddr, "dev: wut?");
        pointsPerBlock = _pointsPerBlock;
    }

    function setVnftPrice(uint256 _vnftPrice) public {
        require(msg.sender == devaddr, "dev: wut?");
        vnftPrice = _vnftPrice;
    }
}