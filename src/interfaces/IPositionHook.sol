pragma solidity 0.8.15;

import {Side, IPool} from "./IPool.sol";

interface IPositionHook {
    function preIncreasePosition(
        address owner,
        address indexToken,
        address collateralToken,
        Side side,
        uint256 sizeChange,
        bytes calldata extradata
    ) external;

    function postIncreasePosition(
        address owner,
        address indexToken,
        address collateralToken,
        Side side,
        uint256 sizeChange,
        bytes calldata extradata
    ) external;

    function preDecreasePosition(
        address owner,
        address indexToken,
        address collateralToken,
        Side side,
        uint256 sizeChange,
        bytes calldata extradata
    ) external;

    function postDecreasePosition(
        address owner,
        address indexToken,
        address collateralToken,
        Side side,
        uint256 sizeChange,
        bytes calldata extradata
    ) external;

    event PreIncreasePositionExecuted(
        address pool,
        address owner,
        address indexToken,
        address collateralToken,
        Side side,
        uint256 sizeChange,
        bytes extradata
    );
    event PostIncreasePositionExecuted(
        address pool,
        address owner,
        address indexToken,
        address collateralToken,
        Side side,
        uint256 sizeChange,
        bytes extradata
    );
    event PreDecreasePositionExecuted(
        address pool,
        address owner,
        address indexToken,
        address collateralToken,
        Side side,
        uint256 sizeChange,
        bytes extradata
    );
    event PostDecreasePositionExecuted(
        address pool,
        address owner,
        address indexToken,
        address collateralToken,
        Side side,
        uint256 sizeChange,
        bytes extradata
    );
}
