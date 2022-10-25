// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.15;

import {Ownable} from "openzeppelin/access/Ownable.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";

struct TokenConfig {
    /// @dev 10 ^ token decimals
    uint256 baseUnits;
    /// @dev chainlink pricefeed used to compare with posted price
    /// if posted price if too high or too low it will be rejected
    AggregatorV3Interface chainlinkPriceFeed;
}

contract ChainlinkOracle is Ownable, IOracle {
    /// @dev This price feed returns price in precision of 10 ^ (30 - token decimals)
    uint256 constant VALUE_PRECISION = 1e30;
    uint256 public constant PRICE_FEED_TIMEOUT = 5 * 60;
    mapping(address => TokenConfig) public tokenConfig;

    function getPrice(address token) external view returns (uint256) {
        TokenConfig memory config = tokenConfig[token];
        require(address(config.chainlinkPriceFeed) != address(0), "ChainlinkOracle:tokenNotConfigured");
        (uint price, uint updatedAt) = getChainlinkPrice(config);
        require(updatedAt + PRICE_FEED_TIMEOUT >= block.timestamp, "ChainlinkOracle:outOfDate");
        return price;
    }

    function getLastPrice(address token) external view returns (uint256 price) {
        TokenConfig memory config = tokenConfig[token];
        require(address(config.chainlinkPriceFeed) != address(0), "ChainlinkOracle:tokenNotConfigured");
        (price,) = getChainlinkPrice(config);
    }

    function getChainlinkPrice(TokenConfig memory config) internal view returns (uint256 price, uint256 updatedAt) {
        int256 answer;
        (, answer, , updatedAt, ) = config.chainlinkPriceFeed.latestRoundData();
        uint256 answerDecimals = config.chainlinkPriceFeed.decimals();
        price = (uint256(answer) * VALUE_PRECISION) / 10**answerDecimals / config.baseUnits;
    }

    /// @notice config watched token
    /// @param token token address
    /// @param tokenDecimals token decimals
    /// @param priceFeed the chainlink price feed used for reference
    function configToken(
        address token,
        uint256 tokenDecimals,
        address priceFeed
    ) external onlyOwner {
        require(tokenConfig[token].baseUnits == 0, "ChainlinkOracle:tokenAdded");
        require(priceFeed != address(0), "ChainlinkOracle:invalidPriceFeed");

        tokenConfig[token] = TokenConfig({
            baseUnits: 10**tokenDecimals,
            chainlinkPriceFeed: AggregatorV3Interface(priceFeed)
        });
        emit TokenAdded(token);
    }

    event TokenAdded(address token);
}
