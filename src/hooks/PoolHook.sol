pragma solidity 0.8.15;

import {IPositionHook} from "../interfaces/IPositionHook.sol";
import {Side, IPool} from "../interfaces/IPool.sol";
import {IMintableErc20} from "../interfaces/IMintableErc20.sol";
import {Ownable} from "openzeppelin/access/Ownable.sol";

contract PoolHook is Ownable, IPositionHook {
    uint8 constant lyLevelDecimals = 18;
    uint256 constant VALUE_PRECISION = 1e30;
    address private immutable pool;
    IMintableErc20 public immutable lyLevel;

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

    function preIncreasePosition(
        address owner,
        address indexToken,
        address collateralToken,
        Side side,
        uint256 sizeChange,
        bytes calldata extradata
    )
        external
        onlyPool
    {}

    function postIncreasePosition(
        address owner,
        address indexToken,
        address collateralToken,
        Side side,
        uint256 sizeChange,
        bytes calldata extradata
    )
        external
        onlyPool
    {}

    function preDecreasePosition(
        address owner,
        address indexToken,
        address collateralToken,
        Side side,
        uint256 sizeChange,
        bytes calldata extradata
    )
        external
        onlyPool
    {}

    function postDecreasePosition(
        address owner,
        address indexToken,
        address collateralToken,
        Side side,
        uint256 sizeChange,
        bytes calldata extradata
    )
        external
        onlyPool
    {
        uint256 lyTokenAmount = (sizeChange * 10 ** lyLevelDecimals) / VALUE_PRECISION;

        if (lyTokenAmount > 0) {
            lyLevel.mint(owner, lyTokenAmount);
        }
        emit PostDecreasePositionExecuted(msg.sender, owner, indexToken, collateralToken, side, sizeChange, extradata);
    }

    event PoolAdded(address pool);
    event PoolRemoved(address pool);
}
