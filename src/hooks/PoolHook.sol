pragma solidity 0.8.15;

import {Ownable} from "openzeppelin/access/Ownable.sol";
import {IPoolHook} from "../interfaces/IPoolHook.sol";
import {Side, IPool} from "../interfaces/IPool.sol";
import {IMintableErc20} from "../interfaces/IMintableErc20.sol";
import {ILevelOracle} from "../interfaces/ILevelOracle.sol";

interface IPoolForHook {
    function oracle() external view returns (ILevelOracle);
}

contract PoolHook is Ownable, IPoolHook {
    uint256 constant MULTIPLIER_PRECISION = 100;
    uint256 constant MAX_MULTIPLIER = 5 * MULTIPLIER_PRECISION;
    uint8 constant lyLevelDecimals = 18;
    uint256 constant VALUE_PRECISION = 1e30;

    address private immutable pool;
    IMintableErc20 public immutable lyLevel;

    uint256 public positionSizeMultiplier = 100;
    uint256 public swapSizeMultiplier = 100;

    constructor(address _lyLevel, address _pool) {
        require(_lyLevel != address(0), "PoolHook:invalidAddress");
        require(_pool != address(0), "PoolHook:invalidAddress");
        lyLevel = IMintableErc20(_lyLevel);
        pool = _pool;
    }

    function validatePool(address sender) internal view {
        require(sender == pool, "PoolHook:!pool");
    }

    modifier onlyPool() {
        validatePool(msg.sender);
        _;
    }

    function postIncreasePosition(
        address _owner,
        address _indexToken,
        address _collateralToken,
        Side _side,
        bytes calldata _extradata
    ) external onlyPool {}

    function postDecreasePosition(
        address _owner,
        address _indexToken,
        address _collateralToken,
        Side _side,
        bytes calldata _extradata
    ) external onlyPool {
        (uint256 sizeChange, /* uint256 collateralValue */ ) = abi.decode(_extradata, (uint256, uint256));
        _handlePositionClosed(_owner, _indexToken, _collateralToken, _side, sizeChange);
        emit PostDecreasePositionExecuted(msg.sender, _owner, _indexToken, _collateralToken, _side, _extradata);
    }

    function postLiquidatePosition(
        address _owner,
        address _indexToken,
        address _collateralToken,
        Side _side,
        bytes calldata _extradata
    ) external onlyPool {
        (uint256 sizeChange, /* uint256 collateralValue */ ) = abi.decode(_extradata, (uint256, uint256));
        _handlePositionClosed(_owner, _indexToken, _collateralToken, _side, sizeChange);
        emit PostLiquidatePositionExecuted(msg.sender, _owner, _indexToken, _collateralToken, _side, _extradata);
    }

    function postSwap(address _user, address _tokenIn, address _tokenOut, bytes calldata _data) external onlyPool {
        (uint256 amountIn, /* uint256 amountOut */ ) = abi.decode(_data, (uint256, uint256));
        uint256 priceIn = _getPrice(_tokenIn, false);
        uint256 lyTokenAmount =
            (amountIn * priceIn * 10 ** lyLevelDecimals) * swapSizeMultiplier / MULTIPLIER_PRECISION / VALUE_PRECISION;
        if (lyTokenAmount != 0) {
            lyLevel.mint(_user, lyTokenAmount);
        }
        emit PostSwapExecuted(msg.sender, _user, _tokenIn, _tokenOut, _data);
    }

    // ========= Admin function ========

    function setMultipliers(uint256 _positionSizeMultiplier, uint256 _swapSizeMultiplier) external onlyOwner {
        require(_positionSizeMultiplier <= MAX_MULTIPLIER, "Multiplier too high");
        require(_swapSizeMultiplier <= MAX_MULTIPLIER, "Multiplier too high");
        positionSizeMultiplier = _positionSizeMultiplier;
        swapSizeMultiplier = _swapSizeMultiplier;
        emit MultipliersSet(positionSizeMultiplier, swapSizeMultiplier);
    }

    // ========= Internal function ========
    function _handlePositionClosed(
        address _owner,
        address, /* _indexToken */
        address, /* _collateralToken */
        Side, /* _side */
        uint256 _sizeChange
    ) internal {
        uint256 lyTokenAmount =
            (_sizeChange * 10 ** lyLevelDecimals) * positionSizeMultiplier / MULTIPLIER_PRECISION / VALUE_PRECISION;

        if (lyTokenAmount != 0) {
            lyLevel.mint(_owner, lyTokenAmount);
        }
    }

    function _getPrice(address token, bool max) internal view returns (uint256) {
        ILevelOracle oracle = IPoolForHook(pool).oracle();
        return oracle.getPrice(token, max);
    }

    event ReferralControllerSet(address controller);
    event MultipliersSet(uint256 positionSizeMultiplier, uint256 swapSizeMultiplier);
}
