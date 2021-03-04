pragma solidity =0.6.6;

library SafeMath {
    function add(uint x, uint y) internal pure returns (uint z) {
        require((z = x + y) >= x, 'ds-math-add-overflow');
    }

    function sub(uint x, uint y) internal pure returns (uint z) {
        require((z = x - y) <= x, 'ds-math-sub-underflow');
    }

    function mul(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x, 'ds-math-mul-overflow');
    }
}

library FixedPoint {
    // range: [0, 2**112 - 1]
    // resolution: 1 / 2**112
    struct uq112x112 {
        uint224 _x;
    }

    // range: [0, 2**144 - 1]
    // resolution: 1 / 2**112
    struct uq144x112 {
        uint _x;
    }

    uint8 private constant RESOLUTION = 112;

    // encode a uint112 as a UQ112x112
    function encode(uint112 x) internal pure returns (uq112x112 memory) {
        return uq112x112(uint224(x) << RESOLUTION);
    }

    // encodes a uint144 as a UQ144x112
    function encode144(uint144 x) internal pure returns (uq144x112 memory) {
        return uq144x112(uint256(x) << RESOLUTION);
    }

    // divide a UQ112x112 by a uint112, returning a UQ112x112
    function div(uq112x112 memory self, uint112 x) internal pure returns (uq112x112 memory) {
        require(x != 0, 'FixedPoint: DIV_BY_ZERO');
        return uq112x112(self._x / uint224(x));
    }

    // multiply a UQ112x112 by a uint, returning a UQ144x112
    // reverts on overflow
    function mul(uq112x112 memory self, uint y) internal pure returns (uq144x112 memory) {
        uint z;
        require(y == 0 || (z = uint(self._x) * y) / y == uint(self._x), "FixedPoint: MULTIPLICATION_OVERFLOW");
        return uq144x112(z);
    }

    // returns a UQ112x112 which represents the ratio of the numerator to the denominator
    // equivalent to encode(numerator).div(denominator)
    function fraction(uint112 numerator, uint112 denominator) internal pure returns (uq112x112 memory) {
        require(denominator > 0, "FixedPoint: DIV_BY_ZERO");
        return uq112x112((uint224(numerator) << RESOLUTION) / denominator);
    }

    // decode a UQ112x112 into a uint112 by truncating after the radix point
    function decode(uq112x112 memory self) internal pure returns (uint112) {
        return uint112(self._x >> RESOLUTION);
    }

    // decode a UQ144x112 into a uint144 by truncating after the radix point
    function decode144(uq144x112 memory self) internal pure returns (uint144) {
        return uint144(self._x >> RESOLUTION);
    }
}

interface IMdexPair {
    event Approval(address indexed owner, address indexed spender, uint value);
    event Transfer(address indexed from, address indexed to, uint value);

    function name() external pure returns (string memory);

    function symbol() external pure returns (string memory);

    function decimals() external pure returns (uint8);

    function totalSupply() external view returns (uint);

    function balanceOf(address owner) external view returns (uint);

    function allowance(address owner, address spender) external view returns (uint);

    function approve(address spender, uint value) external returns (bool);

    function transfer(address to, uint value) external returns (bool);

    function transferFrom(address from, address to, uint value) external returns (bool);

    function DOMAIN_SEPARATOR() external view returns (bytes32);

    function PERMIT_TYPEHASH() external pure returns (bytes32);

    function nonces(address owner) external view returns (uint);

    function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external;

    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    function MINIMUM_LIQUIDITY() external pure returns (uint);

    function factory() external view returns (address);

    function token0() external view returns (address);

    function token1() external view returns (address);

    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

    function price0CumulativeLast() external view returns (uint);

    function price1CumulativeLast() external view returns (uint);

    function kLast() external view returns (uint);

    function mint(address to) external returns (uint liquidity);

    function burn(address to) external returns (uint amount0, uint amount1);

    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external;

    function skim(address to) external;

    function sync() external;

    function price(address token, uint256 baseDecimal) external view returns (uint256);

    function initialize(address, address) external;
}

library MdexOracleLibrary {
    using FixedPoint for *;

    // helper function that returns the current block timestamp within the range of uint32, i.e. [0, 2**32 - 1]
    function currentBlockTimestamp() internal view returns (uint32) {
        return uint32(block.timestamp % 2 ** 32);
    }

    // produces the cumulative price using counterfactuals to save gas and avoid a call to sync.
    function currentCumulativePrices(
        address pair
    ) internal view returns (uint price0Cumulative, uint price1Cumulative, uint32 blockTimestamp) {
        blockTimestamp = currentBlockTimestamp();
        price0Cumulative = IMdexPair(pair).price0CumulativeLast();
        price1Cumulative = IMdexPair(pair).price1CumulativeLast();

        // if time has elapsed since the last update on the pair, mock the accumulated price values
        (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast) = IMdexPair(pair).getReserves();
        if (blockTimestampLast != blockTimestamp) {
            // subtraction overflow is desired
            uint32 timeElapsed = blockTimestamp - blockTimestampLast;
            // addition overflow is desired
            // counterfactual
            price0Cumulative += uint(FixedPoint.fraction(reserve1, reserve0)._x) * timeElapsed;
            // counterfactual
            price1Cumulative += uint(FixedPoint.fraction(reserve0, reserve1)._x) * timeElapsed;
        }
    }
}

interface IMdexFactory {
    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    function feeTo() external view returns (address);

    function feeToSetter() external view returns (address);

    function feeToRate() external view returns (uint256);

    function initCodeHash() external view returns (bytes32);

    function getPair(address tokenA, address tokenB) external view returns (address pair);

    function allPairs(uint) external view returns (address pair);

    function allPairsLength() external view returns (uint);

    function createPair(address tokenA, address tokenB) external returns (address pair);

    function setFeeTo(address) external;

    function setFeeToSetter(address) external;

    function setFeeToRate(uint256) external;

    function setInitCodeHash(bytes32) external;

    function sortTokens(address tokenA, address tokenB) external pure returns (address token0, address token1);

    function pairFor(address tokenA, address tokenB) external view returns (address pair);

    function getReserves(address tokenA, address tokenB) external view returns (uint256 reserveA, uint256 reserveB);

    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) external pure returns (uint256 amountB);

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) external view returns (uint256 amountOut);

    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut) external view returns (uint256 amountIn);

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);

    function getAmountsIn(uint256 amountOut, address[] calldata path) external view returns (uint256[] memory amounts);
}



// fixed window oracle that recomputes the average price for the entire period once every period
// note that the price average is only guaranteed to be over at least 1 period, but may be over a longer period
contract MdexOracle {
    using FixedPoint for *;
    using SafeMath for uint256;
    
    uint256 private oneHourPeriod = 1 hours;
    uint256 private oneHourStartTime;
    uint256 private oneHourEpoch;
    
    uint256 private oneDayPeriod = 24 hours;
    uint256 private oneDayStartTime;
    uint256 private oneDayEpoch;


    IMdexPair immutable pair;
    address public immutable  token0;
    address public immutable  token1;

    uint    public price0CumulativeLast;
    uint    public price1CumulativeLast;
    uint32  public blockTimestampLast;
    FixedPoint.uq112x112 public price0Average;
    FixedPoint.uq112x112 public price1Average;
    uint    public price0CumulativeLast1Hours;
    uint    public price1CumulativeLast1Hours;
    uint32  public blockTimestampLast1Hours;
    FixedPoint.uq112x112 public price0Average1Hours;
    FixedPoint.uq112x112 public price1Average1Hours;
    
    address owner;
    
    
    modifier checkOneHourEpoch {
        require(now >= nextOneHourEpochPoint(), 'Epoch: not allowed');

        _;

        oneHourEpoch = oneHourEpoch.add(1);
    }
    
    
    modifier checkOneDayEpoch {
        require(now >= nextOneDayEpochPoint(), 'Epoch: not allowed');

        _;

        oneDayEpoch = oneDayEpoch.add(1);
    }
    
    
    modifier onlyOwner(){
            require(msg.sender == owner);
            _;
    }
    
    function setOneHourPeriod(uint256 _period) external onlyOwner {
        oneHourPeriod = _period;
    }
    
    function setOneDayPeriod(uint256 _period) external onlyOwner {
        oneDayPeriod = _period;
    }
    
    /* ========== VIEW FUNCTIONS ========== */

    function getCurrentOneHourEpoch() public view returns (uint256) {
        return oneHourEpoch;
    }

    function getOneHourPeriod() public view returns (uint256) {
        return oneHourPeriod;
    }

    function getOneHourStartTime() public view returns (uint256) {
        return oneHourStartTime;
    }

    function nextOneHourEpochPoint() public view returns (uint256) {
        return oneHourStartTime.add(oneHourEpoch.mul(oneHourPeriod));
    }
    
     /* ========== VIEW FUNCTIONS ========== */

    function getCurrentOneDayEpoch() public view returns (uint256) {
        return oneDayEpoch;
    }

    function getOneDayPeriod() public view returns (uint256) {
        return oneDayPeriod;
    }

    function getOneDayStartTime() public view returns (uint256) {
        return oneDayStartTime;
    }

    function nextOneDayEpochPoint() public view returns (uint256) {
        return oneDayStartTime.add(oneDayEpoch.mul(oneDayPeriod));
    }

    constructor(address factory, address tokenA, address tokenB, uint256 oneHourStartTime_, uint256 oneDayStartTime_) public{
        IMdexPair _pair = IMdexPair(IMdexFactory(factory).pairFor(tokenA, tokenB));
        pair = _pair;
        token0 = _pair.token0();
        token1 = _pair.token1();
        price0CumulativeLast = _pair.price0CumulativeLast();
        // fetch the current accumulated price value (1 / 0)
        price1CumulativeLast = _pair.price1CumulativeLast();
        // fetch the current accumulated price value (0 / 1)
        price0CumulativeLast1Hours = price0CumulativeLast;
        price1CumulativeLast1Hours = price1CumulativeLast;
        oneHourStartTime=oneHourStartTime_;
        oneDayStartTime=oneDayStartTime_;
        owner=msg.sender;
        uint112 reserve0;
        uint112 reserve1;
        (reserve0, reserve1, blockTimestampLast) = _pair.getReserves();
        blockTimestampLast1Hours = blockTimestampLast;
        require(reserve0 != 0 && reserve1 != 0, 'MDEXOracle: NO_RESERVES');
        // ensure that there's liquidity in the pair
    }

    function update() public checkOneDayEpoch {
        (uint price0Cumulative, uint price1Cumulative, uint32 blockTimestamp) =
        MdexOracleLibrary.currentCumulativePrices(address(pair));
        uint32 timeElapsed = blockTimestamp - blockTimestampLast;
        

        // overflow is desired, casting never truncates
        // cumulative price is in (uq112x112 price * seconds) units so we simply wrap it after division by time elapsed
        price0Average = FixedPoint.uq112x112(uint224((price0Cumulative - price0CumulativeLast) / timeElapsed));
        price1Average = FixedPoint.uq112x112(uint224((price1Cumulative - price1CumulativeLast) / timeElapsed));

        price0CumulativeLast = price0Cumulative;
        price1CumulativeLast = price1Cumulative;
        blockTimestampLast = blockTimestamp;
    }

    // note this will always return 0 before update has been called successfully for the first time.
    function consult(address token, uint amountIn) public view returns (uint amountOut) {
        if (token == token0) {
            amountOut = price0Average.mul(amountIn).decode144();
        } else {
            require(token == token1, 'MDEXOracle: INVALID_TOKEN');
            amountOut = price1Average.mul(amountIn).decode144();
        }
    }

    function updateFor1Hour() public checkOneHourEpoch {
        (uint price0Cumulative, uint price1Cumulative, uint32 blockTimestamp) =
        MdexOracleLibrary.currentCumulativePrices(address(pair));
        uint32 timeElapsed = blockTimestamp - blockTimestampLast1Hours;


        // overflow is desired, casting never truncates
        // cumulative price is in (uq112x112 price * seconds) units so we simply wrap it after division by time elapsed
        price0Average1Hours = FixedPoint.uq112x112(uint224((price0Cumulative - price0CumulativeLast1Hours) / timeElapsed));
        price1Average1Hours = FixedPoint.uq112x112(uint224((price1Cumulative - price1CumulativeLast1Hours) / timeElapsed));

        price0CumulativeLast1Hours = price0Cumulative;
        price1CumulativeLast1Hours = price1Cumulative;
        blockTimestampLast1Hours = blockTimestamp;
    }

    // note this will always return 0 before update has been called successfully for the first time.
    function consultFor1Hour(address token, uint amountIn) public view returns (uint amountOut) {
        if (token == token0) {
            amountOut = price0Average1Hours.mul(amountIn).decode144();
        } else {
            require(token == token1, 'MDEXOracle: INVALID_TOKEN');
            amountOut = price1Average1Hours.mul(amountIn).decode144();
        }
    }
    
  

}
