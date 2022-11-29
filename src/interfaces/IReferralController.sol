pragma solidity 0.8.15;

import {Side} from "./IPool.sol";

interface IReferralController {
    function handlePositionDecreased(
        address trader,
        address indexToken,
        address collateralToken,
        Side side,
        uint256 sizeChange
    ) external;

    function setReferrer(address _trader, address _referrer) external;
}
