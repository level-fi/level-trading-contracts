pragma solidity >=0.8.0;

contract MockOracle {
    mapping(address => uint256) public _getPrice;

    function setPrice(address token, uint256 price) external {
        _getPrice[token] = price;
    }

    function getPrice(address token, bool) external view returns (uint256) {
        return _getPrice[token];
    }

    function getMultiplePrices(address[] calldata tokens, bool /* max */) external view returns (uint256[] memory) {
        uint256 len = tokens.length;
        uint256[] memory result = new uint[](len);

        for (uint256 i = 0; i < len;) {
            result[i] = _getPrice[tokens[i]];
            unchecked {
                ++i;
            }
        }

        return result;
    }
}
