pragma solidity ^0.6.0;

interface IBoardroom {
    function allocateSeigniorage(uint256 amount) external;
    function totalSupply() external view returns (uint256);

}
