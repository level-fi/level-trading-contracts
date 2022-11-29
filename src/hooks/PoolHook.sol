pragma solidity 0.8.15;

import {IPositionHook} from "../interfaces/IPositionHook.sol";
import {Side, IPool} from "../interfaces/IPool.sol";
import {IMintableErc20} from "../interfaces/IMintableErc20.sol";
import {IReferralController} from "../interfaces/IReferralController.sol";
import {Ownable} from "openzeppelin/access/Ownable.sol";

contract PoolHook is Ownable, IPositionHook {
    uint8 constant lyLevelDecimals = 18;
    uint256 constant VALUE_PRECISION = 1e30;
    address private immutable pool;
    IMintableErc20 public immutable lyLevel;
    IReferralController public referralController;

    constructor(address _lyLevel, address _pool, address _referralController) {
        require(_lyLevel != address(0), "PoolHook:invalidAddress");
        require(_pool != address(0), "PoolHook:invalidAddress");
        lyLevel = IMintableErc20(_lyLevel);
        pool = _pool;
        referralController = IReferralController(_referralController);
    }

    function validatePool(address sender) internal view {
        require(sender == pool, "PoolHook:!pool");
    }

    modifier onlyPool() {
        validatePool(msg.sender);
        _;
    }

    function preIncreasePosition(
        address owner,
        address indexToken,
        address collateralToken,
        Side side,
        bytes calldata extradata
    ) external onlyPool {}

    function postIncreasePosition(
        address owner,
        address indexToken,
        address collateralToken,
        Side side,
        bytes calldata extradata
    ) external onlyPool {}

    function preDecreasePosition(
        address owner,
        address indexToken,
        address collateralToken,
        Side side,
        bytes calldata extradata
    ) external onlyPool {}

    function postDecreasePosition(
        address owner,
        address indexToken,
        address collateralToken,
        Side side,
        bytes calldata extradata
    ) external onlyPool {
        (uint256 sizeChange, /* uint256 collateralValue */) = abi.decode(extradata, (uint256, uint256));
        _handlePositionClosed(owner, indexToken, collateralToken, side, sizeChange);
        emit PostDecreasePositionExecuted(msg.sender, owner, indexToken, collateralToken, side, extradata);
    }

    function preLiquidatePosition(
        address owner,
        address indexToken,
        address collateralToken,
        Side side,
        bytes calldata extradata
    ) external onlyPool {}


    function postLiquidatePosition(
        address owner,
        address indexToken,
        address collateralToken,
        Side side,
        bytes calldata extradata
    ) external onlyPool {
        (uint256 sizeChange, /* uint256 collateralValue */) = abi.decode(extradata, (uint256, uint256));
        _handlePositionClosed(owner, indexToken, collateralToken, side, sizeChange);
        emit PostLiquidatePositionExecuted(msg.sender, owner, indexToken, collateralToken, side, extradata);
    }

    function setReferralController(address _controller) external onlyOwner {
        referralController = IReferralController(_controller);
        emit ReferralControllerSet(_controller);
    }

    function _handlePositionClosed(
        address owner,
        address indexToken,
        address collateralToken,
        Side side,
        uint256 sizeChange
    ) internal {
        uint256 lyTokenAmount = (sizeChange * 10 ** lyLevelDecimals) / VALUE_PRECISION;

        if (lyTokenAmount > 0) {
            lyLevel.mint(owner, lyTokenAmount);
        }

        if (address(referralController) != address(0)) {
            referralController.handlePositionDecreased(owner, indexToken, collateralToken, side, sizeChange);
        }
    }

    event ReferralControllerSet(address controller);
}
