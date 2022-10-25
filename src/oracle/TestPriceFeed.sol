pragma solidity 0.8.15;

import {Ownable} from "openzeppelin/access/Ownable.sol";
import {ERC20} from "openzeppelin/token/ERC20/ERC20.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";
import {UniERC20} from "../lib/UniERC20.sol";

/// @title TestPriceFeed
/// @notice Price feed without guard. Use for testing only
/// @dev Explain to a developer any extra details
contract TestPriceFeed is Ownable, IOracle {
    struct TokenConfig {
        /// @dev 10 ^ token decimals
        uint256 baseUnits;
        /// @dev price precision
        uint256 priceUnits;
    }

    mapping(address => TokenConfig) public tokenConfig;
    /// @dev This price feed returns price in precision of 10 ^ (30 - token decimals)
    uint256 constant VALUE_PRECISION = 1e30;
    /// @notice last reported price
    mapping(address => uint256) lastAnswers;
    mapping(address => bool) public isReporter;
    address[] public reporters;

    // ============ Mutative functions ============

    /// @notice report token price
    /// allow some authorized reporters only
    function postPrice(address token, uint256 price) external {
        require(isReporter[msg.sender], "PriceFeed::unauthorized");
        TokenConfig memory config = tokenConfig[token];
        require(config.baseUnits > 0, "PriceFeed::tokenNotWhitelisted");
        uint256 normalizedPrice = (price * VALUE_PRECISION) /
            config.baseUnits /
            config.priceUnits;

        lastAnswers[token] = normalizedPrice;
        emit PricePosted(token, normalizedPrice);
    }

    // ============ View functions ============

    function getPrice(address token) external view returns (uint256) {
        TokenConfig memory config = tokenConfig[token];
        require(config.baseUnits > 0, "PriceFeed::tokenNotConfigured");
        uint256 price = lastAnswers[token];
        require(price > 0, "PriceFeed::priceIsNotAvailable");
        return price;
    }

    // =========== Admin functions ===========

    /// @notice config watched token
    /// @param token token address
    /// @param priceDecimals precision of price posted by reporter, not the chainlink price feed
    function configToken(
        address token,
        uint256 priceDecimals
    ) external onlyOwner {
        require(tokenConfig[token].baseUnits == 0, "PriceFeed::tokenAdded");
        uint256 decimals = token == UniERC20.ETH ? 18 : ERC20(token).decimals();
        tokenConfig[token] = TokenConfig({
            baseUnits: 10**decimals,
            priceUnits: 10**priceDecimals
        });
        emit TokenAdded(token);
    }


    function addUpdater(address updater) external onlyOwner {
        require(!isReporter[updater], "PriceFeed::updaterAlreadyAdded");
        isReporter[updater] = true;
        reporters.push(updater);
        emit UpdaterAdded(updater);
    }

    function removeUpdater(address updater) external onlyOwner {
        require(isReporter[updater], "PriceFeed::updaterNotExists");
        isReporter[updater] = false;
        for (uint256 i = 0; i < reporters.length; i++) {
            if (reporters[i] == updater) {
                reporters[i] = reporters[reporters.length - 1];
                break;
            }
        }
        reporters.pop();
        emit UpdaterRemoved(updater);
    }

    // =========== Events ===========
    event UpdaterAdded(address);
    event UpdaterRemoved(address);
    event PricePosted(address token, uint256 price);
    event TokenAdded(address token);
}
