pragma solidity ^0.6.0;

import './math.sol';
import './IERC20.sol';
import './SafeERC20.sol';

import './IBoardroom.sol';
import './IBasisAsset.sol';
import './Babylonian.sol';
import './FixedPoint.sol';
import './Safe112.sol';
import './Operator.sol';
import './Epoch.sol';
import './ContractGuard.sol';

/**
 * @title  LLC Treasury contract
 * @notice Monetary policy logic to adjust supplies of LLC assets
 * @author Summer Smith & Rick Sanchez
 */
contract Treasury is ContractGuard, Epoch {
    using FixedPoint for *;
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;
    using Safe112 for uint112;

    /* ========== STATE VARIABLES ========== */

    // ========== FLAGS
    bool public migrated = false;
    bool public initialized = false;

    // ========== CORE
    address public fund;
    address public cash;
    address public bond;
    address public share;
    address public boardroom;
    address public alloUser;
    address public usdt;
    
    address   LLC_USDT;

    
    PriceOracle priceOracle;

    // ========== PARAMS
    uint256 public cashPriceOne;
    uint256 public cashPriceCeiling;
    uint256 public cashPriceBack;

    uint256 public bondDepletionFloor;
    uint256 private accumulatedSeigniorage = 0;
    uint256 public fundAllocationRate = 2; // %

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _cash,
        address _bond,
        address _share,
        address _usdt,
        address _boardroom,
        address _fund,
        address _priceOracle,
        address _alloUser,
        uint256 _startTime
    ) public Epoch(1 days, _startTime, 0) {
        
        cash = _cash;
        bond = _bond;
        share = _share;
        usdt = _usdt;
        boardroom = _boardroom;
        fund = _fund;
        alloUser=_alloUser;
        cashPriceOne = 10**18;
        priceOracle=PriceOracle(_priceOracle);
        cashPriceCeiling = uint256(105).mul(cashPriceOne).div(10**2);
        cashPriceBack = uint256(85).mul(cashPriceOne).div(10**2);
        bondDepletionFloor = uint256(1000).mul(cashPriceOne);
    }

    /* =================== Modifier =================== */

    modifier checkMigration {
        require(!migrated, 'Treasury: migrated');

        _;
    }

    modifier checkOperator {
        require(
            IBasisAsset(cash).operator() == address(this) &&
                IBasisAsset(bond).operator() == address(this) &&
                IBasisAsset(share).operator() == address(this) &&
                Operator(boardroom).operator() == address(this),
            'Treasury: need more permission'
        );

        _;
    }
    
    
    modifier onlyAlloUser(){
        require(msg.sender == alloUser);
        _;
    }

    /* ========== VIEW FUNCTIONS ========== */

    // budget
    function getReserve() public view returns (uint256) {
        return accumulatedSeigniorage;
    }

    // oracle
    function getBondOraclePrice() public view returns (uint256) {
         try priceOracle.consultFor1Hour(cash,10**18) returns (uint256 price) {
            return price;
        } catch {
            revert('Treasury: failed to consult cash price from the oracle');
        }
    }

    function getSeigniorageOraclePrice() public view returns (uint256) {
         try priceOracle.consult(cash,10**18) returns (uint256 price) {
            return price;
        } catch {
            revert('Treasury: failed to consult cash price from the oracle');
        }
    }


    /* ========== GOVERNANCE ========== */

    function initialize() public checkOperator {
        require(!initialized, 'Treasury: initialized');

        // burn all of it's balance
        IBasisAsset(cash).burn(IERC20(cash).balanceOf(address(this)));

        // set accumulatedSeigniorage to it's balance
        accumulatedSeigniorage = IERC20(cash).balanceOf(address(this));

        initialized = true;
        emit Initialized(msg.sender, block.number);
    }

    function migrate(address target) public onlyOperator checkOperator {
        require(!migrated, 'Treasury: migrated');

        // cash
        //Operator(cash).transferOperator(target);
        //Operator(cash).transferOwnership(target);
        
        IERC20(cash).transfer(target, IERC20(cash).balanceOf(address(this)));

        // bond
        //Operator(bond).transferOperator(target);
        //Operator(bond).transferOwnership(target);
        IERC20(bond).transfer(target, IERC20(bond).balanceOf(address(this)));

        // share
        //Operator(share).transferOperator(target);
        //Operator(share).transferOwnership(target);
        IERC20(share).transfer(target, IERC20(share).balanceOf(address(this)));

        IERC20(usdt).transfer(target, IERC20(usdt).balanceOf(address(this)));

        migrated = true;
        emit Migration(target);
    }

    function setFund(address newFund) public onlyOperator {
        fund = newFund;
        emit ContributionPoolChanged(msg.sender, newFund);
    }

    function setFundAllocationRate(uint256 rate) public onlyOperator {
        fundAllocationRate = rate;
        emit ContributionPoolRateChanged(msg.sender, rate);
    }

    /* ========== MUTABLE FUNCTIONS ========== */

    function _updateCashPrice() internal {
        try priceOracle.update()  {} catch {}
        try priceOracle.updateFor1Hour()  {} catch {}
    }

    function buyBonds(uint256 amount, uint256 targetPrice)
        external
        onlyOneBlock
        checkMigration
        checkStartTime
        checkOperator
    {
        require(amount > 0, 'Treasury: cannot purchase bonds with zero amount');

        uint256 cashPrice =getBondOraclePrice();
        require(cashPrice == targetPrice, 'Treasury: cash price moved');
        require(
            cashPrice < cashPriceOne, // price < $1
            'Treasury: cashPrice not eligible for bond purchase'
        );

        uint256 bondPrice = cashPrice;

        IBasisAsset(cash).burnFrom(msg.sender, amount);
        IBasisAsset(bond).mint(msg.sender, amount.mul(1e18).div(bondPrice));
        _updateCashPrice();

        emit BoughtBonds(msg.sender, amount);
    }

    function redeemBonds(uint256 amount, uint256 targetPrice)
        external
        onlyOneBlock
        checkMigration
        checkStartTime
        checkOperator
    {
        require(amount > 0, 'Treasury: cannot redeem bonds with zero amount');

        uint256 cashPrice = getBondOraclePrice();
        require(cashPrice == targetPrice, 'Treasury: cash price moved');
        require(
            cashPrice > cashPriceCeiling, // price > $1.05
            'Treasury: cashPrice not eligible for bond purchase'
        );
        require(
            IERC20(cash).balanceOf(address(this)) >= amount,
            'Treasury: treasury has no more budget'
        );

        accumulatedSeigniorage = accumulatedSeigniorage.sub(
            Math.min(accumulatedSeigniorage, amount)
        );

        IBasisAsset(bond).burnFrom(msg.sender, amount);
        IERC20(cash).safeTransfer(msg.sender, amount);
        _updateCashPrice();

        emit RedeemedBonds(msg.sender, amount);
    }

    function allocateSeigniorage()
        external
        onlyOneBlock
        checkMigration
        checkStartTime
        checkEpoch
        checkOperator
        onlyAlloUser
    {
        _updateCashPrice();
        uint256 cashPrice =getSeigniorageOraclePrice();
        if (cashPrice <= cashPriceCeiling) {
            return; // just advance epoch instead revert
        }
        
        // circulating supply
        uint256 cashSupply = IERC20(cash).totalSupply().sub(
            accumulatedSeigniorage
        );
        uint256 percentage = cashPrice.sub(cashPriceOne);
        uint256 seigniorage = cashSupply.mul(percentage).div(1e18);
        IBasisAsset(cash).mint(address(this), seigniorage);

        // ======================== BIP-3
        uint256 fundReserve = seigniorage.mul(fundAllocationRate).div(100);
        if (fundReserve > 0) {
            IERC20(cash).safeTransfer(fund, fundReserve);
            emit ContributionPoolFunded(now, fundReserve);
        }

        seigniorage = seigniorage.sub(fundReserve);

        // ======================== BIP-4
        uint256 treasuryReserve = Math.min(
            seigniorage,
            IERC20(bond).totalSupply().sub(accumulatedSeigniorage)
        );
        if (treasuryReserve > 0) {
            accumulatedSeigniorage = accumulatedSeigniorage.add(
                treasuryReserve
            );
            emit TreasuryFunded(now, treasuryReserve);
        }

        // boardroom
        uint256 boardroomReserve = seigniorage.sub(treasuryReserve);
        if (boardroomReserve > 0) {
            IERC20(cash).safeApprove(boardroom, boardroomReserve);
            IBoardroom(boardroom).allocateSeigniorage(boardroomReserve);
            emit BoardroomFunded(now, boardroomReserve);
        }
    }
    
    
    function buyBack(uint256 amount) public onlyAlloUser{
        uint256 cashPrice =getSeigniorageOraclePrice();
        require (cashPrice <= cashPriceBack,"price too high");
        require(IERC20(usdt).balanceOf(address(this)) >= amount, "Insufficient contract balance");
        (uint256 reserve0, uint256 reserve1,) = IMdexPair(LLC_USDT).getReserves();
        uint256 amountInWithFee = amount.mul(997);
        uint256 amountOut = amount.mul(997).mul(reserve0) / reserve1.mul(1000).add(amountInWithFee);
        IERC20(usdt).safeTransfer(LLC_USDT, amount);
        IMdexPair(LLC_USDT).swap(amountOut, 0, address(this), new bytes(0));
        IBasisAsset(cash).burn(amountOut);
    }
    
    
    function setPriceOracle(address priceOracle_) public onlyOwner {
         priceOracle=PriceOracle(priceOracle_);
    }
    

    function setAlloUser(address alloUser_) public onlyOwner {
         alloUser=alloUser_;
    }
    
    
    function setLLCPair(address llcPair_) public onlyOwner {
         LLC_USDT=llcPair_;
    }
    
    
    
    

    // GOV
    event Initialized(address indexed executor, uint256 at);
    event Migration(address indexed target);
    event ContributionPoolChanged(address indexed operator, address newFund);
    event ContributionPoolRateChanged(
        address indexed operator,
        uint256 newRate
    );

    // CORE
    event RedeemedBonds(address indexed from, uint256 amount);
    event BoughtBonds(address indexed from, uint256 amount);
    event TreasuryFunded(uint256 timestamp, uint256 seigniorage);
    event BoardroomFunded(uint256 timestamp, uint256 seigniorage);
    event ContributionPoolFunded(uint256 timestamp, uint256 seigniorage);
}

interface  PriceOracle{
    function consult(address token,uint256 amountIn) external view returns(uint256 amountOut);
    function consultFor1Hour(address token,uint256 amountIn) external view returns(uint256 amountOut);
    function update() external;
    function updateFor1Hour() external;
}

interface IMdexPair {

    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external;
}
