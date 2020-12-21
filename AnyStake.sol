// SPDX-License-Identifier: DeFiat and Friends (Zeppelin, MIT...)

// MAINNET VERSION.

pragma solidity ^0.6.6;

import "./AnyStake_Libraries.sol";
import "./AnyStake_Interfaces.sol";


// Vault distributes fees equally amongst staked pools

contract AnyStake {
    using SafeMath for uint256;


    address public DFT; //DeFiat token address
    address public GOV; //DeFiat GOV contract address    
    address public Treasury; //where rewards are stored for distribution
    uint256 public treasuryFee;
    uint256 public pendingTreasuryRewards;
    
    address public constant UniswapV2Router02 = address(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D); 
    address public constant UniswapV2Factory = address(0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f);
    
    //address public constant WETH = address(0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2); // MAINNET 
    address public constant WETH = address(0xc778417E063141139Fce010982780140Aa0cD5Ab);   // RINKEBY
    

//USERS METRICS
    struct UserInfo {
        uint256 amount; // How many tokens the user has provided.
        uint256 rewardPaid; // DFT already Paid. See explanation below.
                //  pending reward = (user.amount * pool.DFTPerShare) - user.rewardPaid
        uint256 rewardPaid2; // WETH already Paid. Same Logic.

    }
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    
//POOL METRICS
    struct PoolInfo {
        address stakedToken;            // Address of staked token contract.
        uint256 allocPoint;             // How many allocation points assigned to this pool. DFTs to distribute per block. (ETH = 2.3M blocks per year)
        uint256 accDFTPerShare;         // Accumulated DFTs per share, times 1e18. See below.
        uint256 accWETHPerShare;        // Accumulated DFTs per share, times 1e18. See below.
        bool withdrawable;              // Is this pool withdrawable or not (yes by default)
        
        mapping(address => mapping(address => uint256)) allowance;
    }
    PoolInfo[] public poolInfo;
    
    uint256 stakingFee;

    uint256 public totalAllocPoint;     // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public pendingDFTRewards;      // pending DFT rewards awaiting anyone to massUpdate
    uint256 public pendingWETHRewards;      // pending DFT rewards awaiting anyone to massUpdate

    uint256 public contractStartBlock;
    uint256 public epochCalculationStartBlock;
    uint256 public cumulativeRewardsSinceStart;
    uint256 public DFTrewardsInThisEpoch;
    uint256 public WETHrewardsInThisEpoch;    
    uint public epoch;

//EVENTS
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 _pid, uint256 value);

    
//INITIALIZE 
    constructor(address _DFT, address _Treasury) public {

        DFT = _DFT;
        Treasury = _Treasury; // DFT Central
        GOV = IDeFiat(DFT).DeFiat_gov();
        
        stakingFee = 50; // 5%base 1000

        contractStartBlock = block.number;
    }
    
//==================================================================================================================================
//POOL
    
 //view stuff
 
    function poolLength() external view returns (uint256) {
        return poolInfo.length; //number of pools (PiDs)
    }
    
    // Returns fees generated since start of this contract, DFT only
    function averageFeesPerBlockSinceStart() external view returns (uint averagePerBlock) {
        averagePerBlock = cumulativeRewardsSinceStart.add(DFTrewardsInThisEpoch).div(block.number.sub(contractStartBlock));
    }


    // Returns averge fees in this epoch, DFT only
    function averageFeesPerBlockEpoch() external view returns (uint256 averagePerBlock) {
        averagePerBlock = DFTrewardsInThisEpoch.div(block.number.sub(epochCalculationStartBlock));
    }

    // For easy graphing historical epoch rewards
    mapping(uint => uint256) public epochRewards;

 //set stuff (govenrors -> level inherited from DeFiat via governance

    // Add a new token pool. Can only be called by governors.
    function addPool(address _stakedToken, bool _withdrawable) public governanceLevel(2) {
        nonWithdrawableByAdmin[_stakedToken] = true; // stakedToken is now non-widthrawable by the admins.
        
        massUpdatePools();

        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            require(poolInfo[pid].stakedToken != _stakedToken,"Error pool already added");
        }

        poolInfo.push(
            PoolInfo({
                stakedToken: _stakedToken,
                allocPoint: _getTokenPrice(_stakedToken), //updates token price 1e18 and pool weight accordingly
                accDFTPerShare: 0,
                accWETHPerShare: 0,
                withdrawable : _withdrawable
            })
        );
        
    }

    // Updates the given pool's  allocation points manually. Can only be called with right governance levels.
    function setPool(uint256 _pid, uint256 _allocPoint, bool _withUpdate) public governanceLevel(2) {
        if (_withUpdate) {massUpdatePools();}

        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    // Update the given pool's ability to withdraw tokens
    function setPoolWithdrawable(uint256 _pid, bool _withdrawable) public governanceLevel(2) {
        poolInfo[_pid].withdrawable = _withdrawable;
    }
    

 //set stuff (anybody)
  
    //Starts a new calculation epoch; Because average since start will not be accurate. DFT only
    function startNewEpoch() public {
        require(epochCalculationStartBlock + 50000 < block.number, "New epoch not ready yet"); // 50k blocks = About a week
        epochRewards[epoch] = DFTrewardsInThisEpoch;
        cumulativeRewardsSinceStart = cumulativeRewardsSinceStart.add(DFTrewardsInThisEpoch);
        DFTrewardsInThisEpoch = 0;
        epochCalculationStartBlock = block.number;
        ++epoch;
    }
    
    
    
    
    
    
    //ANystake specific
    
    // internal view function to view price of any token in ETH
    function _getTokenPrice(address _token ) public view returns (uint256) {
        
        address _lpToken = IUniswapV2Factory(UniswapV2Factory).getPair(_token, WETH);
        //check for tokens or which it's reversed??

        if(_lpToken == address(0)){ _lpToken = IUniswapV2Factory(UniswapV2Factory).getPair(WETH, _token);}


        if (_token == WETH) {
            return 1e18;
        }
        
        uint256 tokenBalance = IERC20(_token).balanceOf(_lpToken);
        if (tokenBalance > 0) {
            uint256 wethBalance = IERC20(WETH).balanceOf(_lpToken);
            uint256 adjuster = 36 - uint256(IERC20(_token).decimals()); // handle non-base 18 tokens
            uint256 tokensPerEth = tokenBalance.mul(10**adjuster).div(wethBalance);
            return uint256(1e36).div(tokensPerEth); // price in gwei of token
        } else {
            return 0;
        }
        
        
    //return is 1e18. max Solidity is 1e77. 
    }
    
    
    
    
    
    
    // Updates the reward variables of the given pool
    function updatePool(uint256 _pid) internal returns (uint256 DFTRewardWhole) {
        PoolInfo storage pool = poolInfo[_pid];

        uint256 tokenSupply = IERC20(pool.stakedToken).balanceOf(address(this));
        if (tokenSupply == 0) { // avoids division by 0 errors
            return 0;
        }
        
        //DFT
            uint256 DFTReward = pendingDFTRewards         // Multiplies pending rewards by allocation point of this pool and then total allocation
                .mul(pool.allocPoint)               // getting the percent of total pending rewards this pool should get
                .div(totalAllocPoint);              // we can do this because pools are only mass updated
            
            pool.accDFTPerShare = pool.accDFTPerShare.add(DFTReward.mul(1e18).div(tokenSupply));
        
        //WETH
            uint256 WETHReward = pendingWETHRewards         // Multiplies pending rewards by allocation point of this pool and then total allocation
                .mul(pool.allocPoint)               // getting the percent of total pending rewards this pool should get
                .div(totalAllocPoint);              // we can do this because pools are only mass updated
            
            pool.accWETHPerShare = pool.accWETHPerShare.add(WETHReward.mul(1e18).div(tokenSupply));
         
        
        
        pool.allocPoint = _getTokenPrice(pool.stakedToken); //updates pricing-weight AFTER.
        
    }
    function massUpdatePools() public {
        uint256 length = poolInfo.length; 
        
        uint allDFTRewards;

        for (uint256 pid = 0; pid < length; ++pid) {
            allDFTRewards = allDFTRewards.add(updatePool(pid)); //calls updatePool(pid)
        }
        pendingDFTRewards = pendingDFTRewards.sub(allDFTRewards);
        
        uint allWETHRewards;
        for (uint256 pid = 0; pid < length; ++pid) {
            allWETHRewards = allWETHRewards.add(updatePool(pid)); //calls updatePool(pid)
        }
        pendingWETHRewards = pendingWETHRewards.sub(allWETHRewards);
        
        
    }
    
    //payout of DFT Rewards, uses SafeDFTTransfer
    function updateAndPayOutPending(uint256 _pid, address user) internal {
        
        massUpdatePools();

        uint256 pending = pendingDFT(_pid, user);
        uint256 pending2 = pendingWETH(_pid, user);
        
        safeDFTTransfer(user, pending);
        IWETH(WETH).transfer(user, pending2);
    }
    
    
    // Safe DFT transfer function, Manages rounding errors and fee on Transfer
    function safeDFTTransfer(address _to, uint256 _amount) internal {
        if(_amount == 0) return;

        uint256 DFTBal = IERC20(DFT).balanceOf(address(this));
        if (_amount >= DFTBal) { IERC20(DFT).transfer(_to, DFTBal);} 
        else { IERC20(DFT).transfer(_to, _amount);}

        DFTBalance = IERC20(DFT).balanceOf(address(this));
    }

//external call from token when rewards are loaded

    /* @dev called by the vault on staking/unstaking/claim
    *       updates the pendingRewards and the rewardsInThisEpoch variables for DFT
    */      
    modifier onlyTreasury() {
        require(msg.sender == Treasury);
        _;
    }
    
    uint256 private DFTBalance;
    uint256 private WETHBalance;
    
    
    function updateRewards() external onlyTreasury { 
        
    //DFT
        uint256 newDFTRewards = IERC20(DFT).balanceOf(address(this)).sub(DFTBalance); //delta vs previous balanceOf

        if(newDFTRewards > 0) {
            DFTBalance =  IERC20(DFT).balanceOf(address(this)); //balance snapshot
            pendingDFTRewards = pendingDFTRewards.add(newDFTRewards);
            DFTrewardsInThisEpoch = DFTrewardsInThisEpoch.add(newDFTRewards);
        }
        
         
    //WETH 
        uint256 newWETHRewards = IERC20(WETH).balanceOf(address(this)).sub(WETHBalance); //delta vs previous balanceOf

        if(newWETHRewards > 0) {
            WETHBalance =  IERC20(WETH).balanceOf(address(this)); //balance snapshot
            pendingWETHRewards = pendingWETHRewards.add(newWETHRewards);
            WETHrewardsInThisEpoch = WETHrewardsInThisEpoch.add(newWETHRewards);
        }
    }
    
    //NEED ONE FOR WETH
    
    
    
    //Buyback tokens with the staked fees (returns amount of tokens bought)
    //send procees to treasury for redistribution
    function buyWETHwithToken(uint256 _pid, uint256 _amountIN) internal returns(uint256){
        
        address[] memory UniSwapPath = new address[](2);
            UniSwapPath[0] = poolInfo[_pid].stakedToken;   //token staked (fee taken)
            UniSwapPath[1] = WETH;
     
        uint256 amountBought = IERC20(WETH).balanceOf(Treasury); //snapshot
        
        IUniswapV2Router02(UniswapV2Router02).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            _amountIN, 0,UniSwapPath, Treasury, 1 days);
        
        //Calculate the amount of tokens Bought
        if( IERC20(WETH).balanceOf(Treasury) > amountBought){
            amountBought = IERC20(WETH).balanceOf(Treasury).sub(amountBought);}
        else{amountBought = 0;}
        
        return amountBought;
    }
    
        //Buyback tokens with the staked fees (returns amount of tokens bought)
    //send procees to treasury for redistribution
    function buyDFTwithWETH(uint256 _amountIN) internal returns(uint256){
    
         address[] memory UniSwapPath = new address[](2);

            UniSwapPath[0] = WETH; 
            UniSwapPath[1] = DFT;
     
        uint256 amountBought = IERC20(DFT).balanceOf(Treasury); //snapshot
        
        IUniswapV2Router02(UniswapV2Router02).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            _amountIN, 0,UniSwapPath, Treasury, 1 days);
        
        //Calculate the amount of tokens Bought
        if( IERC20(DFT).balanceOf(Treasury) > amountBought){
            amountBought = IERC20(DFT).balanceOf(Treasury).sub(amountBought);}
        else{amountBought = 0;}
        
        return amountBought;
    }



//==================================================================================================================================
//USERS

    
    /* protects from a potential reentrancy in Deposits and Withdraws 
     * users can only make 1 deposit or 1 wd per block
     */
     
    mapping(address => uint256) private lastTXBlock;
    modifier NoReentrant(address _address) {
        require(block.number > lastTXBlock[_address], "Wait 1 block between each deposit/withdrawal");
        _;
    }
    
    // Deposit tokens to Vault to get allocation rewards
    function deposit(uint256 _pid, uint256 _amount) external NoReentrant(msg.sender) {
        lastTXBlock[msg.sender] = block.number+1;
        
        require(_amount > 0, "cannot deposit zero tokens");
        
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        

        updateAndPayOutPending(_pid, msg.sender); //Transfer pending tokens, updates the pools 

        // Calculate fees 95% default staking fee on non LP tokens)
        uint256 stakingFeeAmount = _amount.mul(stakingFee).div(1000);
        if(_pid <= 1){stakingFeeAmount = 0;} //overides to zero if user is staking LP DFT-ETH tokens or DFT tokens, _pid 0 and _pid 1
        
        uint256 remainingUserAmount = _amount.sub(stakingFeeAmount);
        
        //Transfer the amounts from user and update pool user.amount
        IERC20(pool.stakedToken).transferFrom(msg.sender, address(this), _amount); //GET ALL TOKENS FROM USER
        


        
        if(_pid <= 1){ //protects LP DFT and DFT tokens, as well as WETH 
    
        //1st move = buy wETH with the token
        uint256 wETHBought = buyWETHwithToken(_pid, stakingFeeAmount);
        
        //use 50% of wETH and buyDFT with them
        if(wETHBought != 0){
         buyDFTwithWETH(wETHBought.div(2));
        }
        
        //Send fees to Treasury (for redistribution later)
        IERC20(pool.stakedToken).transfer(Treasury, stakingFeeAmount.div(2));
        }
        
        
        //Finalize, update USER's metrics
        user.amount = user.amount.add(remainingUserAmount);
        user.rewardPaid = user.amount.mul(pool.accDFTPerShare).div(1e18);
        user.rewardPaid2 = user.amount.mul(pool.accWETHPerShare).div(1e18);
        
        //update POOLS with 1% of Treasury
        ITreasury(Treasury).pullRewards(DFT);
        ITreasury(Treasury).pullRewards(WETH);
        
        
        emit Deposit(msg.sender, _pid, _amount);
    }



    // Withdraw tokens from Vault.
    function withdraw(uint256 _pid, uint256 _amount) external NoReentrant(msg.sender) {
        _withdraw(_pid, _amount, msg.sender, msg.sender);
    }    
    
    function claim(uint256 _pid) external NoReentrant(msg.sender) {
        _withdraw(_pid, 0, msg.sender, msg.sender);
    }
    
    function _withdraw(uint256 _pid, uint256 _amount, address from, address to) internal {
        lastTXBlock[msg.sender] = block.number+1;
        
        PoolInfo storage pool = poolInfo[_pid];
        require(pool.withdrawable, "Withdrawing from this pool is disabled");
        
        UserInfo storage user = userInfo[_pid][from];
        require(user.amount >= _amount, "withdraw: user amount insufficient");

        updateAndPayOutPending(_pid, from); // //Transfer pending tokens, massupdates the pools 

        if(_amount > 0) {
            user.amount = user.amount.sub(_amount);
            IERC20(pool.stakedToken).transfer(address(to), _amount);
        }
        user.rewardPaid = user.amount.mul(pool.accDFTPerShare).div(1e18);

        //update POOLS with 1% of Treasury
        ITreasury(Treasury).pullRewards(DFT);
        ITreasury(Treasury).pullRewards(WETH);
        
        emit Withdraw(to, _pid, _amount);
    }

    // Getter function to see pending DFT rewards per user.
    function pendingDFT(uint256 _pid, address _user) public view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accDFTPerShare = pool.accDFTPerShare;

        return user.amount.mul(accDFTPerShare).div(1e18).sub(user.rewardPaid);
    }
    
    // Getter function to see pending wETH rewards per user.
    function pendingWETH(uint256 _pid, address _user) public view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accWETHPerShare = pool.accWETHPerShare;

        return user.amount.mul(accWETHPerShare).div(1e18).sub(user.rewardPaid);
    }


//==================================================================================================================================
//GOVERNANCE & UTILS

//Governance inherited from governance levels of DFTVaultAddress
    function viewActorLevelOf(address _address) public view returns(uint256) {
        return IGov(GOV).viewActorLevelOf(_address);
    }
    
    
//INHERIT FROM DEFIAT GOV
    modifier governanceLevel(uint8 _level){
        require(viewActorLevelOf(msg.sender) >= _level, "Grow some mustache kiddo...");
        _;
    }


//Anti RUG and EXIT by admins protocols    
    mapping(address => bool) nonWithdrawableByAdmin;
    function isNonWithdrawbleByAdmins(address _token) public view returns(bool) {
        return nonWithdrawableByAdmin[_token];
    }
    function _widthdrawAnyToken(address _recipient, address _ERC20address, uint256 _amount) public governanceLevel(2) returns(bool) {
        require(_ERC20address != DFT, "Cannot withdraw DFT from the pools");
        require(!nonWithdrawableByAdmin[_ERC20address], "this token is into a pool an cannot we withdrawn");
        IERC20(_ERC20address).transfer(_recipient, _amount); //use of the _ERC20 traditional transfer
        return true;
    } //get tokens sent by error, excelt DFT and those used for Staking.
    
    
}
