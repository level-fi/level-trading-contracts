pragma solidity >=0.8.0;

library MathUtils {
    function diff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    function zeroCapSub(uint256 a, uint256 b) internal pure returns(uint) {
        return a > b ? a - b : 0;
    }
}
