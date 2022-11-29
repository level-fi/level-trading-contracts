// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.15;

import {IOrderHook} from "../interfaces/IOrderHook.sol";
import {IReferralController} from "../interfaces/IReferralController.sol";
import {Side, IPool} from "../interfaces/IPool.sol";
import {IOrderManager, Order, SwapOrder} from "../interfaces/IOrderManager.sol";

contract OrderHook is IOrderHook {
    address public immutable orderManager;
    IReferralController public referralController;

    modifier onlyOrderManager() {
        validateSender();
        _;
    }

    constructor(address _orderManager, address _referralController) {
        require(_orderManager != address(0), "LoyaltyProgramController:invalidAddress");
        require(_referralController != address(0), "LoyaltyProgramController:invalidAddress");
        orderManager = _orderManager;
        referralController = IReferralController(_referralController);
    }

    function postPlaceOrder(uint256 orderId, bytes calldata extradata) external onlyOrderManager {
        if (extradata.length == 0) {
            return;
        }
        Order memory order = IOrderManager(orderManager).orders(orderId);
        address trader = order.owner;
        address referrer = abi.decode(extradata, (address));
        if (referrer != address(0)) {
            referralController.setReferrer(trader, referrer);
        }
    }

    function postPlaceSwapOrder(uint256 swapOrderId, bytes calldata extradata) external onlyOrderManager {
        if (extradata.length == 0) {
            return;
        }
        SwapOrder memory order = IOrderManager(orderManager).swapOrders(swapOrderId);
        address trader = order.owner;
        address referrer = abi.decode(extradata, (address));
        if (referrer != address(0)) {
            referralController.setReferrer(trader, referrer);
        }
    }

    function validateSender() internal view {
        require(msg.sender == orderManager, "PositionHook:!orderManager");
    }
}
